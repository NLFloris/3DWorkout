import SwiftUI
import MapKit

/// Tab content for the heatmap. Owns the view model + indexer + location
/// service, composes the map with the filter chips and the indexing progress
/// strip.
struct HeatmapTabView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel: HeatmapViewModel
    @StateObject private var indexer: HeatmapIndexer
    @StateObject private var locationService = LocationService()

    init(store: WorkoutStore, healthKit: HealthKitService, settings: AppSettings) {
        _viewModel = StateObject(wrappedValue: HeatmapViewModel(
            store: store, settings: settings
        ))
        _indexer = StateObject(
            wrappedValue: HeatmapIndexer(healthKit: healthKit, store: store)
        )
    }

    var body: some View {
        // No NavigationStack — the heatmap is a single full-bleed surface, and
        // a nav bar would otherwise reserve a white strip above the safe area.
        ZStack(alignment: .top) {
            HeatmapMapView(viewModel: viewModel,
                           settings: settings,
                           userLocation: locationService.currentLocation)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                HeatmapFilterBar(viewModel: viewModel)
                if indexer.isRunning {
                    IndexingStrip(indexer: indexer)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .task {
            // Give the tab-switch animation + first MapView layout a frame
            // to commit before kicking off heavy work (HealthKit fetches and
            // SwiftData inserts). Without this, iOS's gesture recognizer can
            // log "system gesture gate timed out" while the main actor is
            // briefly busy.
            try? await Task.sleep(nanoseconds: 200_000_000)
            locationService.requestLocation()
            indexer.startIfNeeded()
        }
        .onChange(of: indexer.completedWorkouts) { _, _ in
            // Each newly-indexed workout adds a track; re-aggregate so the
            // heatmap fills in progressively.
            viewModel.refreshAvailableSports()
            viewModel.reaggregate()
        }
    }
}

// MARK: - Filter bar

private struct HeatmapFilterBar: View {
    @ObservedObject var viewModel: HeatmapViewModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Date range", selection: $viewModel.dateRange) {
                    ForEach(HeatmapDateRange.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(viewModel.dateRange.displayName)
                    Image(systemName: "chevron.down").font(.caption2.bold())
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Menu {
                ForEach(viewModel.availableSports, id: \.self) { sport in
                    Button {
                        toggle(sport)
                    } label: {
                        if viewModel.selectedSports.contains(sport) {
                            Label(sport, systemImage: "checkmark")
                        } else {
                            Text(sport)
                        }
                    }
                }
                Divider()
                Button("Select all") {
                    viewModel.selectedSports = Set(viewModel.availableSports)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "figure.run")
                    Text(sportsLabel)
                    Image(systemName: "chevron.down").font(.caption2.bold())
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .disabled(viewModel.availableSports.isEmpty)

            Spacer()
        }
    }

    private func toggle(_ sport: String) {
        if viewModel.selectedSports.contains(sport) {
            viewModel.selectedSports.remove(sport)
        } else {
            viewModel.selectedSports.insert(sport)
        }
    }

    private var sportsLabel: String {
        if viewModel.availableSports.isEmpty { return "Sports" }
        if viewModel.selectedSports.count == viewModel.availableSports.count { return "All sports" }
        if viewModel.selectedSports.count == 1 { return viewModel.selectedSports.first ?? "Sport" }
        return "\(viewModel.selectedSports.count) sports"
    }
}

// MARK: - Indexing strip

private struct IndexingStrip: View {
    @ObservedObject var indexer: HeatmapIndexer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative,
                              options: .repeating,
                              isActive: indexer.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Indexing workouts")
                    .font(.caption.weight(.semibold))
                ProgressView(value: indexer.progress)
                    .tint(.red)
            }
            Text("\(indexer.completedWorkouts) / \(indexer.totalWorkouts)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

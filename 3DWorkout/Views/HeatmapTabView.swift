import SwiftUI
import MapKit

/// Tab content for the heatmap. Owns the view model + indexer + location
/// service, composes the map with the filter chips and the indexing progress
/// strip.
struct HeatmapTabView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @EnvironmentObject var settings: AppSettings
    /// Owned by `MainTabView` so both survive across tab switches and are
    /// pre-warmed before the user first taps this tab.
    @ObservedObject var viewModel: HeatmapViewModel
    @ObservedObject var indexer: HeatmapIndexer
    @StateObject private var locationService = LocationService()
    let store: WorkoutStore

    init(viewModel: HeatmapViewModel,
         indexer: HeatmapIndexer,
         store: WorkoutStore,
         settings: AppSettings) {
        self.viewModel = viewModel
        self.indexer = indexer
        self.store = store
    }

    @State private var showExport = false
    /// We hold the tapped workout's UUID rather than the session itself —
    /// `navigationDestination(item:)` requires `Hashable`, which
    /// `WorkoutSession` isn't because of its nested route/metrics.
    @State private var tappedSessionID: UUID?

    var body: some View {
        // A NavigationStack lets us push the tapped workout into detail. The
        // nav bar is hidden on the heatmap surface itself (so the map stays
        // full-bleed), and shown normally on pushed destinations.
        NavigationStack {
            ZStack(alignment: .top) {
                HeatmapMapView(viewModel: viewModel,
                               settings: settings,
                               userLocation: locationService.currentLocation,
                               onTrackTap: { uuid in tappedSessionID = uuid })
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        HeatmapFilterBar(viewModel: viewModel)
                        Spacer(minLength: 0)
                        Button {
                            showExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .accessibilityLabel("Export heatmap")
                        .disabled(viewModel.tracks.isEmpty)
                    }
                    if indexer.isRunning {
                        IndexingStrip(indexer: indexer)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $tappedSessionID) { uuid in
                if let session = store.cachedSession(for: uuid) {
                    WorkoutDetailView(session: session,
                                      healthKitService: healthKitService,
                                      store: store,
                                      settings: settings)
                } else {
                    ContentUnavailableView(
                        "Workout not found",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This workout is no longer in the local cache.")
                    )
                }
            }
        }
        .sheet(isPresented: $showExport) {
            HeatmapExportView(viewModel: viewModel)
                .environmentObject(settings)
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

import SwiftUI

struct WorkoutListView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @EnvironmentObject var settings: AppSettings
    /// Owned by `MainTabView` so the viewmodel survives across tab switches
    /// and is pre-warmed during launch — see `MainTabView.task`.
    @ObservedObject var viewModel: WorkoutListViewModel
    private let store: WorkoutStore

    init(viewModel: WorkoutListViewModel,
         healthKitService: HealthKitService,
         store: WorkoutStore) {
        self.viewModel = viewModel
        self.store = store
    }

    @State private var refreshTrigger: Int = 0

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.workouts.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemGroupedBackground))
                } else if viewModel.workouts.isEmpty {
                    emptyState
                } else {
                    workoutList
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Button {
                            refreshTrigger &+= 1
                            Task { await viewModel.loadWorkouts(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .fontWeight(.semibold)
                                .symbolEffect(.bounce, value: refreshTrigger)
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.loadWorkouts() }
    }

    private var workoutList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                summaryHeader
                WorkoutFilterBar(viewModel: viewModel)
                if viewModel.filteredWorkouts.isEmpty {
                    filteredEmptyHint
                } else {
                    ForEach(viewModel.filteredWorkouts) { session in
                        NavigationLink {
                            WorkoutDetailView(session: session,
                                              healthKitService: healthKitService,
                                              store: store,
                                              settings: settings)
                        } label: {
                            WorkoutCard(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var filteredEmptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No workouts match these filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var summaryHeader: some View {
        HStack(spacing: 0) {
            SummaryTile(
                value: "\(viewModel.filteredWorkouts.count)",
                label: "Workouts",
                icon: "flame.fill",
                color: .orange
            )
            Divider().frame(height: 32)
            SummaryTile(
                value: totalDistance,
                label: "Total \(settings.units.distanceUnit)",
                icon: "location.fill",
                color: .blue
            )
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .padding(.top, 4)
    }

    private var totalDistance: String {
        let meters = viewModel.filteredWorkouts.compactMap(\.totalDistance).reduce(0, +)
        return settings.units.distanceValueString(meters, decimals: 0)
    }

    @State private var emptyStateAppeared = false

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: emptyStateAppeared)
            Text("No Workouts Found")
                .font(.title3.bold())
            Text("Complete a GPS workout on your Apple Watch\nto see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { emptyStateAppeared = true }
    }
}

// MARK: - Workout Card

private struct WorkoutCard: View {
    let session: WorkoutSession
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(typeColor.gradient)
                        .frame(width: 48, height: 48)
                    Image(systemName: session.workoutTypeIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.workoutType)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)

            Divider().padding(.horizontal, 16)

            // Stats row
            HStack(spacing: 0) {
                if let dist = session.formattedDistance(settings.units) {
                    StatCell(value: dist, label: "Distance", icon: "location.fill", color: .blue)
                }
                StatCell(value: session.formattedDuration, label: "Duration", icon: "clock.fill", color: .orange)
                if let cal = session.formattedCalories {
                    StatCell(value: cal, label: "Calories", icon: "flame.fill", color: .red)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var typeColor: Color {
        switch session.workoutType {
        case "Running":  return .orange
        case "Cycling":  return .blue
        case "Hiking":   return .green
        case "Walking":  return .teal
        case "Swimming": return .cyan
        default:         return .red
        }
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Filter bar

private struct WorkoutFilterBar: View {
    @ObservedObject var viewModel: WorkoutListViewModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Date range", selection: $viewModel.dateRange) {
                    ForEach(HeatmapDateRange.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
            } label: {
                chipLabel(icon: "calendar", text: viewModel.dateRange.displayName)
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
                chipLabel(icon: "figure.run", text: sportsLabel)
            }
            .disabled(viewModel.availableSports.isEmpty)

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
            Image(systemName: "chevron.down").font(.caption2.bold())
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
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

private struct SummaryTile: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.title2, design: .rounded).bold())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

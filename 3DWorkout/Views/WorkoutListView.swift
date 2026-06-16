import SwiftUI

struct WorkoutListView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel: WorkoutListViewModel
    @State private var showSettings = false
    private let store: WorkoutStore

    init(healthKitService: HealthKitService, store: WorkoutStore) {
        self.store = store
        _viewModel = StateObject(wrappedValue: WorkoutListViewModel(healthKitService: healthKitService, store: store))
    }

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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .fontWeight(.semibold)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Button {
                            Task { await viewModel.loadWorkouts() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
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
                ForEach(viewModel.workouts) { session in
                    NavigationLink {
                        WorkoutDetailView(session: session, healthKitService: healthKitService, store: store)
                    } label: {
                        WorkoutCard(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var summaryHeader: some View {
        HStack(spacing: 0) {
            SummaryTile(
                value: "\(viewModel.workouts.count)",
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
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .padding(.top, 4)
    }

    private var totalDistance: String {
        let meters = viewModel.workouts.compactMap(\.totalDistance).reduce(0, +)
        return settings.units.distanceValueString(meters, decimals: 0)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Workouts Found")
                .font(.title3.bold())
            Text("Complete a GPS workout on your Apple Watch\nto see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

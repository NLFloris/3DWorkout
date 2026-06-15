import SwiftUI

struct WorkoutListView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @StateObject private var viewModel: WorkoutListViewModel

    init(healthKitService: HealthKitService) {
        _viewModel = StateObject(wrappedValue: WorkoutListViewModel(healthKitService: healthKitService))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.workouts.isEmpty {
                    ProgressView("Loading workouts…")
                } else if viewModel.workouts.isEmpty {
                    ContentUnavailableView(
                        "No Workouts Found",
                        systemImage: "figure.run.circle",
                        description: Text("Complete a GPS workout on your Apple Watch to see it here.")
                    )
                } else {
                    List(viewModel.workouts) { session in
                        NavigationLink {
                            WorkoutDetailView(session: session, healthKitService: healthKitService)
                        } label: {
                            WorkoutRowView(session: session)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await viewModel.loadWorkouts() } } label: {
                            Image(systemName: "arrow.clockwise")
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
}

private struct WorkoutRowView: View {
    let session: WorkoutSession
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.workoutTypeIcon)
                .font(.title2)
                .foregroundStyle(.red)
                .frame(width: 40, height: 40)
                .background(.red.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.workoutType)
                    .font(.headline)
                Text(Self.dateFormatter.string(from: session.startDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label(session.formattedDuration, systemImage: "clock")
                    if let dist = session.formattedDistance {
                        Label(dist, systemImage: "location")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

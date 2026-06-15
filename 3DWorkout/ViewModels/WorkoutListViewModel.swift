import Foundation

@MainActor
final class WorkoutListViewModel: ObservableObject {
    @Published var workouts: [WorkoutSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let healthKitService: HealthKitService

    init(healthKitService: HealthKitService) {
        self.healthKitService = healthKitService
    }

    func loadWorkouts() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            workouts = try await healthKitService.fetchWorkouts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import Foundation

@MainActor
final class WorkoutListViewModel: ObservableObject {
    @Published var workouts: [WorkoutSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let healthKitService: HealthKitService
    private let store: WorkoutStore

    init(healthKitService: HealthKitService, store: WorkoutStore) {
        self.healthKitService = healthKitService
        self.store = store
    }

    func loadWorkouts() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Show cached workouts immediately for an instant launch.
        let cached = store.cachedSessions()
        if !cached.isEmpty { workouts = cached }

        // Refresh from HealthKit and update the cache.
        do {
            let fresh = try await healthKitService.fetchWorkouts()
            store.syncMetadata(fresh)
            workouts = store.cachedSessions()
        } catch {
            // Keep showing cached data; only surface the error if we have nothing.
            if workouts.isEmpty { errorMessage = error.localizedDescription }
        }
    }
}

import Foundation

@MainActor
final class WorkoutListViewModel: ObservableObject {
    @Published private(set) var workouts: [WorkoutSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Filter state — applied lazily over the cached workouts.
    @Published var selectedSports: Set<String> = []
    @Published var dateRange: HeatmapDateRange = .allTime

    private let healthKitService: HealthKitService
    private let store: WorkoutStore

    /// Last time we successfully hit HealthKit. Re-appearing this view (e.g.
    /// switching back from the Heatmap tab) within `refreshInterval` skips the
    /// HK fetch — the cached data is already shown instantly from SwiftData.
    private var lastFetchAt: Date?
    private let refreshInterval: TimeInterval = 60

    init(healthKitService: HealthKitService, store: WorkoutStore) {
        self.healthKitService = healthKitService
        self.store = store
    }

    /// Distinct workout types we have cached. Drives the sport filter menu.
    var availableSports: [String] {
        Array(Set(workouts.map(\.workoutType))).sorted()
    }

    /// The workouts to display after applying the active filters.
    var filteredWorkouts: [WorkoutSession] {
        let sportsFilter = selectedSports
        let startDate = dateRange.startDate
        return workouts.filter { session in
            if !sportsFilter.isEmpty, !sportsFilter.contains(session.workoutType) {
                return false
            }
            if let startDate, session.startDate < startDate { return false }
            return true
        }
    }

    func loadWorkouts(force: Bool = false) async {
        guard !isLoading else { return }

        // Show cached workouts immediately so the list never blanks out.
        let cached = store.cachedSessions()
        if !cached.isEmpty { workouts = cached }
        seedSportsIfNeeded()

        // Skip the HealthKit round-trip if we refreshed recently — re-entering
        // this tab from elsewhere would otherwise stall on a HK query that
        // can't have new results yet.
        if !force,
           let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < refreshInterval,
           !workouts.isEmpty {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fresh = try await healthKitService.fetchWorkouts()
            store.syncMetadata(fresh)
            workouts = store.cachedSessions()
            seedSportsIfNeeded()
            lastFetchAt = Date()
        } catch {
            // Keep showing cached data; only surface the error if we have nothing.
            if workouts.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// On the very first load, default to "all sports selected" so the list
    /// isn't accidentally empty before the user has touched the filter.
    private func seedSportsIfNeeded() {
        if selectedSports.isEmpty {
            selectedSports = Set(availableSports)
        }
    }
}

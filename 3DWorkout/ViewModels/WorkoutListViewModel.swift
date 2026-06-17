import Foundation

@MainActor
final class WorkoutListViewModel: ObservableObject {
    @Published private(set) var workouts: [WorkoutSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Filter state — applied lazily over the cached workouts.
    @Published var selectedSports: Set<String> = []
    @Published var dateRange: HeatmapDateRange {
        didSet {
            settings.workoutsListDateRange = dateRange
            // A wider range means more HK data — refetch.
            Task { await loadWorkouts(force: true) }
        }
    }

    private let healthKitService: HealthKitService
    private let store: WorkoutStore
    private let settings: AppSettings

    /// Last time we successfully hit HealthKit. Re-appearing this view (e.g.
    /// switching back from the Heatmap tab) within `refreshInterval` skips the
    /// HK fetch — the cached data is already shown instantly from SwiftData.
    private var lastFetchAt: Date?
    /// What `since` we used for the most recent HK fetch. Used to detect
    /// whether the current `dateRange` requires a wider fetch.
    private var lastFetchSince: Date?
    private let refreshInterval: TimeInterval = 60

    init(healthKitService: HealthKitService, store: WorkoutStore, settings: AppSettings) {
        self.healthKitService = healthKitService
        self.store = store
        self.settings = settings
        self.dateRange = settings.workoutsListDateRange
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

        let neededSince = dateRange.startDate

        // Skip the HealthKit round-trip if we refreshed recently AND we
        // already fetched at least as wide a range as the current filter.
        if !force,
           let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < refreshInterval,
           !workouts.isEmpty,
           isLastFetchWideEnough(for: neededSince) {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fresh = try await healthKitService.fetchWorkouts(since: neededSince)
            store.syncMetadata(fresh)
            workouts = store.cachedSessions()
            seedSportsIfNeeded()
            lastFetchAt = Date()
            lastFetchSince = neededSince
        } catch {
            // Keep showing cached data; only surface the error if we have nothing.
            if workouts.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Returns true when the previous fetch already covered the required
    /// window: a nil `lastFetchSince` means we've fetched everything; a wider
    /// (older) `lastFetchSince` than `needed` covers the needed window.
    private func isLastFetchWideEnough(for needed: Date?) -> Bool {
        guard let lastFetchSince else { return true }       // we have everything
        guard let needed else { return false }              // user wants everything but we only have a window
        return lastFetchSince <= needed
    }

    /// On the very first load, default to "all sports selected" so the list
    /// isn't accidentally empty before the user has touched the filter.
    private func seedSportsIfNeeded() {
        if selectedSports.isEmpty {
            selectedSports = Set(availableSports)
        }
    }
}

import Foundation

@MainActor
final class WorkoutListViewModel: ObservableObject {
    @Published private(set) var workouts: [WorkoutSession] = [] {
        didSet { recomputeDerived() }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Filter state — drives `filteredWorkouts` + `availableSports`.
    @Published var selectedSports: Set<String> = [] {
        didSet { recomputeFiltered() }
    }
    @Published var dateRange: HeatmapDateRange {
        didSet {
            settings.workoutsListDateRange = dateRange
            recomputeFiltered()
            // A wider range means more HK + SwiftData scope — refetch.
            Task { await loadWorkouts(force: true) }
        }
    }

    /// Memoized derivatives. Computed once when the source state changes —
    /// not on every SwiftUI body evaluation. With hundreds of cached
    /// workouts, the previous computed-property approach iterated the array
    /// every render and made the tab feel sluggish.
    @Published private(set) var availableSports: [String] = []
    @Published private(set) var filteredWorkouts: [WorkoutSession] = []

    private let healthKitService: HealthKitService
    private let store: WorkoutStore
    private let settings: AppSettings

    /// Last time we successfully hit HealthKit.
    private var lastFetchAt: Date?
    /// What `since` we used for the most recent HK fetch.
    private var lastFetchSince: Date?
    private let refreshInterval: TimeInterval = 60

    init(healthKitService: HealthKitService, store: WorkoutStore, settings: AppSettings) {
        self.healthKitService = healthKitService
        self.store = store
        self.settings = settings
        self.dateRange = settings.workoutsListDateRange
    }

    func loadWorkouts(force: Bool = false) async {
        guard !isLoading else { return }

        let neededSince = dateRange.startDate

        // FIRST GUARD: if we already have data, refreshed recently, and the
        // previous fetch covered the required window, do absolutely nothing.
        // This must happen *before* any SwiftData fetch — otherwise we block
        // the tab switch animation decoding the entire cache on every visit.
        if !force,
           let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < refreshInterval,
           !workouts.isEmpty,
           isLastFetchWideEnough(for: neededSince) {
            return
        }

        // Show cached workouts immediately for fresh loads. The SwiftData
        // predicate bounds the result set to the requested window so we
        // don't decode years of history when the user is on "30 days".
        if workouts.isEmpty || lastFetchSince != neededSince {
            let cached = store.cachedSessions(since: neededSince)
            if !cached.isEmpty { workouts = cached }
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fresh = try await healthKitService.fetchWorkouts(since: neededSince)
            store.syncMetadata(fresh)
            // Re-read so we pick up newly-synced rows; still bounded by since.
            workouts = store.cachedSessions(since: neededSince)
            lastFetchAt = Date()
            lastFetchSince = neededSince
        } catch {
            if workouts.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func isLastFetchWideEnough(for needed: Date?) -> Bool {
        // nil lastFetchSince means we previously fetched everything.
        guard let lastFetchSince else { return true }
        // nil needed means user wants everything but we only have a window.
        guard let needed else { return false }
        return lastFetchSince <= needed
    }

    // MARK: - Derived state

    private func recomputeDerived() {
        recomputeAvailableSports()
        recomputeFiltered()
        seedSportsIfNeeded()
    }

    private func recomputeAvailableSports() {
        availableSports = Array(Set(workouts.map(\.workoutType))).sorted()
    }

    private func recomputeFiltered() {
        let sportsFilter = selectedSports
        let startDate = dateRange.startDate
        filteredWorkouts = workouts.filter { session in
            if !sportsFilter.isEmpty, !sportsFilter.contains(session.workoutType) {
                return false
            }
            if let startDate, session.startDate < startDate { return false }
            return true
        }
    }

    private func seedSportsIfNeeded() {
        if selectedSports.isEmpty, !availableSports.isEmpty {
            selectedSports = Set(availableSports)
        }
    }
}

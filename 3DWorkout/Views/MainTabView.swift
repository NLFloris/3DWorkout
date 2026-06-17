import SwiftUI

/// Root tab container shown once HealthKit access is granted.
///
/// Owns both `WorkoutListViewModel` and `HeatmapViewModel` (+ `HeatmapIndexer`)
/// as `@StateObject`s and pre-warms them via `.task` so the first tap on
/// either tab is instant — by the time the user reaches them, the SwiftData
/// fetches, HealthKit refresh, and the heatmap indexing pass have already
/// kicked off in the background while the launch splash was playing.
struct MainTabView: View {
    let healthKitService: HealthKitService
    let store: WorkoutStore
    @EnvironmentObject var settings: AppSettings

    @StateObject private var workoutsViewModel: WorkoutListViewModel
    @StateObject private var heatmapViewModel: HeatmapViewModel
    @StateObject private var heatmapIndexer: HeatmapIndexer

    init(healthKitService: HealthKitService, store: WorkoutStore) {
        self.healthKitService = healthKitService
        self.store = store
        let appSettings = AppSettings.shared
        _workoutsViewModel = StateObject(wrappedValue: WorkoutListViewModel(
            healthKitService: healthKitService,
            store: store,
            settings: appSettings
        ))
        _heatmapViewModel = StateObject(wrappedValue: HeatmapViewModel(
            store: store,
            settings: appSettings
        ))
        _heatmapIndexer = StateObject(wrappedValue: HeatmapIndexer(
            healthKit: healthKitService,
            store: store
        ))
    }

    var body: some View {
        TabView {
            WorkoutListView(viewModel: workoutsViewModel,
                            healthKitService: healthKitService,
                            store: store)
                .tabItem {
                    Label("Workouts", systemImage: "figure.run")
                }

            HeatmapTabView(viewModel: heatmapViewModel,
                           indexer: heatmapIndexer,
                           store: store,
                           settings: settings)
                .tabItem {
                    Label("Heatmap", systemImage: "flame.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .task {
            // Pre-warm both tabs while the splash is still on screen so their
            // first tap doesn't pay for SwiftData fetches, HK round-trips, or
            // the heatmap indexing pass.
            await workoutsViewModel.loadWorkouts()
            heatmapIndexer.startIfNeeded()
            heatmapViewModel.refreshAvailableSports()
            heatmapViewModel.reaggregate()

            // When the user widens the heatmap's date range, push that wider
            // window through to the Workouts viewmodel so HealthKit covers
            // it and the indexer can pick up older workouts.
            heatmapViewModel.onDateRangeWidened = { [weak workoutsViewModel,
                                                     weak heatmapIndexer,
                                                     weak heatmapViewModel] range in
                guard let workoutsViewModel else { return }
                if Self.range(range, isWiderThan: workoutsViewModel.dateRange) {
                    workoutsViewModel.dateRange = range
                    Task {
                        await workoutsViewModel.loadWorkouts(force: true)
                        heatmapIndexer?.startIfNeeded()
                        heatmapViewModel?.refreshAvailableSports()
                        heatmapViewModel?.reaggregate()
                    }
                }
            }
        }
    }

    /// Returns true if `candidate` reaches further back in time than `current`.
    /// nil `startDate` ("All time") is the widest possible.
    private static func range(_ candidate: HeatmapDateRange,
                              isWiderThan current: HeatmapDateRange) -> Bool {
        switch (candidate.startDate, current.startDate) {
        case (nil, .some): return true
        case (nil, nil):   return false
        case (.some, nil): return false
        case (.some(let c), .some(let cur)): return c < cur
        }
    }
}

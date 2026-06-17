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
        }
    }
}

import SwiftUI

/// Root tab container shown once HealthKit access is granted.
///
/// Owns `WorkoutListViewModel` as a `@StateObject` and pre-warms it via
/// `.task` so the first tap on the Workouts tab is instant — by the time the
/// user reaches it, the cached SwiftData fetch + HealthKit refresh have
/// already happened in the background while the launch splash was playing.
struct MainTabView: View {
    let healthKitService: HealthKitService
    let store: WorkoutStore
    @EnvironmentObject var settings: AppSettings

    @StateObject private var workoutsViewModel: WorkoutListViewModel

    init(healthKitService: HealthKitService, store: WorkoutStore) {
        self.healthKitService = healthKitService
        self.store = store
        _workoutsViewModel = StateObject(wrappedValue: WorkoutListViewModel(
            healthKitService: healthKitService,
            store: store,
            settings: AppSettings.shared
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

            HeatmapTabView(store: store,
                           healthKit: healthKitService,
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
            // Pre-warm the workouts list while the splash is still on screen
            // so the first tab tap doesn't pay for the SwiftData fetch + HK
            // round-trip. The viewmodel's internal guards make this idempotent.
            await workoutsViewModel.loadWorkouts()
        }
    }
}

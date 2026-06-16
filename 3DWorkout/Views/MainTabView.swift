import SwiftUI

/// Root tab container shown once HealthKit access is granted.
struct MainTabView: View {
    let healthKitService: HealthKitService
    let store: WorkoutStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            WorkoutListView(healthKitService: healthKitService, store: store)
                .tabItem {
                    Label("Workouts", systemImage: "figure.run")
                }

            HeatmapTabView(store: store, healthKit: healthKitService, settings: settings)
                .tabItem {
                    Label("Heatmap", systemImage: "flame.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

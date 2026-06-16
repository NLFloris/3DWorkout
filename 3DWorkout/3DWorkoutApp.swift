import SwiftUI

@main
struct ThreeDWorkoutApp: App {
    @StateObject private var healthKitService = HealthKitService()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            Group {
                switch healthKitService.authorizationStatus {
                case .authorized:
                    WorkoutListView(healthKitService: healthKitService)
                        .environmentObject(healthKitService)
                case .denied, .notDetermined:
                    PermissionsView()
                        .environmentObject(healthKitService)
                }
            }
            .environmentObject(settings)
            .task { await healthKitService.refreshStatus() }
        }
    }
}

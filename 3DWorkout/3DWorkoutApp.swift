import SwiftUI

@main
struct ThreeDWorkoutApp: App {
    @StateObject private var healthKitService = HealthKitService()

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
            .task { await healthKitService.refreshStatus() }
        }
    }
}

import SwiftUI

@main
struct ThreeDWorkoutApp: App {
    @StateObject private var healthKitService = HealthKitService()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = WorkoutStore()

    /// Hides the splash once the symbol animations have had time to play.
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    switch healthKitService.authorizationStatus {
                    case .authorized:
                        MainTabView(healthKitService: healthKitService, store: store)
                            .environmentObject(healthKitService)
                    case .denied, .notDetermined:
                        PermissionsView()
                            .environmentObject(healthKitService)
                    }
                }
                .environmentObject(settings)
                .task { await healthKitService.refreshStatus() }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                // Give the symbol animations ~1.5 s to play, then crossfade
                // the splash out.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.45)) {
                    showSplash = false
                }
            }
        }
    }
}

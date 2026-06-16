import SwiftUI

/// Animated launch splash. iOS shows the static `UILaunchScreen` (a flat green
/// background, set in `Info.plist` -> `LaunchBackground` color set) instantly
/// while SwiftUI boots; then this view fades in, plays the symbol animations
/// for ~1.5 s, and the app root crossfades to `MainTabView`.
///
/// The two glyphs match the app icon exactly: a running track
/// (`point.forward.to.point.capsulepath.fill`) with a 3D-rotating dot
/// (`rotate.3d.circle.fill`) hovering above it.
struct SplashView: View {
    /// Background that matches the app-icon green (sRGB 0.018, 0.626, 0).
    private let bg = Color(red: 0.018, green: 0.626, blue: 0.000)

    @State private var trackVisible = false
    @State private var sphereVisible = false
    @State private var sphereRotation: Double = 0
    @State private var glowPulse = false
    @State private var titleVisible = false

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 8) {
                ZStack {
                    // Track — bounces in.
                    Image(systemName: "point.forward.to.point.capsulepath.fill")
                        .font(.system(size: 200, weight: .regular))
                        .foregroundStyle(.white)
                        .opacity(trackVisible ? 1 : 0)
                        .scaleEffect(trackVisible ? 1 : 0.6)
                        .symbolEffect(.bounce, options: .nonRepeating, value: trackVisible)

                    // Sphere — drops in, then spins continuously and pulses.
                    Image(systemName: "rotate.3d.circle.fill")
                        .font(.system(size: 96, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .white)
                        .offset(y: -88)
                        .opacity(sphereVisible ? 1 : 0)
                        .scaleEffect(sphereVisible ? 1 : 0.2)
                        .rotation3DEffect(.degrees(sphereRotation),
                                          axis: (x: 0, y: 1, z: 0))
                        .symbolEffect(.pulse, options: .repeating, isActive: glowPulse)
                }

                Text("3DWorkout")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 60)
                    .opacity(titleVisible ? 1 : 0)
                    .offset(y: titleVisible ? 0 : 12)
            }
        }
        .onAppear { startAnimations() }
    }

    private func startAnimations() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) {
            trackVisible = true
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.5).delay(0.18)) {
            sphereVisible = true
        }
        // Continuous 3-D rotation around the Y axis.
        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false).delay(0.4)) {
            sphereRotation = 360
        }
        glowPulse = true
        withAnimation(.easeOut(duration: 0.4).delay(0.55)) {
            titleVisible = true
        }
    }
}

#Preview {
    SplashView()
}

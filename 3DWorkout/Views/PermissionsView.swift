import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero
            ZStack {
                Circle()
                    .fill(.red.opacity(0.08))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(.red.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "figure.run")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 32)

            // Title
            VStack(spacing: 8) {
                Text("3DWorkout")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Animate your Apple Watch workouts\nas live 3D map replays.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 40)

            // Feature list
            VStack(spacing: 0) {
                FeatureRow(icon: "heart.fill",   color: .red,    title: "Heart Rate & Metrics",  subtitle: "Live HR, pace, and elevation during replay")
                Divider().padding(.leading, 56)
                FeatureRow(icon: "map.fill",      color: .blue,   title: "3D Animated Maps",      subtitle: "GPS routes with Apple Maps 3D flyover")
                Divider().padding(.leading, 56)
                FeatureRow(icon: "paintpalette.fill", color: .purple, title: "Full Customization", subtitle: "Gradient coloring by pace, HR, or elevation")
                Divider().padding(.leading, 56)
                FeatureRow(icon: "lock.shield.fill", color: .green, title: "Private by Design",   subtitle: "All data stays on your device")
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 20)

            Spacer()

            // CTA
            VStack(spacing: 12) {
                if healthKitService.authorizationStatus == .denied {
                    Text("Health access was denied in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                            .font(.body.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                } else {
                    Button {
                        Task {
                            isRequesting = true
                            defer { isRequesting = false }
                            try? await healthKitService.requestAuthorization()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isRequesting {
                                ProgressView().tint(.white).scaleEffect(0.85)
                            } else {
                                Image(systemName: "heart.fill")
                            }
                            Text(isRequesting ? "Requesting…" : "Allow Health Access")
                                .font(.body.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(isRequesting)
                }

                Text("Requires iPhone paired with Apple Watch")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var healthKitService: HealthKitService
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.red.gradient)

            VStack(spacing: 12) {
                Text("3DWorkout")
                    .font(.largeTitle.bold())
                Text("Animate your Apple Watch workouts as live 3D map replays.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 8) {
                FeatureRow(icon: "heart.fill",      color: .red,   text: "Reads workout routes & heart rate")
                FeatureRow(icon: "map.fill",         color: .blue,  text: "Animates GPS tracks in 3D")
                FeatureRow(icon: "lock.fill",        color: .green, text: "All data stays on your device")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()

            if healthKitService.authorizationStatus == .denied {
                VStack(spacing: 12) {
                    Text("Health access was denied.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                Button {
                    Task {
                        isRequesting = true
                        defer { isRequesting = false }
                        try? await healthKitService.requestAuthorization()
                    }
                } label: {
                    Label(isRequesting ? "Requesting…" : "Allow Health Access", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(isRequesting)
            }

            Spacer().frame(height: 16)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}

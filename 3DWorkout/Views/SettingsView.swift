import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $settings.unitPreference) {
                        ForEach(UnitPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                } header: {
                    Text("Measurement")
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var footerText: String {
        let resolved = settings.units.isMetric ? "metric (km, m, km/h)" : "imperial (mi, ft, mph)"
        switch settings.unitPreference {
        case .automatic:
            return "Automatic follows your device's region setting — currently \(resolved)."
        case .metric, .imperial:
            return "Distances, elevation, speed, and pace are shown in \(resolved)."
        }
    }
}

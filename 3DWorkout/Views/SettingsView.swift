import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                measurementSection
                athleteSection
                workoutViewSection
                heatmapSection
            }
            .navigationTitle("Settings")
        }
    }

    private var athleteSection: some View {
        Section {
            Stepper(value: $settings.maxHeartRate, in: 100...220, step: 1) {
                HStack {
                    Text("Max heart rate")
                    Spacer()
                    Text("\(Int(settings.maxHeartRate)) bpm")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Athlete profile")
        } footer: {
            Text("Used to split your heart-rate samples into the five standard training zones on the workout detail. A common estimate is 220 minus your age.")
        }
    }

    // MARK: - Measurement

    private var measurementSection: some View {
        Section {
            Picker("Units", selection: $settings.unitPreference) {
                ForEach(UnitPreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }
        } header: {
            Text("Measurement")
        } footer: {
            Text(measurementFooter)
        }
    }

    private var measurementFooter: String {
        let resolved = settings.units.isMetric ? "metric (km, m, km/h)" : "imperial (mi, ft, mph)"
        switch settings.unitPreference {
        case .automatic:
            return "Automatic follows your device's region setting — currently \(resolved)."
        case .metric, .imperial:
            return "Distances, elevation, speed, and pace are shown in \(resolved)."
        }
    }

    // MARK: - Workout View defaults

    private var workoutViewSection: some View {
        Section {
            Picker("Colour by", selection: $settings.defaultGradientMetric) {
                ForEach(GradientMetric.allCases) { m in
                    Text(m.displayName).tag(m.rawValue)
                }
            }

            if GradientMetric(rawValue: settings.defaultGradientMetric) == .solid {
                ColorPicker("Solid colour",
                            selection: Binding(
                                get: { Color(hex: settings.defaultRouteColorHex) },
                                set: { settings.defaultRouteColorHex = $0.toHex() }
                            ),
                            supportsOpacity: false)
            }

            Picker("Map style", selection: $settings.defaultMapStyle) {
                ForEach(MapDisplayStyle.allCases) { s in
                    Text(s.displayName).tag(s.rawValue)
                }
            }

            Toggle("3D camera", isOn: $settings.defaultIs3DMode)

            if settings.defaultIs3DMode {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Pitch")
                        Spacer()
                        Text("\(Int(settings.defaultPitch))°")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.defaultPitch, in: 0...80, step: 1)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Camera distance")
                    Spacer()
                    Text("\(Int(settings.defaultCameraDistance)) m")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.defaultCameraDistance, in: 100...2000, step: 50)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Line width")
                    Spacer()
                    Text(String(format: "%.1f", settings.defaultLineWidth))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.defaultLineWidth, in: 1...10, step: 0.5)
            }

            Picker("Playback speed", selection: $settings.defaultAnimationSpeed) {
                ForEach(AnimationSpeed.allCases) { s in
                    Text(s.displayName).tag(s.rawValue)
                }
            }
        } header: {
            Text("Workout View")
        } footer: {
            Text("These defaults are applied when you open a workout. You can still override them per workout from the customise menu.")
        }
    }

    // MARK: - Heatmap defaults

    private var heatmapSection: some View {
        Section {
            Picker("Default date range", selection: $settings.heatmapDateRange) {
                ForEach(HeatmapDateRange.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Line opacity")
                    Spacer()
                    Text("\(Int(settings.heatmapLineAlpha * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.heatmapLineAlpha, in: 0.05...1.0, step: 0.05)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Line width")
                    Spacer()
                    Text(String(format: "%.1f", settings.heatmapLineWidth))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.heatmapLineWidth, in: 1...8, step: 0.5)
            }
        } header: {
            Text("Heatmap")
        } footer: {
            Text("Lines are tinted per sport (running orange, cycling blue, walking teal, hiking green, swimming cyan) so overlapping routes brighten as they layer.")
        }
    }
}

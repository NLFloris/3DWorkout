import SwiftUI

struct CustomizationView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Route Color
                Section {
                    Picker("Color By", selection: $viewModel.gradientMetric) {
                        ForEach(GradientMetric.allCases) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    if viewModel.gradientMetric == .solid {
                        ColorPicker("Route Color", selection: $viewModel.routeColor)
                    }
                    HStack {
                        Text("Line Width")
                        Spacer()
                        Text(String(format: "%.0f pt", viewModel.lineWidth))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $viewModel.lineWidth, in: 2...12, step: 1)
                } header: {
                    Text("Route Style")
                } footer: {
                    if viewModel.gradientMetric == .heartRate && (viewModel.metrics?.heartRateSamples.isEmpty ?? true) {
                        Text("No heart rate data available for this workout.")
                    }
                }

                // MARK: Map
                Section("Map") {
                    Picker("Style", selection: $viewModel.mapStyle) {
                        ForEach(MapDisplayStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }

                    Toggle("3D Mode", isOn: $viewModel.is3DMode)

                    if viewModel.is3DMode {
                        HStack {
                            Text("Camera Pitch")
                            Spacer()
                            Text("\(Int(viewModel.pitch))°")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Slider(value: $viewModel.pitch, in: 20...75, step: 5)

                        HStack {
                            Text("Camera Distance")
                            Spacer()
                            Text("\(Int(viewModel.cameraDistance)) m")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Slider(value: $viewModel.cameraDistance, in: 100...2000, step: 50)
                    }
                }

                // MARK: Playback
                Section("Playback") {
                    Picker("Speed", selection: $viewModel.animationSpeed) {
                        ForEach(AnimationSpeed.allCases) { speed in
                            Text(speed.displayName).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Stats summary
                if let route = viewModel.route {
                    Section("Route Summary") {
                        StatRow(label: "Total Distance", value: String(format: "%.2f km", route.totalDistance / 1000))
                        StatRow(label: "Elevation Gain", value: "\(Int(route.elevationGain)) m")
                        StatRow(label: "Elevation Loss", value: "\(Int(route.elevationLoss)) m")
                        StatRow(label: "GPS Points", value: "\(route.points.count)")
                    }
                }
            }
            .navigationTitle("Customize")
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
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI
import AVKit

struct VideoExportView: View {
    @StateObject private var model: VideoExportViewModel
    @Environment(\.dismiss) private var dismiss

    init(detail: WorkoutDetailViewModel, units: UnitFormatter) {
        _model = StateObject(wrappedValue: VideoExportViewModel(detail: detail, units: units))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle:                 configForm
                case .rendering(let p):     renderingState(progress: p)
                case .finished(let url):    finishedState(url: url)
                case .failed(let message):  failedState(message: message)
                }
            }
            .navigationTitle("Share Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Configure

    private var configForm: some View {
        Form {
            Section("Format") {
                Picker("Aspect Ratio", selection: $model.config.aspect) {
                    ForEach(VideoExportConfig.Aspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Duration")
                    Spacer()
                    Text("\(Int(model.config.duration))s")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Slider(value: $model.config.duration, in: 3...15, step: 1)
            }

            Section("Overlay") {
                Toggle("Show Stats", isOn: $model.config.showStats)
                Toggle("Watermark", isOn: $model.config.showWatermark)
            }

            Section {
                Button {
                    model.export()
                } label: {
                    Label("Render Video", systemImage: "film")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
            } footer: {
                Text("Renders an animated flyover of your route with live stats. This can take a few seconds.")
            }
        }
    }

    // MARK: - Rendering

    private func renderingState(progress: Double) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.red)
                .padding(.horizontal, 40)
            Text("Rendering… \(Int(progress * 100))%")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Finished

    private func finishedState(url: URL) -> some View {
        VStack(spacing: 16) {
            VideoPlayer(player: AVPlayer(url: url))
                .aspectRatio(model.config.aspect.size, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
                .padding(.top)

            if let message = model.saveMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    model.saveToPhotos()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Button("Make Another") { model.reset() }
                .font(.subheadline)
                .padding(.bottom)

            Spacer()
        }
        .tint(.red)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Failed

    private func failedState(message: String) -> some View {
        ContentUnavailableView {
            Label("Export Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { model.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}

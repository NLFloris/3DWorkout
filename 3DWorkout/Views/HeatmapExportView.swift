import SwiftUI
import Photos
import UIKit
import MapKit

/// Sheet that renders the current heatmap to an image and lets the user save
/// it to Photos or share via the system sheet.
struct HeatmapExportView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var viewModel: HeatmapViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: HeatmapImageRenderer.Format = .portrait
    @State private var rendered: UIImage?
    @State private var rendering = false
    @State private var errorMessage: String?
    @State private var savedSuccess: Bool = false
    @State private var showingShareSheet = false

    private let renderer = HeatmapImageRenderer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                formatPicker
                Spacer(minLength: 0)
                actionButtons
            }
            .padding(16)
            .navigationTitle("Export heatmap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await rerender() }
            .onChange(of: format) { _, _ in
                Task { await rerender() }
            }
            .alert("Couldn't export",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Saved to Photos",
                   isPresented: $savedSuccess) {
                Button("OK") { savedSuccess = false }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let img = rendered {
                    ShareSheet(items: [img])
                }
            }
        }
    }

    // MARK: - Sections

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            if let img = rendered {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            } else if rendering {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "Nothing to export",
                    systemImage: "photo",
                    description: Text("Adjust the heatmap filters and the export will refresh.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
    }

    private var formatPicker: some View {
        Picker("Format", selection: $format) {
            ForEach(HeatmapImageRenderer.Format.allCases) { f in
                Text(f.displayName).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard let img = rendered else { return }
                saveToPhotos(img)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .disabled(rendered == nil || rendering)

            Button {
                showingShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(rendered == nil || rendering)
        }
    }

    // MARK: - Actions

    @MainActor
    private func rerender() async {
        rendering = true
        defer { rendering = false }

        guard let region = viewModel.currentMapRegion ?? viewModel.aggregatedBounds else {
            errorMessage = "No region to render — wait for the map to load and try again."
            return
        }

        let input = HeatmapImageRenderer.Input(
            tracks: viewModel.tracks,
            region: region,
            mapType: .standard,                // export uses the standard style for legibility
            stats: viewModel.currentStats(),
            units: settings.units,
            lineAlpha: settings.heatmapLineAlpha,
            lineWidth: settings.heatmapLineWidth * 1.5,   // a touch thicker in export so it's readable
            format: format,
            title: "Heatmap"
        )

        do {
            rendered = try await renderer.render(input)
        } catch {
            rendered = nil
            errorMessage = error.localizedDescription
        }
    }

    private func saveToPhotos(_ image: UIImage) {
        // Use PHPhotoLibrary so we can show a real "saved" alert instead of
        // relying on UIImageWriteToSavedPhotosAlbum's selector callback.
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    errorMessage = "Photos access denied. Enable it in Settings."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, err in
                Task { @MainActor in
                    if ok {
                        savedSuccess = true
                    } else {
                        errorMessage = err?.localizedDescription ?? "Couldn't save."
                    }
                }
            }
        }
    }
}

// MARK: - Share Sheet wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

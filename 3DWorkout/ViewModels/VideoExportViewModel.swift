import Foundation
import Photos
import MapKit

@MainActor
final class VideoExportViewModel: ObservableObject {
    enum State {
        case idle
        case rendering(Double)
        case finished(URL)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var config = VideoExportConfig()
    @Published var saveMessage: String?

    private let detail: WorkoutDetailViewModel
    private let units: UnitFormatter
    private let renderer = RouteVideoRenderer()

    init(detail: WorkoutDetailViewModel, units: UnitFormatter) {
        self.detail = detail
        self.units = units
        // Seed export config with the workout's current display settings so
        // "render" with no edits matches what the user is watching.
        config.mapStyle = detail.mapStyle
        config.is3DMode = detail.is3DMode
        config.pitch = detail.pitch
        config.cameraDistance = detail.cameraDistance
    }

    var canExport: Bool { detail.route != nil }

    func export() {
        guard let route = detail.route else {
            state = .failed("This workout has no route to render.")
            return
        }
        let input = RouteVideoRenderer.Input(
            route: route,
            segmentColors: detail.computedSegmentColors,
            metrics: detail.metrics,
            mapType: config.mapStyle.mkMapType,
            pitch: config.is3DMode ? config.pitch : 0,
            cameraDistance: config.cameraDistance,
            lineWidth: detail.lineWidth,
            usesPace: detail.session.usesPace,
            units: units,
            title: detail.session.workoutType,
            subtitle: detail.session.startDate.formatted(date: .abbreviated, time: .shortened),
            config: config
        )

        state = .rendering(0)
        saveMessage = nil
        Task {
            do {
                let url = try await renderer.render(input) { [weak self] progress in
                    self?.state = .rendering(progress)
                }
                state = .finished(url)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        state = .idle
        saveMessage = nil
    }

    func saveToPhotos() {
        guard case let .finished(url) = state else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self?.saveMessage = "Photo access denied. Enable it in Settings." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                Task { @MainActor in
                    self?.saveMessage = success ? "Saved to Photos" : (error?.localizedDescription ?? "Couldn't save video.")
                }
            }
        }
    }
}

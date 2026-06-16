import Foundation
import UIKit
import MapKit
import AVFoundation
import CoreVideo

/// Configuration for an exported route video.
struct VideoExportConfig {
    enum Aspect: String, CaseIterable, Identifiable {
        case vertical, square, landscape
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vertical:  return "Portrait"
            case .square:    return "Square"
            case .landscape: return "Landscape"
            }
        }
        /// Even dimensions are required by the H.264 encoder.
        var size: CGSize {
            switch self {
            case .vertical:  return CGSize(width: 1080, height: 1920)
            case .square:    return CGSize(width: 1080, height: 1080)
            case .landscape: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    var aspect: Aspect = .vertical
    var duration: Double = 6        // seconds
    var fps: Int = 30
    var showStats: Bool = true
    var showWatermark: Bool = true
}

/// Renders an animated flyover of a route to an MP4. Each frame is produced
/// deterministically (decoupled from the live playback timer): `MKMapSnapshotter`
/// draws the map tiles + 3D camera off-screen, the route/stats/watermark are
/// composited on top with Core Graphics, and frames are written with
/// `AVAssetWriter`.
///
/// Runs on the main actor; the per-frame snapshot `await` frees the main thread
/// so a progress UI stays responsive during the (multi-second) render.
@MainActor
final class RouteVideoRenderer {
    struct Input {
        let route: WorkoutRoute
        let segmentColors: [UIColor]   // per original segment (count = points - 1)
        let metrics: WorkoutMetrics?
        let mapType: MKMapType
        let pitch: Double              // 0 = top-down
        let cameraDistance: Double     // meters
        let lineWidth: CGFloat
        let usesPace: Bool
        let units: UnitFormatter
        let title: String
        let subtitle: String
        let config: VideoExportConfig
    }

    enum RenderError: LocalizedError {
        case noRoute, snapshotFailed, bufferFailed, writerFailed(String?)
        var errorDescription: String? {
            switch self {
            case .noRoute:            return "This workout has no route to render."
            case .snapshotFailed:     return "Couldn't render the map."
            case .bufferFailed:       return "Couldn't build a video frame."
            case .writerFailed(let m): return m ?? "Video export failed."
            }
        }
    }

    /// Compact, evenly-sampled drawing source so per-frame work stays bounded.
    private struct DrawData {
        let coords: [CLLocationCoordinate2D]
        let colors: [CGColor]   // count = coords.count - 1
        let dists: [Double]
        let alts: [Double]
        let speeds: [Double?]
        let times: [Date]
        var count: Int { coords.count }
    }

    private var smoothedHeading: Double = 0

    func render(_ input: Input, progress: @escaping (Double) -> Void) async throws -> URL {
        guard input.route.points.count > 1 else { throw RenderError.noRoute }

        let size = input.config.aspect.size
        let fps = Int32(max(1, input.config.fps))
        let frameCount = max(2, Int(input.config.duration * Double(input.config.fps)))
        let data = prepareDrawData(route: input.route, colors: input.segmentColors, maxPoints: 700)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("3DWorkout-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(writerInput) else { throw RenderError.writerFailed(nil) }
        writer.add(writerInput)
        guard writer.startWriting() else { throw RenderError.writerFailed(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)

        smoothedHeading = initialHeading(data)

        for i in 0..<frameCount {
            let t = Double(i) / Double(frameCount - 1)
            let headIndex = min(Int(t * Double(data.count - 1)), data.count - 1)
            let center = data.coords[headIndex]
            let heading = updatedHeading(data, at: headIndex)

            let snapshot = try await makeSnapshot(center: center, heading: heading, size: size, input: input)
            let frame = composite(snapshot: snapshot, data: data, revealed: headIndex, input: input, size: size)
            guard let buffer = pixelBuffer(from: frame, size: size) else { throw RenderError.bufferFailed }

            while !writerInput.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: fps))
            progress(Double(i + 1) / Double(frameCount))
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.writerFailed(writer.error?.localizedDescription)
        }
        return url
    }

    // MARK: - Drawing data

    private func prepareDrawData(route: WorkoutRoute, colors: [UIColor], maxPoints: Int) -> DrawData {
        let pts = route.points
        let n = pts.count
        let indices: [Int]
        if n <= maxPoints {
            indices = Array(0..<n)
        } else {
            let step = Double(n - 1) / Double(maxPoints - 1)
            indices = (0..<maxPoints).map { min(Int((Double($0) * step).rounded()), n - 1) }
        }

        var segColors: [CGColor] = []
        segColors.reserveCapacity(max(0, indices.count - 1))
        for j in 0..<max(0, indices.count - 1) {
            if colors.isEmpty {
                segColors.append(UIColor.systemBlue.cgColor)
            } else {
                segColors.append(colors[min(indices[j], colors.count - 1)].cgColor)
            }
        }

        return DrawData(
            coords: indices.map { pts[$0].coordinate },
            colors: segColors,
            dists: indices.map { pts[$0].cumulativeDistance },
            alts: indices.map { pts[$0].altitude },
            speeds: indices.map { pts[$0].speed },
            times: indices.map { pts[$0].timestamp }
        )
    }

    // MARK: - Camera heading

    private func initialHeading(_ data: DrawData) -> Double {
        bearing(from: data.coords[0], to: data.coords[min(3, data.count - 1)])
    }

    private func updatedHeading(_ data: DrawData, at index: Int) -> Double {
        let lookahead = min(index + 4, data.count - 1)
        guard lookahead > index else { return smoothedHeading }
        let raw = bearing(from: data.coords[index], to: data.coords[lookahead])
        let diff = ((raw - smoothedHeading) + 540).truncatingRemainder(dividingBy: 360) - 180
        smoothedHeading = (smoothedHeading + diff * 0.2 + 360).truncatingRemainder(dividingBy: 360)
        return smoothedHeading
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Great-circle distance in meters between two coordinates (Haversine).
    private func metersBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * atan2(sqrt(h), sqrt(1 - h))
    }

    // MARK: - Snapshotting

    private func makeSnapshot(center: CLLocationCoordinate2D, heading: Double,
                              size: CGSize, input: Input) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 1   // 1 pt == 1 px so point(for:) maps directly to output pixels
        // MKMapSnapshotter doesn't support the flyover map types; fall back to
        // their static equivalents so a "Flyover" style still renders.
        switch input.mapType {
        case .satelliteFlyover: options.mapType = .satellite
        case .hybridFlyover:    options.mapType = .hybrid
        default:                options.mapType = input.mapType
        }
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: input.cameraDistance,
            pitch: CGFloat(input.pitch),
            heading: heading
        )
        options.showsBuildings = true

        let snapshotter = MKMapSnapshotter(options: options)
        return try await withCheckedThrowingContinuation { cont in
            snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snapshot, error in
                if let snapshot {
                    cont.resume(returning: snapshot)
                } else {
                    cont.resume(throwing: error ?? RenderError.snapshotFailed)
                }
            }
        }
    }

    // MARK: - Compositing

    private func composite(snapshot: MKMapSnapshotter.Snapshot, data: DrawData,
                           revealed: Int, input: Input, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // match the snapshot scale; output is exactly size in pixels
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererCtx in
            let cg = rendererCtx.cgContext
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))

            // Revealed route polyline. GPS gaps (signal loss, tunnels, paused
            // recording) can leave neighbouring samples hundreds of meters
            // apart; drawing a straight line between them produces the long
            // off-axis bands the user reported. Skip any segment whose
            // straight-line distance exceeds a generous gap threshold.
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(max(3, input.lineWidth * 1.6))
            let gapThresholdMeters = 200.0
            for j in 0..<revealed {
                let c0 = data.coords[j]
                let c1 = data.coords[j + 1]
                if metersBetween(c0, c1) > gapThresholdMeters { continue }
                let p0 = snapshot.point(for: c0)
                let p1 = snapshot.point(for: c1)
                cg.setStrokeColor(data.colors[min(j, data.colors.count - 1)])
                cg.beginPath()
                cg.move(to: p0)
                cg.addLine(to: p1)
                cg.strokePath()
            }

            // Current position marker.
            let head = snapshot.point(for: data.coords[revealed])
            drawMarker(cg, at: head)

            if input.config.showStats {
                drawStats(cg, data: data, revealed: revealed, input: input, size: size)
            }
            if input.config.showWatermark {
                drawWatermark(cg, size: size)
            }
        }
    }

    private func drawMarker(_ cg: CGContext, at p: CGPoint) {
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        cg.setFillColor(UIColor.systemRed.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
    }

    private func drawStats(_ cg: CGContext, data: DrawData, revealed: Int, input: Input, size: CGSize) {
        let units = input.units
        let elapsed = data.times[revealed].timeIntervalSince(data.times[0])
        let speed = data.speeds[revealed] ?? 0
        let hr = input.metrics?.heartRate(at: data.times[revealed])

        // Bottom scrim for legibility.
        let scrimHeight = size.height * 0.26
        let scrimRect = CGRect(x: 0, y: size.height - scrimHeight, width: size.width, height: scrimHeight)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.72).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            cg.saveGState()
            cg.clip(to: scrimRect)
            cg.drawLinearGradient(gradient,
                                  start: CGPoint(x: 0, y: scrimRect.minY),
                                  end: CGPoint(x: 0, y: scrimRect.maxY),
                                  options: [])
            cg.restoreGState()
        }

        let margin: CGFloat = 40
        // Hero: distance + elapsed time.
        drawText(units.distance(data.dists[revealed]),
                 font: .systemFont(ofSize: 64, weight: .heavy), color: .white,
                 at: CGPoint(x: margin, y: size.height - 150))
        drawText(format(elapsed),
                 font: .monospacedDigitSystemFont(ofSize: 30, weight: .semibold),
                 color: UIColor.white.withAlphaComponent(0.85),
                 at: CGPoint(x: margin, y: size.height - 78))

        // Secondary row: pace/speed, heart rate, elevation.
        let paceText = input.usesPace
            ? "\(units.pace(speed))\(units.paceUnit)"
            : "\(units.speed(speed)) \(units.speedUnit)"
        let hrText = hr.map { "\(Int($0)) bpm" } ?? "-- bpm"
        let elevText = units.elevation(data.alts[revealed])
        let secondary = [paceText, hrText, elevText].joined(separator: "   •   ")
        drawText(secondary,
                 font: .systemFont(ofSize: 26, weight: .medium),
                 color: UIColor.white.withAlphaComponent(0.9),
                 at: CGPoint(x: margin, y: size.height - 78),
                 alignedRight: size.width - margin)

        // Title + date, top-left.
        drawText(input.title,
                 font: .systemFont(ofSize: 34, weight: .bold), color: .white,
                 at: CGPoint(x: margin, y: 64))
        drawText(input.subtitle,
                 font: .systemFont(ofSize: 22, weight: .medium),
                 color: UIColor.white.withAlphaComponent(0.85),
                 at: CGPoint(x: margin, y: 108))
    }

    private func drawWatermark(_ cg: CGContext, size: CGSize) {
        drawText("3DWorkout",
                 font: .systemFont(ofSize: 22, weight: .semibold),
                 color: UIColor.white.withAlphaComponent(0.65),
                 at: CGPoint(x: 0, y: size.height - 40),
                 alignedRight: size.width - 40)
    }

    /// Draws a single line of text. When `alignedRight` is set, the text is
    /// right-aligned to that x; otherwise left-aligned at `point`.
    private func drawText(_ string: String, font: UIFont, color: UIColor,
                          at point: CGPoint, alignedRight: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        var origin = point
        if let rightX = alignedRight {
            origin.x = rightX - attributed.size().width
        }
        attributed.draw(at: origin)
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Pixel buffer

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32ARGB, attrs, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

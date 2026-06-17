import Foundation
import UIKit
import MapKit
import CoreLocation

/// Renders the heatmap to a single `UIImage` for sharing or saving. Mirrors the
/// shape of `RouteVideoRenderer` but produces one frame:
///   1. `MKMapSnapshotter` paints the map for the visible region.
///   2. Every track is stroked on top as a semi-transparent per-sport polyline.
///   3. A glassy dark stats card is composited along the bottom: workout count,
///      total distance, total time, date range, and a per-sport legend.
///
/// All Core Graphics work happens inside `UIGraphicsImageRenderer`; the
/// snapshotter callback is dispatched on a background queue so the main thread
/// stays responsive.
@MainActor
final class HeatmapImageRenderer {
    enum Format: String, CaseIterable, Identifiable {
        case portrait, square, landscape
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .portrait:  return "Portrait"
            case .square:    return "Square"
            case .landscape: return "Landscape"
            }
        }
        var size: CGSize {
            switch self {
            case .portrait:  return CGSize(width: 1080, height: 1920)
            case .square:    return CGSize(width: 1080, height: 1080)
            case .landscape: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    struct Input {
        let tracks: [HeatmapTrack]
        let region: MKCoordinateRegion
        let mapType: MKMapType
        let stats: HeatmapStats
        let units: UnitFormatter
        let lineAlpha: Double
        let lineWidth: Double
        let format: Format
        let title: String
    }

    enum RenderError: LocalizedError {
        case snapshotFailed(String?)
        var errorDescription: String? {
            switch self {
            case .snapshotFailed(let m): return m ?? "Couldn't render the map."
            }
        }
    }

    func render(_ input: Input) async throws -> UIImage {
        let size = input.format.size
        let snapshot = try await makeSnapshot(region: input.region,
                                              mapType: input.mapType,
                                              size: size)
        return composite(snapshot: snapshot, input: input, size: size)
    }

    // MARK: - Map snapshot

    private func makeSnapshot(region: MKCoordinateRegion,
                              mapType: MKMapType,
                              size: CGSize) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 1   // 1 pt == 1 px so point(for:) maps directly to output pixels
        // MKMapSnapshotter doesn't support the flyover map types; fall back
        // to their static equivalents.
        switch mapType {
        case .satelliteFlyover: options.mapType = .satellite
        case .hybridFlyover:    options.mapType = .hybrid
        default:                options.mapType = mapType
        }
        options.region = region
        options.showsBuildings = true

        let snapshotter = MKMapSnapshotter(options: options)
        return try await withCheckedThrowingContinuation { cont in
            snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, error in
                if let snap {
                    cont.resume(returning: snap)
                } else {
                    cont.resume(throwing: RenderError.snapshotFailed(error?.localizedDescription))
                }
            }
        }
    }

    // MARK: - Compositing

    private func composite(snapshot: MKMapSnapshotter.Snapshot,
                           input: Input,
                           size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))

            drawTracks(cg, snapshot: snapshot, input: input, size: size)
            drawStatsCard(cg, input: input, size: size)
            drawTitle(cg, title: input.title, size: size)
            drawWatermark(cg, size: size)
        }
    }

    private func drawTracks(_ cg: CGContext,
                            snapshot: MKMapSnapshotter.Snapshot,
                            input: Input,
                            size: CGSize) {
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(max(2.0, CGFloat(input.lineWidth)))

        // Tracks come from CachedHeatmapTrack which is already
        // Douglas-Peucker simplified by HeatmapIndexer — long straight
        // sections collapse to a few long segments. A gap filter here would
        // tear those into "holes", so we draw the polyline straight through
        // and trust the indexer to have rejected dropouts upstream.
        for track in input.tracks where track.coordinates.count >= 2 {
            cg.setStrokeColor(
                HeatmapStyle.uiColor(for: track.sportType, alpha: input.lineAlpha).cgColor
            )
            cg.beginPath()
            cg.move(to: snapshot.point(for: track.coordinates[0]))
            for i in 1..<track.coordinates.count {
                cg.addLine(to: snapshot.point(for: track.coordinates[i]))
            }
            cg.strokePath()
        }
    }

    private func drawStatsCard(_ cg: CGContext, input: Input, size: CGSize) {
        // Glassy dark gradient along the bottom 30%.
        let cardHeight = size.height * 0.28
        let cardRect = CGRect(x: 0, y: size.height - cardHeight,
                              width: size.width, height: cardHeight)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor.black.withAlphaComponent(0.0).cgColor,
                UIColor.black.withAlphaComponent(0.85).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            cg.saveGState()
            cg.clip(to: cardRect)
            cg.drawLinearGradient(gradient,
                                  start: CGPoint(x: 0, y: cardRect.minY),
                                  end:   CGPoint(x: 0, y: cardRect.maxY),
                                  options: [])
            cg.restoreGState()
        }

        let margin: CGFloat = 48
        let baseY = size.height - cardHeight + 28

        // Date range pill
        drawPill(cg, text: input.stats.dateRangeLabel,
                 origin: CGPoint(x: margin, y: baseY))

        // Hero: total distance + workout count
        let distanceText = input.units.distance(input.stats.totalDistanceMeters, decimals: 1)
        drawText(distanceText,
                 font: .systemFont(ofSize: 88, weight: .heavy),
                 color: .white,
                 at: CGPoint(x: margin, y: baseY + 50))

        let countText = "\(input.stats.workoutCount) workouts · \(formatDuration(input.stats.totalDurationSeconds))"
        drawText(countText,
                 font: .systemFont(ofSize: 28, weight: .medium),
                 color: UIColor.white.withAlphaComponent(0.85),
                 at: CGPoint(x: margin, y: baseY + 152))

        // Per-sport legend along the bottom
        drawSportLegend(cg,
                        perSport: input.stats.perSport,
                        units: input.units,
                        topY: baseY + 198,
                        leftX: margin,
                        rightX: size.width - margin)
    }

    private func drawSportLegend(_ cg: CGContext,
                                 perSport: [(sport: String, count: Int, distanceMeters: Double)],
                                 units: UnitFormatter,
                                 topY: CGFloat,
                                 leftX: CGFloat,
                                 rightX: CGFloat) {
        guard !perSport.isEmpty else { return }
        var x = leftX
        let y = topY
        let chipDot: CGFloat = 12
        let chipSpacing: CGFloat = 18

        for entry in perSport {
            let label = "\(entry.sport) · \(units.distance(entry.distanceMeters, decimals: 0))"
            let chipText = NSAttributedString(string: label, attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.white
            ])
            let textW = chipText.size().width
            let chipWidth = chipDot + 8 + textW

            // Wrap to next row if we run out of width.
            if x + chipWidth > rightX { break }

            cg.setFillColor(
                HeatmapStyle.uiColor(for: entry.sport, alpha: 1.0).cgColor
            )
            cg.fillEllipse(in: CGRect(x: x, y: y + 6, width: chipDot, height: chipDot))

            chipText.draw(at: CGPoint(x: x + chipDot + 8, y: y))
            x += chipWidth + chipSpacing
        }
    }

    private func drawPill(_ cg: CGContext, text: String, origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let padH: CGFloat = 16
        let padV: CGFloat = 8
        let rect = CGRect(x: origin.x, y: origin.y,
                          width: textSize.width + padH * 2,
                          height: textSize.height + padV * 2)
        cg.setFillColor(UIColor.white.withAlphaComponent(0.18).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
        cg.addPath(path)
        cg.fillPath()
        attr.draw(at: CGPoint(x: rect.minX + padH, y: rect.minY + padV))
    }

    private func drawTitle(_ cg: CGContext, title: String, size: CGSize) {
        // Title sits at the top with a soft shadow scrim so it reads over the
        // map without dominating it.
        let scrim = CGRect(x: 0, y: 0, width: size.width, height: 200)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor.black.withAlphaComponent(0.55).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            cg.saveGState()
            cg.clip(to: scrim)
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: scrim.maxY),
                                  options: [])
            cg.restoreGState()
        }
        drawText(title,
                 font: .systemFont(ofSize: 44, weight: .heavy),
                 color: .white,
                 at: CGPoint(x: 48, y: 64))
    }

    private func drawWatermark(_ cg: CGContext, size: CGSize) {
        drawText("3DWorkout",
                 font: .systemFont(ofSize: 24, weight: .semibold),
                 color: UIColor.white.withAlphaComponent(0.65),
                 at: CGPoint(x: 0, y: size.height - 48),
                 alignedRight: size.width - 48)
    }

    // MARK: - Helpers

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

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

}

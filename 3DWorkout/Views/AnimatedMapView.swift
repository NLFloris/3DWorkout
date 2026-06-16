import SwiftUI
import MapKit
import Combine
import QuartzCore

struct AnimatedMapView: UIViewRepresentable {
    @ObservedObject var viewModel: WorkoutDetailViewModel

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.showsUserLocation = false
        map.showsCompass = true
        map.showsScale = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.mapView = map
        context.coordinator.update(with: viewModel)
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var viewModel: WorkoutDetailViewModel
        weak var mapView: MKMapView?
        private var cancellables = Set<AnyCancellable>()

        // Single overlay for the whole route. The renderer paints every
        // revealed segment in one Core Graphics pass and then paints the
        // playback marker (white halo + red dot) immediately on top of the
        // line — that's the only way to keep the marker above the polyline
        // in iOS 26's MapKit, where bringSubviewToFront / zPosition on
        // MKAnnotationView are ignored in pitched 3D mode.
        private var routeOverlay: MKPolyline?
        private weak var routeRenderer: GradientRouteRenderer?
        private var revealedSegmentIndex: Int = -1
        private var segmentColors: [UIColor] = []
        private var routeCoords: [CLLocationCoordinate2D] = []

        private var lastRouteID: UUID?
        private var lastGradientMetric: GradientMetric?
        private var lastMapStyle: MapDisplayStyle?
        private var lastLineWidth: CGFloat?
        private var hasFramed = false

        // Sub-threshold camera updates are filtered to spare MapKit a relayout.
        private var lastCameraCoord: CLLocationCoordinate2D?
        private var lastCameraHeading: CLLocationDirection = .nan
        private var lastCameraDistance: Double = .nan
        private var lastCameraPitch: Double = .nan
        private let coordEpsilonDeg: Double = 1.0 / 111_000.0   // ~1 m
        private let headingEpsilonDeg: Double = 0.5
        private let distanceEpsilonM: Double = 1.0
        private let pitchEpsilonDeg: Double = 0.5

        init(viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            super.init()

            viewModel.animator.$currentPointIndex
                .removeDuplicates()
                .sink { [weak self] index in
                    guard let self, let map = self.mapView else { return }
                    self.applyRevealedPointIndex(index)
                    self.updateCamera(on: map)
                }
                .store(in: &cancellables)
        }

        func update(with viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            guard let map = mapView else { return }

            if lastMapStyle != viewModel.mapStyle {
                map.mapType = viewModel.mapStyle.mkMapType
                lastMapStyle = viewModel.mapStyle
            }

            let routeChanged = viewModel.routeID != nil && viewModel.routeID != lastRouteID
            let metricChanged = lastGradientMetric != viewModel.gradientMetric
            let widthChanged  = lastLineWidth != viewModel.lineWidth

            if routeChanged {
                rebuildOverlay(on: map)
            } else if metricChanged {
                refreshSegmentColors()
            } else if widthChanged {
                refreshLineWidth()
            }

            updateCamera(on: map)
        }

        // MARK: - Overlay lifecycle

        private func rebuildOverlay(on map: MKMapView) {
            if let old = routeOverlay {
                map.removeOverlay(old)
            }
            routeOverlay = nil
            routeRenderer = nil
            revealedSegmentIndex = -1
            routeCoords = []

            guard let route = viewModel.route, route.points.count > 1 else { return }

            segmentColors = viewModel.computedSegmentColors
            routeCoords = route.points.map(\.coordinate)
            lastRouteID = viewModel.routeID
            lastGradientMetric = viewModel.gradientMetric
            lastLineWidth = viewModel.lineWidth

            var coords = routeCoords
            let polyline = MKPolyline(coordinates: &coords, count: coords.count)
            routeOverlay = polyline
            map.addOverlay(polyline, level: .aboveLabels)

            let initialPointIndex = viewModel.animator.isPlaying
                ? viewModel.animator.currentPointIndex
                : route.points.count - 1
            applyRevealedPointIndex(initialPointIndex)

            if !hasFramed {
                map.setRegion(route.boundingRegion, animated: false)
                hasFramed = true
            }
        }

        private func refreshSegmentColors() {
            lastGradientMetric = viewModel.gradientMetric
            segmentColors = viewModel.computedSegmentColors
            routeRenderer?.segmentColors = segmentColors
            routeRenderer?.setNeedsDisplay()
        }

        private func refreshLineWidth() {
            lastLineWidth = viewModel.lineWidth
            routeRenderer?.lineWidth = viewModel.lineWidth
            routeRenderer?.setNeedsDisplay()
        }

        // MARK: - Reveal progress

        private func applyRevealedPointIndex(_ pointIndex: Int) {
            // Segment i connects point i → point i+1. After reaching point K
            // segments 0…K-1 are revealed.
            let segmentCount = max(0, routeCoords.count - 1)
            let target = min(pointIndex - 1, segmentCount - 1)
            let newRevealed = max(-1, target)
            guard newRevealed != revealedSegmentIndex else { return }
            revealedSegmentIndex = newRevealed
            routeRenderer?.revealedSegmentIndex = newRevealed
            routeRenderer?.setNeedsDisplay()
        }

        // MARK: - Camera

        private func updateCamera(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate else { return }
            let heading = viewModel.animator.currentHeading
            let distance = viewModel.cameraDistance
            let pitch = viewModel.is3DMode ? viewModel.pitch : 0

            if let last = lastCameraCoord,
               !lastCameraHeading.isNaN,
               !lastCameraDistance.isNaN,
               !lastCameraPitch.isNaN,
               abs(last.latitude - coord.latitude) < coordEpsilonDeg,
               abs(last.longitude - coord.longitude) < coordEpsilonDeg,
               headingDelta(last: lastCameraHeading, new: heading) < headingEpsilonDeg,
               abs(lastCameraDistance - distance) < distanceEpsilonM,
               abs(lastCameraPitch - pitch) < pitchEpsilonDeg {
                return
            }

            let camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: distance,
                pitch: CGFloat(pitch),
                heading: heading
            )
            map.setCamera(camera, animated: !viewModel.animator.isPlaying)

            lastCameraCoord = coord
            lastCameraHeading = heading
            lastCameraDistance = distance
            lastCameraPitch = pitch
        }

        private func headingDelta(last: CLLocationDirection, new: CLLocationDirection) -> Double {
            let raw = abs(new - last).truncatingRemainder(dividingBy: 360)
            return min(raw, 360 - raw)
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline,
                  polyline === routeOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = GradientRouteRenderer(overlay: polyline)
            renderer.coords = routeCoords
            renderer.segmentColors = segmentColors
            renderer.revealedSegmentIndex = revealedSegmentIndex
            renderer.lineWidth = viewModel.lineWidth
            routeRenderer = renderer
            return renderer
        }
    }
}

// MARK: - Gradient Route Renderer

/// One overlay renderer that paints the gradient route *and* the playback dot.
/// Painting the dot at the end of the same `draw(_:zoomScale:in:)` is the only
/// reliable way to keep it above the polyline — in iOS 26 MapKit renders the
/// overlay layer above the `MKAnnotationContainerView` in pitched 3D mode,
/// which used to swallow the marker.
private final class GradientRouteRenderer: MKOverlayRenderer {
    var coords: [CLLocationCoordinate2D] = []
    var segmentColors: [UIColor] = []
    var revealedSegmentIndex: Int = -1
    var lineWidth: CGFloat = 4.0

    override func draw(_ mapRect: MKMapRect,
                       zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard coords.count > 1 else { return }

        // 1) Polyline — revealed portion only.
        if revealedSegmentIndex >= 0 {
            drawRevealedSegments(mapRect: mapRect,
                                 zoomScale: zoomScale,
                                 context: context)
        }

        // 2) Playback dot — last thing painted, so it sits on top of the
        //    polyline even when both occupy the same pixel in pitched 3D.
        drawPlaybackDot(mapRect: mapRect,
                        zoomScale: zoomScale,
                        context: context)
    }

    private func drawRevealedSegments(mapRect: MKMapRect,
                                      zoomScale: MKZoomScale,
                                      context: CGContext) {
        // MapKit's context is in map-point space; scaling the stroke by
        // 1/zoomScale keeps the line a constant screen width regardless
        // of zoom level.
        let strokeWidth = lineWidth / CGFloat(zoomScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)

        let padded = mapRect.insetBy(dx: -mapRect.size.width * 0.1,
                                     dy: -mapRect.size.height * 0.1)

        let lastIdx = min(revealedSegmentIndex, coords.count - 2)
        for i in 0...lastIdx {
            let mp0 = MKMapPoint(coords[i])
            let mp1 = MKMapPoint(coords[i + 1])
            let segRect = MKMapRect(
                x: min(mp0.x, mp1.x),
                y: min(mp0.y, mp1.y),
                width: abs(mp0.x - mp1.x),
                height: abs(mp0.y - mp1.y)
            )
            guard padded.intersects(segRect) else { continue }

            let p0 = self.point(for: mp0)
            let p1 = self.point(for: mp1)
            let color = i < segmentColors.count ? segmentColors[i] : UIColor.systemBlue
            context.beginPath()
            context.move(to: p0)
            context.addLine(to: p1)
            context.setStrokeColor(color.cgColor)
            context.strokePath()
        }
    }

    private func drawPlaybackDot(mapRect: MKMapRect,
                                 zoomScale: MKZoomScale,
                                 context: CGContext) {
        // Current playback point is the head endpoint of the last revealed
        // segment, clamped into a valid index.
        let headIdx = max(0, min(revealedSegmentIndex + 1, coords.count - 1))
        let head = MKMapPoint(coords[headIdx])

        // Skip if the head isn't in (or near) the tile being painted, so
        // adjacent tiles don't end up with a stale dot.
        let padding = 50.0 / Double(zoomScale)
        let padded = mapRect.insetBy(dx: -padding, dy: -padding)
        guard padded.contains(head) else { return }

        let p = self.point(for: head)
        let outerRadius: CGFloat = 11 / CGFloat(zoomScale)  // 22 pt diameter
        let innerRadius: CGFloat = 7  / CGFloat(zoomScale)  // 14 pt diameter

        // White halo with a soft drop shadow for separation from the map.
        context.saveGState()
        context.setShadow(offset: .zero,
                          blur: 6 / CGFloat(zoomScale),
                          color: UIColor.black.withAlphaComponent(0.40).cgColor)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - outerRadius,
                                       y: p.y - outerRadius,
                                       width: outerRadius * 2,
                                       height: outerRadius * 2))
        context.restoreGState()

        // Red core.
        context.setFillColor(UIColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - innerRadius,
                                       y: p.y - innerRadius,
                                       width: innerRadius * 2,
                                       height: innerRadius * 2))
    }
}

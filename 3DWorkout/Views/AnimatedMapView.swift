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
        context.coordinator.attachMarkerIfNeeded(on: map)
        context.coordinator.update(with: viewModel)
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var viewModel: WorkoutDetailViewModel
        weak var mapView: MKMapView?
        private var cancellables = Set<AnyCancellable>()

        // Single overlay for the whole route. The renderer paints every
        // revealed segment in one Core Graphics pass.
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

        // Sub-threshold camera updates are filtered.
        private var lastCameraCoord: CLLocationCoordinate2D?
        private var lastCameraHeading: CLLocationDirection = .nan
        private var lastCameraDistance: Double = .nan
        private var lastCameraPitch: Double = .nan
        private let coordEpsilonDeg: Double = 1.0 / 111_000.0   // ~1 m
        private let headingEpsilonDeg: Double = 0.5
        private let distanceEpsilonM: Double = 1.0
        private let pitchEpsilonDeg: Double = 0.5

        // Position marker. Painted via a CALayer added directly to the
        // MKMapView's layer hierarchy — not via the overlay renderer, not via
        // an MKAnnotation — so it's screen-space, atomic to update, and
        // always on top regardless of 3D pitch, tile boundaries, or MapKit's
        // overlay layer ordering. Earlier approaches all suffered from one
        // or more of: tile boundary "two dots" during playback (renderer),
        // covered-by-polyline in 3D pitch (annotation), or
        // _UIReparentingView warnings (subview).
        private let markerLayer: CALayer = Coordinator.makeMarkerLayer()
        private var markerAttached = false
        private var markerCoord: CLLocationCoordinate2D?

        init(viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            super.init()

            viewModel.animator.$currentPointIndex
                .removeDuplicates()
                .sink { [weak self] index in
                    guard let self, let map = self.mapView else { return }
                    self.applyRevealedPointIndex(index)
                    self.updateCamera(on: map)
                    self.updateMarker(on: map)
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
            updateMarker(on: map)
        }

        func attachMarkerIfNeeded(on map: MKMapView) {
            guard !markerAttached else { return }
            map.layer.addSublayer(markerLayer)
            markerAttached = true
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

            updateMarker(on: map)
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
            let segmentCount = max(0, routeCoords.count - 1)
            let target = min(pointIndex - 1, segmentCount - 1)
            let newRevealed = max(-1, target)
            guard newRevealed != revealedSegmentIndex else { return }
            revealedSegmentIndex = newRevealed
            routeRenderer?.revealedSegmentIndex = newRevealed
            routeRenderer?.setNeedsDisplay()
        }

        // MARK: - Marker

        /// Re-pin the screen-space marker to whatever screen pixel its
        /// coordinate currently projects to.
        private func updateMarker(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate,
                  CLLocationCoordinate2DIsValid(coord) else { return }
            markerCoord = coord
            let screen = map.convert(coord, toPointTo: map)
            // Disable Core Animation's implicit position tween so the marker
            // snaps to the new spot instead of trailing the polyline head.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markerLayer.position = screen
            markerLayer.isHidden = false
            CATransaction.commit()
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

        /// Keep the marker pinned during user pan / zoom + while MapKit
        /// animates a camera setCamera transition.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard markerCoord != nil else { return }
            updateMarker(on: mapView)
        }

        // MARK: - Marker layer

        private static func makeMarkerLayer() -> CALayer {
            // Outer white halo with a drop shadow.
            let outer = CALayer()
            outer.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
            outer.backgroundColor = UIColor.white.cgColor
            outer.cornerRadius = 11
            outer.shadowColor = UIColor.black.cgColor
            outer.shadowOpacity = 0.35
            outer.shadowRadius = 4
            outer.shadowOffset = .zero
            outer.zPosition = 999_999
            // Skip implicit animation on position changes — we drive these
            // ourselves and don't want the dot lerping behind the polyline.
            outer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "hidden": NSNull()
            ]
            outer.isHidden = true

            // Red core.
            let inner = CALayer()
            inner.frame = CGRect(x: 4, y: 4, width: 14, height: 14)
            inner.backgroundColor = UIColor.systemRed.cgColor
            inner.cornerRadius = 7
            inner.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull()
            ]
            outer.addSublayer(inner)
            return outer
        }
    }
}

// MARK: - Gradient Route Renderer

/// Draws every revealed segment of the route in a single Core Graphics pass.
/// The playback marker is now handled by a CALayer in `AnimatedMapView.Coordinator`
/// — drawing the dot in the renderer caused per-tile duplicate-dot artifacts
/// while the head moved across tile boundaries during playback.
private final class GradientRouteRenderer: MKOverlayRenderer {
    var coords: [CLLocationCoordinate2D] = []
    var segmentColors: [UIColor] = []
    var revealedSegmentIndex: Int = -1
    var lineWidth: CGFloat = 4.0

    override func draw(_ mapRect: MKMapRect,
                       zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard revealedSegmentIndex >= 0, coords.count > 1 else { return }
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
}

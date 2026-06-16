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
        // The current-position marker is a plain subview pinned to a
        // coordinate, not an MKAnnotation — MapKit animates KVO-driven
        // annotation coordinate changes over ~250 ms which made the marker
        // lag behind the polyline reveal during fast playback ("two dots").
        map.addSubview(context.coordinator.positionMarkerView)
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

        // All segment polylines, built once per route and added to the map a
        // single time. Reveal progress is communicated to the renderers via
        // `revealedSegmentIndex` and `setNeedsDisplay()` calls — never by
        // adding or removing overlays mid-playback.
        private var segmentOverlays: [MKPolyline] = []
        private var segmentColors: [UIColor] = []
        private var segmentRenderers: [Int: RouteSegmentRenderer] = [:]

        // Highest segment index that should currently be drawn. -1 = none.
        fileprivate var revealedSegmentIndex: Int = -1

        private var lastRouteID: UUID?
        private var lastGradientMetric: GradientMetric?
        private var lastMapStyle: MapDisplayStyle?
        private var lastLineWidth: CGFloat?
        private var hasFramed = false

        // Skip camera updates that would move the camera by less than these
        // thresholds — MapKit's layout pass for sub-meter / sub-degree changes
        // is wasted work and causes the marker/line desync.
        private var lastCameraCoord: CLLocationCoordinate2D?
        private var lastCameraHeading: CLLocationDirection = .nan
        private var lastCameraDistance: Double = .nan
        private var lastCameraPitch: Double = .nan
        private let coordEpsilonDeg: Double = 1.0 / 111_000.0   // ~1 m
        private let headingEpsilonDeg: Double = 0.5
        private let distanceEpsilonM: Double = 1.0
        private let pitchEpsilonDeg: Double = 0.5

        // Live position marker — a UIView pinned to a coordinate. We
        // reposition it on every animator tick and on every map-region
        // change so it cannot lag behind the polyline head.
        let positionMarkerView: UIView = {
            let v = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
            v.backgroundColor = .systemRed
            v.layer.cornerRadius = 9
            v.layer.borderColor = UIColor.white.cgColor
            v.layer.borderWidth = 2.5
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = 0.35
            v.layer.shadowRadius = 4
            v.layer.shadowOffset = .zero
            v.isUserInteractionEnabled = false
            v.layer.zPosition = 1000
            v.isHidden = true
            return v
        }()
        private var positionMarkerCoord: CLLocationCoordinate2D?

        init(viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            super.init()

            // Drive camera + segment reveal from animator ticks via Combine.
            viewModel.animator.$currentPointIndex
                .removeDuplicates()
                .sink { [weak self] index in
                    guard let self, let map = self.mapView else { return }
                    self.applyRevealedPointIndex(index)
                    self.updateCamera(on: map)
                    self.updatePositionMarker(on: map)
                }
                .store(in: &cancellables)
        }

        // Called from updateUIView – detect what changed and apply minimal updates
        func update(with viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            guard let map = mapView else { return }

            // Map type
            if lastMapStyle != viewModel.mapStyle {
                map.mapType = viewModel.mapStyle.mkMapType
                lastMapStyle = viewModel.mapStyle
            }

            let routeChanged = viewModel.routeID != nil && viewModel.routeID != lastRouteID
            let metricChanged = lastGradientMetric != viewModel.gradientMetric
            let widthChanged  = lastLineWidth != viewModel.lineWidth

            if routeChanged {
                rebuildOverlays(on: map)
            } else if metricChanged {
                refreshSegmentColors()
            } else if widthChanged {
                refreshSegmentLineWidths()
            }

            updateCamera(on: map)
        }

        // MARK: - Overlay lifecycle

        private func rebuildOverlays(on map: MKMapView) {
            map.removeOverlays(segmentOverlays)
            segmentOverlays.removeAll(keepingCapacity: true)
            segmentRenderers.removeAll(keepingCapacity: true)
            revealedSegmentIndex = -1

            guard let route = viewModel.route, route.points.count > 1 else { return }

            segmentColors = viewModel.computedSegmentColors
            lastRouteID = viewModel.routeID
            lastGradientMetric = viewModel.gradientMetric
            lastLineWidth = viewModel.lineWidth

            var polylines: [MKPolyline] = []
            polylines.reserveCapacity(route.points.count - 1)
            for i in 0..<(route.points.count - 1) {
                var coords = [route.points[i].coordinate, route.points[i + 1].coordinate]
                let p = MKPolyline(coordinates: &coords, count: 2)
                p.title = "\(i)"
                polylines.append(p)
            }
            segmentOverlays = polylines
            map.addOverlays(polylines, level: .aboveRoads)

            // When not animating, reveal the full route immediately so the static
            // view looks correct.
            let initialPointIndex = viewModel.animator.isPlaying
                ? viewModel.animator.currentPointIndex
                : route.points.count - 1
            applyRevealedPointIndex(initialPointIndex)

            if !hasFramed {
                map.setRegion(route.boundingRegion, animated: false)
                hasFramed = true
            }

            updatePositionMarker(on: map)
        }

        /// Update strokeColors of existing renderers without rebuilding overlays.
        private func refreshSegmentColors() {
            lastGradientMetric = viewModel.gradientMetric
            segmentColors = viewModel.computedSegmentColors
            for (idx, renderer) in segmentRenderers {
                renderer.strokeColor = idx < segmentColors.count
                    ? segmentColors[idx]
                    : .systemBlue
                renderer.setNeedsDisplay()
            }
        }

        /// Update lineWidth of existing renderers without rebuilding overlays.
        private func refreshSegmentLineWidths() {
            lastLineWidth = viewModel.lineWidth
            for renderer in segmentRenderers.values {
                renderer.lineWidth = viewModel.lineWidth
                renderer.setNeedsDisplay()
            }
        }

        // MARK: - Reveal progress

        /// Translates a route *point* index (animator state) into the corresponding
        /// segment index and only redraws the renderers that actually changed state.
        private func applyRevealedPointIndex(_ pointIndex: Int) {
            // Segment i spans point i → point i+1. After reaching point K we have
            // revealed segments 0…K-1.
            let target = min(pointIndex - 1, segmentOverlays.count - 1)
            let newRevealed = max(-1, target)
            let oldRevealed = revealedSegmentIndex
            guard newRevealed != oldRevealed else { return }
            revealedSegmentIndex = newRevealed

            let lo = min(oldRevealed, newRevealed) + 1
            let hi = max(oldRevealed, newRevealed)
            if lo <= hi {
                for i in lo...hi {
                    segmentRenderers[i]?.setNeedsDisplay()
                }
            }
        }

        // MARK: - Position marker

        private func updatePositionMarker(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate,
                  CLLocationCoordinate2DIsValid(coord) else { return }
            positionMarkerCoord = coord
            // Direct, animation-free positioning. UIKit would otherwise
            // implicitly animate the center change inside MapKit's animation
            // transactions.
            UIView.performWithoutAnimation {
                positionMarkerView.center = map.convert(coord, toPointTo: map)
                positionMarkerView.isHidden = false
            }
        }

        /// Keep the marker pinned to its coordinate when the map's visible
        /// region changes (user pan/zoom or programmatic camera changes).
        private func repositionMarkerForRegionChange(on map: MKMapView) {
            guard let coord = positionMarkerCoord else { return }
            UIView.performWithoutAnimation {
                positionMarkerView.center = map.convert(coord, toPointTo: map)
            }
        }

        // MARK: - Camera

        private func updateCamera(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate else { return }
            let heading = viewModel.animator.currentHeading
            let distance = viewModel.cameraDistance
            let pitch = viewModel.is3DMode ? viewModel.pitch : 0

            // Filter sub-threshold updates so MapKit isn't asked to re-layout
            // for sub-meter / sub-degree changes that aren't visible anyway.
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
            // While playing we tick frequently; animating each setCamera call
            // would queue ~0.25 s animations that lag behind the dot. Snap
            // instead. Animate only for user-driven changes (scrubbing, settings).
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
                  let idxStr = polyline.title,
                  let idx = Int(idxStr) else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = RouteSegmentRenderer(overlay: polyline)
            renderer.coordinator = self
            renderer.strokeColor = idx < segmentColors.count ? segmentColors[idx] : .systemBlue
            renderer.lineWidth = viewModel.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
            segmentRenderers[idx] = renderer
            return renderer
        }

        // Called continuously as the camera moves (programmatic or user gesture).
        // Keeps the marker pinned to its world coordinate without animation.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            repositionMarkerForRegionChange(on: mapView)
        }

        // The coordinator's current reveal state is read by RouteSegmentRenderer.
        fileprivate func shouldDrawSegment(_ index: Int) -> Bool {
            index <= revealedSegmentIndex
        }
    }
}

// MARK: - Segment Renderer

/// MKPolylineRenderer that suppresses drawing for segments past the current
/// playback position. This lets us add every segment to the map once at load
/// and reveal progressively without `addOverlays(_:)` churn on every tick.
///
/// The segment index is read from the polyline's `title` (set when the overlay
/// is created). We override `init(overlay:)` because `MKPolylineRenderer`'s
/// `init(polyline:)` dispatches through `-[self initWithOverlay:]` in
/// Objective-C, and a missing override would crash with "Use of unimplemented
/// initializer 'init(overlay:)'".
private final class RouteSegmentRenderer: MKPolylineRenderer {
    let segmentIndex: Int
    weak var coordinator: AnimatedMapView.Coordinator?

    override init(overlay: MKOverlay) {
        if let polyline = overlay as? MKPolyline,
           let idxStr = polyline.title,
           let idx = Int(idxStr) {
            self.segmentIndex = idx
        } else {
            self.segmentIndex = -1
        }
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard coordinator?.shouldDrawSegment(segmentIndex) ?? false else { return }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

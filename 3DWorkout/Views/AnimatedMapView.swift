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
        map.register(
            CurrentPositionAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: CurrentPositionAnnotationView.reuseID
        )
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

        // Single overlay for the whole route; a custom renderer paints every
        // segment in one Core Graphics pass. This avoids the per-segment
        // `MKPolylineRenderer` cache explosion that previously pushed memory
        // over 1 GB when the line-width slider was dragged.
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

        // Live position marker as an MKAnnotation — annotations render above
        // overlays, so the dot is always on top of the polyline head.
        private let positionAnnotation = CurrentPositionAnnotation()
        private var positionAnnotationAdded = false

        init(viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            super.init()

            viewModel.animator.$currentPointIndex
                .removeDuplicates()
                .sink { [weak self] index in
                    guard let self, let map = self.mapView else { return }
                    self.applyRevealedPointIndex(index)
                    self.updateCamera(on: map)
                    self.updatePositionAnnotation(on: map)
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
            map.addOverlay(polyline, level: .aboveRoads)

            let initialPointIndex = viewModel.animator.isPlaying
                ? viewModel.animator.currentPointIndex
                : route.points.count - 1
            applyRevealedPointIndex(initialPointIndex)

            if !hasFramed {
                map.setRegion(route.boundingRegion, animated: false)
                hasFramed = true
            }

            updatePositionAnnotation(on: map)
        }

        /// Push fresh colors into the renderer and ask for one redraw.
        private func refreshSegmentColors() {
            lastGradientMetric = viewModel.gradientMetric
            segmentColors = viewModel.computedSegmentColors
            routeRenderer?.segmentColors = segmentColors
            routeRenderer?.setNeedsDisplay()
        }

        /// Update the renderer's line width once and ask for one redraw —
        /// regardless of how many segments the route has.
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

        // MARK: - Position annotation

        private func updatePositionAnnotation(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate,
                  CLLocationCoordinate2DIsValid(coord) else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            positionAnnotation.coordinate = coord
            CATransaction.commit()

            if !positionAnnotationAdded {
                map.addAnnotation(positionAnnotation)
                positionAnnotationAdded = true
            }

            if let view = map.view(for: positionAnnotation) {
                let target = map.convert(coord, toPointTo: map)
                view.layer.removeAllAnimations()
                UIView.performWithoutAnimation { view.center = target }
            }
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

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is CurrentPositionAnnotation else { return nil }
            return map.dequeueReusableAnnotationView(
                withIdentifier: CurrentPositionAnnotationView.reuseID,
                for: annotation
            )
        }
    }
}

// MARK: - Gradient Route Renderer

/// A single `MKOverlayRenderer` that draws every revealed segment of the route
/// in one pass. Replaces the per-segment `MKPolylineRenderer` approach which
/// allocated thousands of independently-cached layers — the slider could push
/// memory north of 1 GB by invalidating all those caches at 60 Hz.
///
/// The renderer keeps the path data + colours in plain arrays. Reveal index,
/// colours and line width all live as `var` properties so the coordinator can
/// mutate them and trigger a single `setNeedsDisplay()` per change.
private final class GradientRouteRenderer: MKOverlayRenderer {
    var coords: [CLLocationCoordinate2D] = []
    var segmentColors: [UIColor] = []
    var revealedSegmentIndex: Int = -1
    var lineWidth: CGFloat = 4.0

    override func draw(_ mapRect: MKMapRect,
                       zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard revealedSegmentIndex >= 0, coords.count > 1 else { return }
        // MapKit's context is in map-point space; scaling the stroke by
        // 1/zoomScale keeps the line a constant *screen* width regardless
        // of zoom level.
        let strokeWidth = lineWidth / CGFloat(zoomScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)

        // Clip work to the tile MapKit is asking us to paint, with a margin
        // so segments straddling the edge still get drawn.
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

// MARK: - Position Annotation

private final class CurrentPositionAnnotation: NSObject, MKAnnotation {
    private var _coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @objc dynamic var coordinate: CLLocationCoordinate2D {
        get { _coordinate }
        set {
            willChangeValue(forKey: "coordinate")
            _coordinate = newValue
            didChangeValue(forKey: "coordinate")
        }
    }
}

private final class CurrentPositionAnnotationView: MKAnnotationView {
    static let reuseID = "currentPositionDot"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        backgroundColor = .systemRed
        layer.cornerRadius = 9
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
        canShowCallout = false
        isUserInteractionEnabled = false
        layer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull()
        ]
        layer.zPosition = 1000
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: false)
    }
}

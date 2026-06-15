import SwiftUI
import MapKit
import Combine

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

        // Overlay state
        private var segmentOverlays: [MKPolyline] = []
        private var segmentColors: [UIColor] = []
        private var lastRenderedIndex: Int = -1
        private var lastRouteID: UUID?
        private var lastGradientMetric: GradientMetric?
        private var lastMapStyle: MapDisplayStyle?
        private var lastLineWidth: CGFloat?
        private var hasFramed = false

        // Live position dot
        private let positionAnnotation = CurrentPositionAnnotation()
        private var positionAnnotationAdded = false

        init(viewModel: WorkoutDetailViewModel) {
            self.viewModel = viewModel
            super.init()

            // Drive camera + segment reveal from animator ticks via Combine
            viewModel.animator.$currentPointIndex
                .receive(on: RunLoop.main)
                .sink { [weak self] index in
                    guard let self, let map = self.mapView else { return }
                    self.revealSegments(on: map, upTo: index)
                    self.updateCamera(on: map)
                    self.updatePositionAnnotation(on: map)
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

            // Route or gradient metric or line width changed – rebuild overlays
            let routeChanged = viewModel.routeID != nil && viewModel.routeID != lastRouteID
            let metricChanged = lastGradientMetric != viewModel.gradientMetric
            let widthChanged  = lastLineWidth != viewModel.lineWidth

            if routeChanged || metricChanged || widthChanged {
                rebuildOverlays(on: map)
            }

            updateCamera(on: map)
        }

        private func rebuildOverlays(on map: MKMapView) {
            guard let route = viewModel.route else { return }

            map.removeOverlays(segmentOverlays)
            segmentOverlays.removeAll()
            lastRenderedIndex = -1
            segmentColors = viewModel.computedSegmentColors
            lastRouteID = viewModel.routeID
            lastGradientMetric = viewModel.gradientMetric
            lastLineWidth = viewModel.lineWidth

            // When not animating, reveal the full static route
            let upTo = viewModel.animator.isPlaying
                ? viewModel.animator.currentPointIndex
                : route.points.count - 1
            revealSegments(on: map, upTo: upTo)

            // Frame the route on first load
            if !hasFramed {
                map.setRegion(route.boundingRegion, animated: false)
                hasFramed = true
            }

            updatePositionAnnotation(on: map)
        }

        private func updatePositionAnnotation(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate,
                  CLLocationCoordinate2DIsValid(coord) else { return }
            positionAnnotation.coordinate = coord
            if !positionAnnotationAdded {
                map.addAnnotation(positionAnnotation)
                positionAnnotationAdded = true
            }
        }

        private func revealSegments(on map: MKMapView, upTo index: Int) {
            guard let route = viewModel.route, index < route.points.count else { return }
            guard index > lastRenderedIndex else { return }

            let start = max(0, lastRenderedIndex)
            var newOverlays: [MKPolyline] = []
            newOverlays.reserveCapacity(index - start)

            for i in start..<index {
                guard i + 1 < route.points.count else { break }
                var coords = [route.points[i].coordinate, route.points[i + 1].coordinate]
                let seg = MKPolyline(coordinates: &coords, count: 2)
                seg.title = "\(i)"
                newOverlays.append(seg)
            }

            if !newOverlays.isEmpty {
                map.addOverlays(newOverlays, level: .aboveRoads)
                segmentOverlays.append(contentsOf: newOverlays)
            }
            lastRenderedIndex = index
        }

        private func updateCamera(on map: MKMapView) {
            guard let coord = viewModel.animator.currentCoordinate else { return }
            let camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: viewModel.cameraDistance,
                pitch: viewModel.is3DMode ? CGFloat(viewModel.pitch) : 0,
                heading: viewModel.animator.currentHeading
            )
            // While playing we tick at ~30 fps; animating each setCamera call queues
            // ~0.25 s animations that lag behind the dot. Snap instead so the camera
            // stays centered on the position. Animate only for user-driven changes
            // (scrubbing, settings).
            map.setCamera(camera, animated: !viewModel.animator.isPlaying)
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline,
                  let idxStr = polyline.title,
                  let idx = Int(idxStr) else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = idx < segmentColors.count ? segmentColors[idx] : .systemBlue
            renderer.lineWidth = viewModel.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
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

// MARK: - Current Position Annotation

private final class CurrentPositionAnnotation: NSObject, MKAnnotation {
    // KVO-compliant via manual willChange/didChange so the map view animates updates.
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
        // Render above polyline overlays.
        layer.zPosition = 1000
    }
}

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
            map.setCamera(camera, animated: viewModel.animator.isPlaying)
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
    }
}

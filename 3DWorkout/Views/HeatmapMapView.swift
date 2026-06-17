import SwiftUI
import MapKit
import Combine

/// Renders the heatmap as one `MKPolyline` per workout. Where multiple
/// workouts pass through the same area, their semi-transparent strokes blend
/// on the GPU and form the brightness ramp — Strava-style. MapKit handles
/// per-frame culling natively, so pan / zoom does *no* work in our code.
struct HeatmapMapView: UIViewRepresentable {
    @ObservedObject var viewModel: HeatmapViewModel
    @ObservedObject var settings: AppSettings
    var userLocation: CLLocation?
    /// Called when the user taps a track on the map. The argument is the
    /// `HeatmapTrack.id` (which is the workout's HK UUID), so the parent can
    /// look up the matching `WorkoutSession` and push detail.
    var onTrackTap: (UUID) -> Void = { _ in }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = true

        // Tap → find the nearest polyline and bubble the workout id up.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.mapView = map
        context.coordinator.onTrackTap = onTrackTap
        context.coordinator.bind(viewModel: viewModel, settings: settings)
        context.coordinator.applyInitialFocus(userLocation: userLocation,
                                              bounds: viewModel.aggregatedBounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapView: MKMapView?
        var onTrackTap: (UUID) -> Void = { _ in }

        private var viewModel: HeatmapViewModel?
        private var settings: AppSettings?
        private var cancellables = Set<AnyCancellable>()

        private var renderedTrackIDs: Set<UUID> = []
        private var trackOverlays: [UUID: MKPolyline] = [:]
        /// Reverse map (overlay → workout id) used for nearest-track lookup
        /// from a tap point.
        private var overlayToTrackID: [ObjectIdentifier: UUID] = [:]
        private var hasFocused = false

        func bind(viewModel: HeatmapViewModel, settings: AppSettings) {
            let viewModelChanged = self.viewModel !== viewModel
            let settingsChanged  = self.settings !== settings
            self.viewModel = viewModel
            self.settings  = settings

            if viewModelChanged {
                cancellables.removeAll()
                viewModel.$tracks
                    // Hop off the gesture/layout pass before mutating
                    // overlays; otherwise the first sync can block the main
                    // thread long enough that iOS gives up on touch gestures
                    // (system gesture gate timed out).
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] tracks in
                        DispatchQueue.main.async {
                            self?.syncOverlays(tracks: tracks)
                        }
                    }
                    .store(in: &cancellables)
                DispatchQueue.main.async { [weak self] in
                    self?.syncOverlays(tracks: viewModel.tracks)
                }
            }
            if settingsChanged {
                refreshRendererStyles()
            }
        }

        func applyInitialFocus(userLocation: CLLocation?, bounds: MKCoordinateRegion?) {
            guard !hasFocused, let map = mapView else { return }
            if let loc = userLocation {
                let region = MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: 5_000,
                    longitudinalMeters: 5_000
                )
                map.setRegion(region, animated: false)
                hasFocused = true
            } else if let bounds {
                map.setRegion(bounds, animated: false)
                hasFocused = true
            }
            // Seed the view model with the current region so an export can
            // happen even before the user pans. Hopping off the SwiftUI view
            // update tick avoids "publishing changes from within view updates"
            // runtime warnings.
            if hasFocused, let map = mapView {
                let region = map.region
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.currentMapRegion = region
                }
            }
        }

        // MARK: - Overlay sync

        /// Diff the incoming track set against what's already on the map and
        /// only `removeOverlays` / `addOverlays` for the differences.
        private func syncOverlays(tracks: [HeatmapTrack]) {
            guard let map = mapView else { return }
            let incomingIDs = Set(tracks.map(\.id))

            // Remove tracks that no longer match the filter.
            let toRemove = renderedTrackIDs.subtracting(incomingIDs)
            if !toRemove.isEmpty {
                var removed: [MKPolyline] = []
                removed.reserveCapacity(toRemove.count)
                for id in toRemove {
                    if let poly = trackOverlays.removeValue(forKey: id) {
                        removed.append(poly)
                        overlayToTrackID.removeValue(forKey: ObjectIdentifier(poly))
                    }
                }
                map.removeOverlays(removed)
            }

            // Add tracks that are newly matched.
            var added: [MKPolyline] = []
            added.reserveCapacity(incomingIDs.subtracting(renderedTrackIDs).count)
            for track in tracks where !renderedTrackIDs.contains(track.id) {
                guard track.coordinates.count >= 2 else { continue }
                var coords = track.coordinates
                let poly = MKPolyline(coordinates: &coords, count: coords.count)
                // Carry the sport type through `title` so the renderer can
                // pick the right colour without a side table.
                poly.title = track.sportType
                trackOverlays[track.id] = poly
                overlayToTrackID[ObjectIdentifier(poly)] = track.id
                added.append(poly)
            }
            if !added.isEmpty {
                map.addOverlays(added, level: .aboveRoads)
            }

            renderedTrackIDs = incomingIDs
        }

        /// Rebuild renderers when the user changes the heatmap style settings.
        private func refreshRendererStyles() {
            guard let map = mapView else { return }
            for overlay in map.overlays {
                if let r = map.renderer(for: overlay) as? MKPolylineRenderer,
                   let sport = (overlay as? MKPolyline)?.title {
                    style(renderer: r, sport: sport)
                    r.setNeedsDisplay()
                }
            }
        }

        private func style(renderer: MKPolylineRenderer, sport: String) {
            guard let settings = settings else { return }
            renderer.strokeColor = HeatmapStyle.uiColor(for: sport,
                                                       alpha: settings.heatmapLineAlpha)
            renderer.lineWidth = CGFloat(settings.heatmapLineWidth)
            renderer.lineCap = .round
            renderer.lineJoin = .round
        }

        // MARK: - Delegate

        // Mirror the visible region back to the view model so the export
        // sheet can render whatever the user is currently framing. The
        // delegate fires inside MapKit's layout pass, so defer the
        // @Published write to avoid SwiftUI's "publishing changes from
        // within view updates" runtime warning.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.currentMapRegion = region
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: polyline)
            style(renderer: r, sport: polyline.title ?? "")
            return r
        }

        // MARK: - Tap-to-open

        /// Cooperate with MapKit's own pan / pinch gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc fileprivate func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let map = mapView,
                  !trackOverlays.isEmpty else { return }
            let tapPoint = gesture.location(in: map)
            if let id = nearestTrack(to: tapPoint, in: map, maxPixels: 22) {
                onTrackTap(id)
            }
        }

        /// Returns the workout id of the polyline whose closest segment is
        /// within `maxPixels` of the tap, or nil. We walk in screen space so
        /// the threshold is intuitive and zoom-independent.
        private func nearestTrack(to tap: CGPoint,
                                  in map: MKMapView,
                                  maxPixels: CGFloat) -> UUID? {
            var bestDistance = maxPixels
            var bestID: UUID?
            for overlay in map.overlays {
                guard let poly = overlay as? MKPolyline,
                      let id = overlayToTrackID[ObjectIdentifier(poly)] else { continue }
                let count = poly.pointCount
                guard count >= 2 else { continue }
                let mapPoints = poly.points()
                var prevScreen: CGPoint = map.convert(mapPoints[0].coordinate, toPointTo: map)
                for i in 1..<count {
                    let nextScreen = map.convert(mapPoints[i].coordinate, toPointTo: map)
                    let d = pointSegmentDistance(p: tap, a: prevScreen, b: nextScreen)
                    if d < bestDistance {
                        bestDistance = d
                        bestID = id
                    }
                    prevScreen = nextScreen
                }
            }
            return bestID
        }

        /// Euclidean distance from `p` to the segment (a, b).
        private func pointSegmentDistance(p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
            let ax = a.x, ay = a.y, bx = b.x, by = b.y
            let dx = bx - ax, dy = by - ay
            let lenSq = dx * dx + dy * dy
            let t: CGFloat
            if lenSq == 0 {
                t = 0
            } else {
                t = max(0, min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / lenSq))
            }
            let projX = ax + t * dx
            let projY = ay + t * dy
            return hypot(p.x - projX, p.y - projY)
        }
    }
}

// MARK: - Per-sport palette

/// Matches the sport tinting used on `WorkoutCard` so the heatmap and the
/// workouts list speak the same visual language.
enum HeatmapStyle {
    static func uiColor(for sport: String, alpha: Double) -> UIColor {
        let base: UIColor
        switch sport {
        case "Running":  base = .systemOrange
        case "Cycling":  base = .systemBlue
        case "Hiking":   base = .systemGreen
        case "Walking":  base = .systemTeal
        case "Swimming": base = .systemCyan
        default:         base = .systemRed
        }
        return base.withAlphaComponent(CGFloat(alpha))
    }

    static func swiftUIColor(for sport: String) -> Color {
        switch sport {
        case "Running":  return .orange
        case "Cycling":  return .blue
        case "Hiking":   return .green
        case "Walking":  return .teal
        case "Swimming": return .cyan
        default:         return .red
        }
    }
}

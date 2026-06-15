import Foundation
import CoreLocation
import Combine

enum AnimationSpeed: Double, CaseIterable, Identifiable, Codable {
    case oneX = 1
    case twoX = 2
    case fourX = 4
    case eightX = 8
    case sixteenX = 16
    case thirtyTwoX = 32
    case sixtyFourX = 64

    var id: Double { rawValue }
    var displayName: String { "\(Int(rawValue))×" }
}

@MainActor
final class RouteAnimator: ObservableObject {
    @Published private(set) var currentPointIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0.0

    var animationSpeed: AnimationSpeed = .oneX

    private(set) var route: WorkoutRoute?
    private var timer: Timer?
    private var lastTickDate: Date?
    private var smoothedHeading: Double = 0

    var currentCoordinate: CLLocationCoordinate2D? {
        guard let route, currentPointIndex < route.points.count else { return nil }
        return route.points[currentPointIndex].coordinate
    }

    var currentHeading: CLLocationDirection {
        guard let route else { return smoothedHeading }
        let lookahead = min(currentPointIndex + 5, route.points.count - 1)
        guard lookahead > currentPointIndex else { return smoothedHeading }
        let raw = bearing(from: route.points[currentPointIndex], to: route.points[lookahead])
        // Exponential smoothing to avoid jitter on dense GPS tracks
        let diff = ((raw - smoothedHeading) + 540).truncatingRemainder(dividingBy: 360) - 180
        smoothedHeading = (smoothedHeading + diff * 0.15 + 360).truncatingRemainder(dividingBy: 360)
        return smoothedHeading
    }

    var currentTimestamp: Date? {
        guard let route, currentPointIndex < route.points.count else { return nil }
        return route.points[currentPointIndex].timestamp
    }

    func load(route: WorkoutRoute) {
        pause()
        self.route = route
        currentPointIndex = 0
        progress = 0
        smoothedHeading = 0
    }

    func play() {
        guard let route, !route.points.isEmpty else { return }
        if currentPointIndex >= route.points.count - 1 { seek(to: 0) }
        isPlaying = true
        lastTickDate = Date()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        lastTickDate = nil
    }

    func stop() {
        pause()
        currentPointIndex = 0
        progress = 0
    }

    func seek(to fraction: Double) {
        guard let route else { return }
        let clamped = max(0, min(1, fraction))
        currentPointIndex = Int(clamped * Double(route.points.count - 1))
        progress = clamped
    }

    // MARK: - Private

    private func tick() {
        guard let route, isPlaying, route.points.count > 1 else { return }
        let now = Date()
        let elapsed = lastTickDate.map { now.timeIntervalSince($0) } ?? (1.0 / 30.0)
        lastTickDate = now

        let totalDuration = route.points.last!.timestamp.timeIntervalSince(route.points.first!.timestamp)
        guard totalDuration > 0 else { pause(); return }

        let virtualElapsed = elapsed * animationSpeed.rawValue
        let advanceFraction = virtualElapsed / totalDuration
        let advance = max(1, Int(advanceFraction * Double(route.points.count)))
        let newIndex = min(currentPointIndex + advance, route.points.count - 1)

        currentPointIndex = newIndex
        progress = Double(newIndex) / Double(route.points.count - 1)

        if newIndex >= route.points.count - 1 { pause() }
    }

    private func bearing(from: RoutePoint, to: RoutePoint) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

import Foundation
import CoreLocation
import QuartzCore
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
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var lastTickTimestamp: CFTimeInterval = 0

    // Smoothed heading is updated inside tick() so reads from the camera are
    // side-effect free.
    private(set) var currentHeading: CLLocationDirection = 0

    var currentCoordinate: CLLocationCoordinate2D? {
        guard let route, currentPointIndex < route.points.count else { return nil }
        return route.points[currentPointIndex].coordinate
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
        currentHeading = 0
        updateHeading()
    }

    func play() {
        guard let route, !route.points.isEmpty else { return }
        if currentPointIndex >= route.points.count - 1 { seek(to: 0) }
        isPlaying = true
        lastTickTimestamp = 0

        // CADisplayLink syncs to the display refresh and lets the system batch
        // redraws; far more energy-efficient than a 30 Hz Timer.
        let proxy = DisplayLinkProxy { [weak self] link in
            self?.tick(timestamp: link.timestamp)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        if #available(iOS 15.0, *) {
            // Cap at 30 fps — adequate for a moving dot and halves wakeups on
            // 60/120 Hz displays.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkProxy = proxy
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        isPlaying = false
        lastTickTimestamp = 0
    }

    func stop() {
        pause()
        currentPointIndex = 0
        progress = 0
        currentHeading = 0
        updateHeading()
    }

    func seek(to fraction: Double) {
        guard let route else { return }
        let clamped = max(0, min(1, fraction))
        currentPointIndex = Int(clamped * Double(route.points.count - 1))
        progress = clamped
        updateHeading()
    }

    // MARK: - Private

    private func tick(timestamp: CFTimeInterval) {
        guard let route, isPlaying, route.points.count > 1 else { return }
        let elapsed: TimeInterval
        if lastTickTimestamp == 0 {
            elapsed = 1.0 / 30.0
        } else {
            elapsed = timestamp - lastTickTimestamp
        }
        lastTickTimestamp = timestamp

        let totalDuration = route.points.last!.timestamp.timeIntervalSince(route.points.first!.timestamp)
        guard totalDuration > 0 else { pause(); return }

        let virtualElapsed = elapsed * animationSpeed.rawValue
        let advanceFraction = virtualElapsed / totalDuration
        let advance = max(1, Int(advanceFraction * Double(route.points.count)))
        let newIndex = min(currentPointIndex + advance, route.points.count - 1)

        if newIndex != currentPointIndex {
            currentPointIndex = newIndex
            progress = Double(newIndex) / Double(route.points.count - 1)
            updateHeading()
        }

        if newIndex >= route.points.count - 1 { pause() }
    }

    /// Exponentially-smoothed heading from the current position towards a small
    /// lookahead. Called only inside tick()/seek()/load() — never as a side
    /// effect of a property read.
    private func updateHeading() {
        guard let route, route.points.count > 1 else { return }
        let lookahead = min(currentPointIndex + 5, route.points.count - 1)
        guard lookahead > currentPointIndex else { return }
        let raw = bearing(from: route.points[currentPointIndex], to: route.points[lookahead])
        let diff = ((raw - currentHeading) + 540).truncatingRemainder(dividingBy: 360) - 180
        currentHeading = (currentHeading + diff * 0.15 + 360).truncatingRemainder(dividingBy: 360)
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

/// CADisplayLink retains its target. A proxy avoids a retain cycle on the
/// animator and lets the closure capture `self` weakly.
private final class DisplayLinkProxy {
    private let handler: (CADisplayLink) -> Void
    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }
    @objc func fire(_ link: CADisplayLink) {
        handler(link)
    }
}

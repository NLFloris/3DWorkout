import Foundation
import SwiftUI
import UIKit
import MapKit

enum GradientMetric: String, CaseIterable, Identifiable, Codable {
    case pace, heartRate, elevation, speed, solid
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pace:      return "Pace"
        case .heartRate: return "Heart Rate"
        case .elevation: return "Elevation"
        case .speed:     return "Speed"
        case .solid:     return "Solid Color"
        }
    }
}

enum MapDisplayStyle: String, CaseIterable, Identifiable, Codable {
    case standard, satellite, hybrid, satelliteFlyover
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard:          return "Standard"
        case .satellite:         return "Satellite"
        case .hybrid:            return "Hybrid"
        case .satelliteFlyover:  return "Flyover"
        }
    }
    var mkMapType: MKMapType {
        switch self {
        case .standard:         return .standard
        case .satellite:        return .satellite
        case .hybrid:           return .hybrid
        case .satelliteFlyover: return .satelliteFlyover
        }
    }
}

@MainActor
final class WorkoutDetailViewModel: ObservableObject {
    let session: WorkoutSession

    // Not @Published — views that need playback state observe the animator
    // directly so view-model observers don't redraw on every animation tick.
    let animator = RouteAnimator()
    @Published private(set) var route: WorkoutRoute?
    @Published private(set) var metrics: WorkoutMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var routeID: UUID?

    // Customization — initial values come from AppSettings so the user can
    // pick their preferred look once and have every new workout open with it.
    @Published var gradientMetric: GradientMetric { didSet { invalidateColors() } }
    @Published var routeColor: Color { didSet { if gradientMetric == .solid { invalidateColors() } } }
    @Published var lineWidth: CGFloat
    @Published var mapStyle: MapDisplayStyle
    @Published var is3DMode: Bool
    @Published var pitch: Double
    @Published var animationSpeed: AnimationSpeed { didSet { animator.animationSpeed = animationSpeed } }
    @Published var cameraDistance: Double

    private var cachedColors: (metric: GradientMetric, colors: [UIColor])?
    private let healthKitService: HealthKitService
    private let store: WorkoutStore

    init(session: WorkoutSession,
         healthKitService: HealthKitService,
         store: WorkoutStore,
         settings: AppSettings) {
        self.session = session
        self.healthKitService = healthKitService
        self.store = store

        self.gradientMetric  = GradientMetric(rawValue: settings.defaultGradientMetric) ?? .pace
        self.routeColor      = Color(hex: settings.defaultRouteColorHex)
        self.lineWidth       = CGFloat(settings.defaultLineWidth)
        self.mapStyle        = MapDisplayStyle(rawValue: settings.defaultMapStyle) ?? .hybrid
        self.is3DMode        = settings.defaultIs3DMode
        self.pitch           = settings.defaultPitch
        self.cameraDistance  = settings.defaultCameraDistance
        self.animationSpeed  = AnimationSpeed(rawValue: settings.defaultAnimationSpeed) ?? .fourX

        animator.animationSpeed = animationSpeed
    }

    var computedSegmentColors: [UIColor] {
        guard let route else { return [] }
        if let c = cachedColors, c.metric == gradientMetric { return c.colors }
        let colors = buildColors(for: route)
        cachedColors = (gradientMetric, colors)
        return colors
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let uuid = session.hkWorkoutUUID

        // Serve from cache when available.
        if let cachedMetrics = store.cachedMetrics(for: uuid) {
            metrics = cachedMetrics
        }
        let cachedRoute = store.cachedRoute(for: uuid)
        if cachedRoute.fetched, let r = cachedRoute.route {
            applyRoute(r)
        }

        do {
            // Fetch metrics from HealthKit only if not cached.
            if metrics == nil {
                let m = try await healthKitService.fetchMetrics(for: session)
                metrics = m
                store.storeMetrics(m, for: uuid)
            }

            // Fetch the route from HealthKit only if it hasn't been fetched before.
            if !cachedRoute.fetched {
                let r = try await healthKitService.fetchRoute(for: session)
                store.storeRoute(r, for: uuid)
                if let r { applyRoute(r) }
            }
        } catch {
            // Don't clobber a successfully cached route with a transient error.
            if route == nil { errorMessage = error.localizedDescription }
        }
    }

    private func applyRoute(_ r: WorkoutRoute) {
        route = r
        routeID = UUID()
        cachedColors = nil
        animator.load(route: r)
    }

    func cycleSpeed() {
        let all = AnimationSpeed.allCases
        let next = (all.firstIndex(of: animationSpeed).map { $0 + 1 } ?? 0) % all.count
        animationSpeed = all[next]
    }

    // MARK: - Private color computation

    private func invalidateColors() { cachedColors = nil }

    private func buildColors(for route: WorkoutRoute) -> [UIColor] {
        let count = max(0, route.points.count - 1)
        guard count > 0 else { return [] }
        switch gradientMetric {
        case .solid:      return Array(repeating: UIColor(routeColor), count: count)
        case .speed:      return speedColors(route: route, count: count)
        case .pace:       return speedColors(route: route, count: count, inverted: true)
        case .heartRate:  return heartRateColors(route: route, count: count)
        case .elevation:  return elevationColors(route: route, count: count)
        }
    }

    private func speedColors(route: WorkoutRoute, count: Int, inverted: Bool = false) -> [UIColor] {
        let minV = route.minSpeed, maxV = route.maxSpeed
        let range = maxV - minV
        return (0..<count).map { i in
            let speed = route.points[i].speed ?? 0
            let t = range > 0 ? (speed - minV) / range : 0
            let hue = inverted ? (1 - t) * 0.33 : t * 0.33
            return UIColor(hue: hue, saturation: 0.9, brightness: 0.9, alpha: 1)
        }
    }

    private func heartRateColors(route: WorkoutRoute, count: Int) -> [UIColor] {
        guard let metrics, !metrics.heartRateSamples.isEmpty else {
            return Array(repeating: UIColor.systemBlue, count: count)
        }
        let values = metrics.heartRateSamples.map(\.value)
        let minV = values.min()!, maxV = values.max()!
        let range = maxV - minV
        return (0..<count).map { i in
            let ts = route.points[i].timestamp
            let hr = metrics.heartRate(at: ts) ?? minV
            let t = range > 0 ? (hr - minV) / range : 0
            // blue (low) → red (high): hue 0.66 → 0.0
            return UIColor(hue: (1 - t) * 0.66, saturation: 0.9, brightness: 0.9, alpha: 1)
        }
    }

    private func elevationColors(route: WorkoutRoute, count: Int) -> [UIColor] {
        let minV = route.minAltitude, maxV = route.maxAltitude
        let range = maxV - minV
        return (0..<count).map { i in
            let alt = route.points[i].altitude
            let t = range > 0 ? (alt - minV) / range : 0
            // brown-green (low) → white (high)
            return UIColor(hue: 0.3 - t * 0.3, saturation: 1 - t * 0.7, brightness: 0.5 + t * 0.5, alpha: 1)
        }
    }
}

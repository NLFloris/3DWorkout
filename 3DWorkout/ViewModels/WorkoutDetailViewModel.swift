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

    @Published var animator = RouteAnimator()
    @Published private(set) var route: WorkoutRoute?
    @Published private(set) var metrics: WorkoutMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var routeID: UUID?

    // Customization
    @Published var gradientMetric: GradientMetric = .pace { didSet { invalidateColors() } }
    @Published var routeColor: Color = .blue { didSet { if gradientMetric == .solid { invalidateColors() } } }
    @Published var lineWidth: CGFloat = 4.0
    @Published var mapStyle: MapDisplayStyle = .hybrid
    @Published var is3DMode: Bool = true
    @Published var pitch: Double = 60.0
    @Published var animationSpeed: AnimationSpeed = .fourX { didSet { animator.animationSpeed = animationSpeed } }
    @Published var cameraDistance: Double = 400.0

    private var cachedColors: (metric: GradientMetric, colors: [UIColor])?
    private let healthKitService: HealthKitService

    init(session: WorkoutSession, healthKitService: HealthKitService) {
        self.session = session
        self.healthKitService = healthKitService
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
        do {
            async let routeResult = healthKitService.fetchRoute(for: session)
            async let metricsResult = healthKitService.fetchMetrics(for: session)
            let (r, m) = try await (routeResult, metricsResult)
            metrics = m
            if let r {
                route = r
                routeID = UUID()
                cachedColors = nil
                animator.load(route: r)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

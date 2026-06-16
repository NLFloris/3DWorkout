import Foundation
import CoreLocation

/// Walks every cached workout that doesn't yet have a heatmap track, fetches
/// (or re-uses) the route, Ramer–Douglas–Peucker simplifies it down to a
/// bounded polyline (≤ ~200 points), and stores the result. Runs on the main
/// actor so the UI stays responsive; dominates only the first heatmap open.
@MainActor
final class HeatmapIndexer: ObservableObject {
    @Published private(set) var totalWorkouts: Int = 0
    @Published private(set) var completedWorkouts: Int = 0
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    var progress: Double {
        totalWorkouts > 0 ? Double(completedWorkouts) / Double(totalWorkouts) : 0
    }

    /// Target maximum points per stored polyline. ~200 is plenty for a heatmap
    /// view — at this density a 50 km route already smooths to 1 point / 250 m.
    private let maxPointsPerTrack = 200
    /// Douglas-Peucker epsilon in degrees (~3 m at the equator). Cheap to tune.
    private let simplifyEpsilonDeg: Double = 0.00003

    private let healthKit: HealthKitService
    private let store: WorkoutStore
    private var task: Task<Void, Never>?

    init(healthKit: HealthKitService, store: WorkoutStore) {
        self.healthKit = healthKit
        self.store = store
    }

    func startIfNeeded() {
        guard task == nil, !isRunning else { return }
        task = Task { [weak self] in await self?.runIndex() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func runIndex() async {
        isRunning = true
        lastError = nil
        defer {
            isRunning = false
            task = nil
        }

        let pending = store.sessionsNeedingHeatmapIndex()
        totalWorkouts = pending.count
        completedWorkouts = 0
        guard !pending.isEmpty else { return }

        for session in pending {
            if Task.isCancelled { break }

            let route = await routeFor(session)
            let coords = route.map { Self.simplify(route: $0,
                                                  epsilon: simplifyEpsilonDeg,
                                                  cap: maxPointsPerTrack) } ?? []
            store.storeHeatmapTrack(coords, for: session)

            completedWorkouts += 1
            await Task.yield()
        }
    }

    /// Prefer the locally cached route; only hit HealthKit for workouts whose
    /// routes we haven't fetched yet.
    private func routeFor(_ session: WorkoutSession) async -> WorkoutRoute? {
        let cached = store.cachedRoute(for: session.hkWorkoutUUID)
        if cached.fetched { return cached.route }
        do {
            let fetched = try await healthKit.fetchRoute(for: session)
            store.storeRoute(fetched, for: session.hkWorkoutUUID)
            return fetched
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Simplify a route via Ramer–Douglas–Peucker, then enforce a hard cap on
    /// the resulting point count via every-Nth subsampling if simplification
    /// alone wasn't enough.
    static func simplify(route: WorkoutRoute, epsilon: Double, cap: Int) -> [CLLocationCoordinate2D] {
        let raw = route.points.map(\.coordinate)
        guard raw.count > 2 else { return raw }

        var simplified = douglasPeucker(coords: raw, epsilon: epsilon)
        if simplified.count > cap {
            let step = Double(simplified.count - 1) / Double(cap - 1)
            var out: [CLLocationCoordinate2D] = []
            out.reserveCapacity(cap)
            for i in 0..<cap {
                let idx = min(Int((Double(i) * step).rounded()), simplified.count - 1)
                out.append(simplified[idx])
            }
            simplified = out
        }
        return simplified
    }

    // MARK: - Douglas-Peucker

    private static func douglasPeucker(coords: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var keep = [Bool](repeating: false, count: coords.count)
        keep[0] = true
        keep[coords.count - 1] = true
        recurseDP(coords: coords, start: 0, end: coords.count - 1, epsilon: epsilon, keep: &keep)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(keep.lazy.filter { $0 }.count)
        for i in 0..<coords.count where keep[i] { out.append(coords[i]) }
        return out
    }

    private static func recurseDP(coords: [CLLocationCoordinate2D],
                                  start: Int, end: Int,
                                  epsilon: Double,
                                  keep: inout [Bool]) {
        guard end - start > 1 else { return }
        var maxD = 0.0
        var maxIdx = start
        let a = coords[start], b = coords[end]
        for i in (start + 1)..<end {
            let d = perpendicularDistance(point: coords[i], a: a, b: b)
            if d > maxD { maxD = d; maxIdx = i }
        }
        if maxD > epsilon {
            keep[maxIdx] = true
            recurseDP(coords: coords, start: start, end: maxIdx, epsilon: epsilon, keep: &keep)
            recurseDP(coords: coords, start: maxIdx, end: end, epsilon: epsilon, keep: &keep)
        }
    }

    /// Perpendicular distance from `point` to the line segment (a, b), in
    /// degrees. Fine for simplification — we're not measuring real distance.
    private static func perpendicularDistance(point p: CLLocationCoordinate2D,
                                              a: CLLocationCoordinate2D,
                                              b: CLLocationCoordinate2D) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude  - a.latitude
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 {
            let ddx = p.longitude - a.longitude
            let ddy = p.latitude  - a.latitude
            return sqrt(ddx * ddx + ddy * ddy)
        }
        let t = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / lenSq
        let projLon = a.longitude + t * dx
        let projLat = a.latitude  + t * dy
        let ddx = p.longitude - projLon
        let ddy = p.latitude  - projLat
        return sqrt(ddx * ddx + ddy * ddy)
    }
}

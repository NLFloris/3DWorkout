import SwiftUI
import Charts

/// A point on the elevation profile, in SI source units (meters).
private struct ElevationSample: Identifiable {
    let id = UUID()
    let distance: Double   // meters from start
    let altitude: Double   // meters
}

/// Swift Charts elevation profile synced to the playback position.
///
/// The static area/line chart is rendered independently of the moving rule.
/// Per-tick updates only affect the header text and the rule overlay — both of
/// which are factored into child views that observe the animator directly so
/// the heavy AreaMark/LineMark rasters don't rebuild every frame.
struct ElevationProfileView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel
    @EnvironmentObject var settings: AppSettings

    /// Plot data is downsampled once per route (not per animation tick) so
    /// sample identities stay stable and the chart doesn't fully rebuild.
    @State private var samples: [ElevationSample] = []

    var body: some View {
        let units = settings.units
        if let route = viewModel.route, route.points.count > 1 {
            let yLow = units.elevationValue(route.minAltitude)
            let yHigh = units.elevationValue(route.maxAltitude)

            VStack(alignment: .leading, spacing: 8) {
                ProfileHeader(route: route, animator: viewModel.animator, units: units)

                Chart {
                    ForEach(samples) { s in
                        AreaMark(
                            x: .value("Distance", units.distanceValue(s.distance)),
                            y: .value("Elevation", units.elevationValue(s.altitude))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.linearGradient(
                            colors: [.green.opacity(0.45), .green.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    }
                    ForEach(samples) { s in
                        LineMark(
                            x: .value("Distance", units.distanceValue(s.distance)),
                            y: .value("Elevation", units.elevationValue(s.altitude))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: yLow...max(yHigh, yLow + 1))
                .chartXAxisLabel(units.distanceUnit, alignment: .trailing)
                .chartYAxisLabel(units.elevationUnit)
                .frame(height: 110)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack {
                            // The rule is its own observer — only this redraws
                            // per animator tick. The Chart content above stays
                            // stable across ticks.
                            RuleOverlay(
                                route: route,
                                animator: viewModel.animator,
                                units: units,
                                proxy: proxy,
                                geo: geo
                            )
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            seek(at: value.location, proxy: proxy, geo: geo, route: route, units: units)
                                        }
                                )
                        }
                    }
                }
            }
            .onAppear { rebuild(route) }
            .onChange(of: viewModel.routeID) { _, _ in rebuild(route) }
        }
    }

    // MARK: - Child observers

    /// Header text that follows playback. Isolated as its own ObservedObject
    /// view so the surrounding chart doesn't redraw per tick.
    private struct ProfileHeader: View {
        let route: WorkoutRoute
        @ObservedObject var animator: RouteAnimator
        let units: UnitFormatter

        var body: some View {
            let curIdx = min(animator.currentPointIndex, route.points.count - 1)
            let curDistM = route.points[curIdx].cumulativeDistance
            let curAltM = route.points[curIdx].altitude
            HStack {
                Label("Elevation", systemImage: "mountain.2.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(units.elevation(curAltM)) · \(units.distance(curDistM))")
                    .font(.system(.caption, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Vertical playback rule drawn into the chart plot. Owns the only per-tick
    /// observation of the animator inside the chart.
    private struct RuleOverlay: View {
        let route: WorkoutRoute
        @ObservedObject var animator: RouteAnimator
        let units: UnitFormatter
        let proxy: ChartProxy
        let geo: GeometryProxy

        var body: some View {
            let curIdx = min(animator.currentPointIndex, route.points.count - 1)
            let curDistM = route.points[curIdx].cumulativeDistance
            let displayDist = units.distanceValue(curDistM)

            if let plotAnchor = proxy.plotFrame,
               let xInPlot = proxy.position(forX: displayDist) {
                let plotRect = geo[plotAnchor]
                Path { path in
                    let x = plotRect.minX + xInPlot
                    path.move(to: CGPoint(x: x, y: plotRect.minY))
                    path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                }
                .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5))
            }
        }
    }

    // MARK: - Helpers

    private func rebuild(_ route: WorkoutRoute) {
        samples = Self.downsample(route.points, maxCount: 160)
    }

    /// Maps a tap/drag location to a route distance and seeks playback to the
    /// nearest GPS point.
    private func seek(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy,
                      route: WorkoutRoute, units: UnitFormatter) {
        guard route.totalDistance > 0, route.points.count > 1 else { return }
        guard let plotAnchor = proxy.plotFrame else { return }
        let plotRect = geo[plotAnchor]
        let xInPlot = location.x - plotRect.minX
        guard let displayDistance: Double = proxy.value(atX: xInPlot) else { return }

        // Convert display units back to meters and clamp to the route.
        let metersPerUnit = units.isMetric ? 1000.0 : 1609.344
        let targetMeters = min(max(displayDistance * metersPerUnit, 0), route.totalDistance)

        let idx = Self.nearestIndex(toDistance: targetMeters, in: route.points)
        viewModel.animator.seek(to: Double(idx) / Double(route.points.count - 1))
    }

    /// Downsamples to at most `maxCount` evenly spaced points for smooth charting.
    private static func downsample(_ points: [RoutePoint], maxCount: Int) -> [ElevationSample] {
        guard points.count > maxCount else {
            return points.map { ElevationSample(distance: $0.cumulativeDistance, altitude: $0.altitude) }
        }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { i in
            let idx = min(Int((Double(i) * step).rounded()), points.count - 1)
            let p = points[idx]
            return ElevationSample(distance: p.cumulativeDistance, altitude: p.altitude)
        }
    }

    /// Binary search over the monotonically increasing cumulativeDistance.
    private static func nearestIndex(toDistance target: Double, in points: [RoutePoint]) -> Int {
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].cumulativeDistance < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // Pick whichever neighbor is closer.
        if lo > 0 {
            let prev = points[lo - 1].cumulativeDistance
            let cur = points[lo].cumulativeDistance
            if abs(prev - target) <= abs(cur - target) { return lo - 1 }
        }
        return lo
    }
}

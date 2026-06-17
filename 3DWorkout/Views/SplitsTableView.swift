import SwiftUI

/// Per-km (metric) or per-mi (imperial) splits derived from the route's
/// cumulative distance + timestamps. Pace is interpolated on the exact unit
/// boundary so the table matches what fitness apps display.
struct SplitsTableView: View {
    let route: WorkoutRoute
    let usesPace: Bool
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let units = settings.units
        let rows = Self.compute(route: route, units: units)

        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Splits", systemImage: "figure.run")
                        .font(.headline)
                    Spacer()
                    Text("per \(units.distanceUnit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SplitRow(index: index + 1,
                             total: rows.count,
                             row: row,
                             usesPace: usesPace,
                             units: units,
                             maxPace: rows.map { $0.secondsForUnit }.max() ?? 0)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Compute

    struct SplitRowData {
        /// Seconds spent in this split.
        let secondsForUnit: TimeInterval
        /// Distance, in meters, that this split covers (usually 1000 or 1609,
        /// but shorter for the last incomplete split).
        let distanceMeters: Double
    }

    static func compute(route: WorkoutRoute, units: UnitFormatter) -> [SplitRowData] {
        guard route.points.count > 1 else { return [] }
        let unitMeters = units.isMetric ? 1000.0 : 1609.344

        var rows: [SplitRowData] = []
        var prevBoundaryDist = 0.0
        var prevBoundaryTime = route.points[0].timestamp

        var nextBoundary = unitMeters
        var i = 1
        while i < route.points.count {
            let p0 = route.points[i - 1]
            let p1 = route.points[i]
            if p1.cumulativeDistance >= nextBoundary {
                // Linear interpolation to find the exact timestamp at the
                // split boundary.
                let span = p1.cumulativeDistance - p0.cumulativeDistance
                let t: Double = span > 0
                    ? (nextBoundary - p0.cumulativeDistance) / span
                    : 0
                let segTime = p1.timestamp.timeIntervalSince(p0.timestamp)
                let boundaryTime = p0.timestamp.addingTimeInterval(segTime * t)

                rows.append(SplitRowData(
                    secondsForUnit: boundaryTime.timeIntervalSince(prevBoundaryTime),
                    distanceMeters: nextBoundary - prevBoundaryDist
                ))
                prevBoundaryDist = nextBoundary
                prevBoundaryTime = boundaryTime
                nextBoundary += unitMeters
                // Don't advance i — the same segment might cross multiple boundaries.
            } else {
                i += 1
            }
        }

        // Last partial split, if any meaningful distance left over.
        let last = route.points.last!
        if last.cumulativeDistance > prevBoundaryDist + 1 {
            rows.append(SplitRowData(
                secondsForUnit: last.timestamp.timeIntervalSince(prevBoundaryTime),
                distanceMeters: last.cumulativeDistance - prevBoundaryDist
            ))
        }
        return rows
    }
}

// MARK: - Row

private struct SplitRow: View {
    let index: Int
    let total: Int
    let row: SplitsTableView.SplitRowData
    let usesPace: Bool
    let units: UnitFormatter
    let maxPace: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            // Pace / speed bar — width relative to slowest split.
            GeometryReader { geo in
                let ratio: CGFloat = maxPace > 0
                    ? CGFloat(row.secondsForUnit / maxPace)
                    : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(20, geo.size.width * ratio))
                }
            }
            .frame(height: 12)

            Text(label)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .frame(width: 80, alignment: .trailing)
        }
    }

    /// Heat-style fill: slower splits redder, faster splits greener.
    private var barColor: Color {
        guard maxPace > 0 else { return .green }
        let t = row.secondsForUnit / maxPace
        // green (fast) -> orange -> red (slow)
        return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
    }

    private var label: String {
        if usesPace {
            // Pace = seconds per unit. Format as m:ss.
            let total = Int(row.secondsForUnit)
            let m = total / 60, s = total % 60
            return String(format: "%d:%02d", m, s)
        } else {
            // Speed: distance / time in user's display unit.
            guard row.secondsForUnit > 0 else { return "--" }
            let mps = row.distanceMeters / row.secondsForUnit
            return "\(units.speed(mps, decimals: 1)) \(units.speedUnit)"
        }
    }
}

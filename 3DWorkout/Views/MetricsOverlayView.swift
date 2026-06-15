import SwiftUI

struct MetricsOverlayView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel

    private var currentMetrics: LiveMetrics {
        guard let route = viewModel.route else { return .empty }
        let idx = min(viewModel.animator.currentPointIndex, route.points.count - 1)
        let point = route.points[idx]
        let elapsed = point.cumulativeDistance
        let hr = viewModel.metrics?.heartRate(at: point.timestamp)
        return LiveMetrics(
            heartRate: hr,
            elevation: point.altitude,
            speed: point.speed,
            distance: elapsed
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            MetricTile(
                value: currentMetrics.heartRate.map { "\(Int($0))" } ?? "--",
                unit: "bpm",
                icon: "heart.fill",
                color: .red
            )
            Divider().frame(height: 36)
            MetricTile(
                value: currentMetrics.formattedSpeed,
                unit: "km/h",
                icon: "speedometer",
                color: .blue
            )
            Divider().frame(height: 36)
            MetricTile(
                value: currentMetrics.formattedElevation,
                unit: "m",
                icon: "arrow.up.right",
                color: .green
            )
            Divider().frame(height: 36)
            MetricTile(
                value: currentMetrics.formattedDistance,
                unit: "km",
                icon: "location.fill",
                color: .orange
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LiveMetrics {
    var heartRate: Double? = nil
    var elevation: Double? = nil
    var speed: Double? = nil    // m/s
    var distance: Double? = nil // meters

    static let empty = LiveMetrics()

    var formattedSpeed: String {
        guard let s = speed else { return "--" }
        return String(format: "%.1f", s * 3.6)
    }

    var formattedElevation: String {
        guard let e = elevation else { return "--" }
        return "\(Int(e))"
    }

    var formattedDistance: String {
        guard let d = distance else { return "--" }
        return String(format: "%.2f", d / 1000)
    }
}

private struct MetricTile: View {
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.callout, design: .monospaced).bold())
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

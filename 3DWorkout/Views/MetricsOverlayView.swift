import SwiftUI

struct MetricsOverlayView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel

    private var live: LiveMetrics {
        guard let route = viewModel.route, !route.points.isEmpty else { return .empty }
        let idx = min(viewModel.animator.currentPointIndex, route.points.count - 1)
        let pt = route.points[idx]
        return LiveMetrics(
            heartRate: viewModel.metrics?.heartRate(at: pt.timestamp),
            elevation: pt.altitude,
            speed: pt.speed,
            distance: pt.cumulativeDistance
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            MetricPill(icon: "heart.fill",    color: .red,    value: live.hrString,   unit: "bpm")
            divider
            if viewModel.session.usesPace {
                MetricPill(icon: "stopwatch.fill", color: .blue, value: live.paceString, unit: "/km")
            } else {
                MetricPill(icon: "speedometer", color: .blue, value: live.kmhString, unit: "km/h")
            }
            divider
            MetricPill(icon: "location.fill", color: .orange, value: live.distString, unit: "km")
            divider
            MetricPill(icon: "mountain.2.fill", color: .green, value: live.elevString, unit: "m")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.3))
            .frame(width: 0.5, height: 22)
    }
}

private struct MetricPill: View {
    let icon: String
    let color: Color
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 38)
    }
}

private struct LiveMetrics {
    var heartRate: Double? = nil
    var elevation: Double? = nil
    var speed: Double? = nil     // m/s
    var distance: Double? = nil  // meters

    static let empty = LiveMetrics()

    var hrString:   String { heartRate.map { "\(Int($0))" } ?? "--" }
    var kmhString:  String { speed.map { String(format: "%.1f", $0 * 3.6) } ?? "--" }
    var distString: String { distance.map { String(format: "%.2f", $0 / 1000) } ?? "--" }
    var elevString: String { elevation.map { "\(Int($0))" } ?? "--" }

    // Pace in min:sec per km. Below ~0.4 m/s (≈1.5 km/h) treat as stopped.
    var paceString: String {
        guard let s = speed, s > 0.4 else { return "--" }
        let secPerKm = 1000.0 / s
        guard secPerKm.isFinite, secPerKm < 60 * 60 else { return "--" }
        let m = Int(secPerKm) / 60
        let sec = Int(secPerKm) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

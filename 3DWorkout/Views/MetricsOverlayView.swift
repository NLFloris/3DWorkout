import SwiftUI

struct MetricsOverlayView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel
    @EnvironmentObject var settings: AppSettings

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
        let units = settings.units
        HStack(spacing: 14) {
            MetricPill(icon: "heart.fill", color: .red, value: live.hrString, unit: "bpm")
            divider
            if viewModel.session.usesPace {
                MetricPill(
                    icon: "stopwatch.fill", color: .blue,
                    value: live.speed.map { units.pace($0) } ?? "--",
                    unit: units.paceUnit
                )
            } else {
                MetricPill(
                    icon: "speedometer", color: .blue,
                    value: live.speed.map { units.speed($0) } ?? "--",
                    unit: units.speedUnit
                )
            }
            divider
            MetricPill(
                icon: "location.fill", color: .orange,
                value: live.distance.map { units.distanceValueString($0) } ?? "--",
                unit: units.distanceUnit
            )
            divider
            MetricPill(
                icon: "mountain.2.fill", color: .green,
                value: live.elevation.map { units.elevationValueString($0) } ?? "--",
                unit: units.elevationUnit
            )
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
    var elevation: Double? = nil  // meters
    var speed: Double? = nil      // m/s
    var distance: Double? = nil   // meters

    static let empty = LiveMetrics()

    var hrString: String { heartRate.map { "\(Int($0))" } ?? "--" }
}

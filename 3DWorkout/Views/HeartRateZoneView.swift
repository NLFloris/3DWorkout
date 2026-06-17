import SwiftUI
import Charts

/// Donut showing time-in-zone for the five standard training zones, derived
/// from the workout's heart-rate samples and the user's `maxHeartRate` setting.
struct HeartRateZoneView: View {
    let metrics: WorkoutMetrics

    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let zones = Self.compute(samples: metrics.heartRateSamples,
                                 maxHR: settings.maxHeartRate)
        let total = zones.map(\.seconds).reduce(0, +)

        if total == 0 {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Heart rate zones", systemImage: "heart.fill")
                        .font(.headline)
                    Spacer()
                    Text(formatDuration(total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 16) {
                    Chart(zones) { zone in
                        SectorMark(
                            angle: .value("Seconds", zone.seconds),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .foregroundStyle(zone.color)
                    }
                    .frame(width: 140, height: 140)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(zones) { zone in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(zone.color)
                                    .frame(width: 10, height: 10)
                                Text(zone.label)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(formatDuration(zone.seconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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

    struct ZoneBucket: Identifiable {
        let id = UUID()
        let label: String
        let lowerPct: Double
        let upperPct: Double
        let color: Color
        var seconds: TimeInterval
    }

    static func compute(samples: [MetricSample], maxHR: Double) -> [ZoneBucket] {
        var zones: [ZoneBucket] = [
            .init(label: "Z1 · Recovery",  lowerPct: 0.50, upperPct: 0.60, color: .blue,    seconds: 0),
            .init(label: "Z2 · Endurance", lowerPct: 0.60, upperPct: 0.70, color: .teal,    seconds: 0),
            .init(label: "Z3 · Tempo",     lowerPct: 0.70, upperPct: 0.80, color: .green,   seconds: 0),
            .init(label: "Z4 · Threshold", lowerPct: 0.80, upperPct: 0.90, color: .orange,  seconds: 0),
            .init(label: "Z5 · VO2 max",   lowerPct: 0.90, upperPct: 1.10, color: .red,     seconds: 0)
        ]
        guard samples.count > 1, maxHR > 0 else { return [] }

        // Sum the duration each sample is "responsible for" (gap to next
        // sample) into whichever zone the sample's HR falls into.
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        for i in 0..<(sorted.count - 1) {
            let s = sorted[i]
            let dt = sorted[i + 1].timestamp.timeIntervalSince(s.timestamp)
            // Skip absurd gaps (paused workouts) so the donut isn't dominated
            // by a single 30-minute "Z1" rest.
            guard dt > 0, dt < 60 else { continue }
            let pct = s.value / maxHR
            if let idx = zones.firstIndex(where: { pct >= $0.lowerPct && pct < $0.upperPct }) {
                zones[idx].seconds += dt
            } else if pct >= 1.10 {
                zones[zones.count - 1].seconds += dt
            }
        }
        return zones.filter { $0.seconds > 0 }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

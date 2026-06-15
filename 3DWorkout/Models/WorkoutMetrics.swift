import Foundation

struct MetricSample: Codable {
    let timestamp: Date
    let value: Double
}

struct WorkoutMetrics: Codable {
    var heartRateSamples: [MetricSample]    // bpm
    var paceIntervals: [MetricSample]       // sec/meter (distance samples used for pace derivation)
    var cadenceSamples: [MetricSample]      // steps/min
    var powerSamples: [MetricSample]        // watts

    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var minHeartRate: Double?
    var avgPaceSecPerKm: Double?
    var totalCalories: Double?

    func heartRate(at date: Date) -> Double? {
        nearest(in: heartRateSamples, at: date, tolerance: 60)
    }

    func pace(at date: Date) -> Double? {
        nearest(in: paceIntervals, at: date, tolerance: 120)
    }

    func cadence(at date: Date) -> Double? {
        nearest(in: cadenceSamples, at: date, tolerance: 60)
    }

    private func nearest(in samples: [MetricSample], at date: Date, tolerance: TimeInterval) -> Double? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            samples[mid].timestamp < date ? (lo = mid + 1) : (hi = mid)
        }
        var best = samples[lo]
        if lo > 0 {
            let prev = samples[lo - 1]
            if abs(prev.timestamp.timeIntervalSince(date)) < abs(best.timestamp.timeIntervalSince(date)) {
                best = prev
            }
        }
        guard abs(best.timestamp.timeIntervalSince(date)) <= tolerance else { return nil }
        return best.value
    }

    static let empty = WorkoutMetrics(
        heartRateSamples: [], paceIntervals: [], cadenceSamples: [], powerSamples: [],
        avgHeartRate: nil, maxHeartRate: nil, minHeartRate: nil,
        avgPaceSecPerKm: nil, totalCalories: nil
    )
}

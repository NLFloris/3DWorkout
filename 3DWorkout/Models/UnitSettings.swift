import Foundation
import Combine

/// User-facing measurement preference. `.automatic` resolves against the
/// device locale so the app defaults to the system setting until the user
/// overrides it.
enum UnitPreference: String, CaseIterable, Identifiable, Codable {
    case automatic, metric, imperial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .metric:    return "Metric"
        case .imperial:  return "Imperial"
        }
    }

    /// Whether this preference renders metric units, resolving `.automatic`
    /// against the current locale.
    var isMetric: Bool {
        switch self {
        case .metric:   return true
        case .imperial: return false
        case .automatic:
            return Locale.current.measurementSystem == .metric
        }
    }
}

/// Pure value type that converts SI source values (meters, m/s) into the
/// user's chosen display units and formats them as strings.
struct UnitFormatter {
    let isMetric: Bool

    private static let metersPerMile = 1609.344
    private static let feetPerMeter = 3.280839895
    private static let mphPerMps = 2.236936292

    // MARK: Distance (source: meters)

    var distanceUnit: String { isMetric ? "km" : "mi" }

    func distanceValue(_ meters: Double) -> Double {
        meters / (isMetric ? 1000 : Self.metersPerMile)
    }

    func distanceValueString(_ meters: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", distanceValue(meters))
    }

    func distance(_ meters: Double, decimals: Int = 2) -> String {
        "\(distanceValueString(meters, decimals: decimals)) \(distanceUnit)"
    }

    // MARK: Elevation (source: meters)

    var elevationUnit: String { isMetric ? "m" : "ft" }

    func elevationValue(_ meters: Double) -> Double {
        meters * (isMetric ? 1 : Self.feetPerMeter)
    }

    func elevationValueString(_ meters: Double) -> String {
        "\(Int(elevationValue(meters).rounded()))"
    }

    func elevation(_ meters: Double) -> String {
        "\(elevationValueString(meters)) \(elevationUnit)"
    }

    // MARK: Speed (source: m/s)

    var speedUnit: String { isMetric ? "km/h" : "mph" }

    func speedValue(_ mps: Double) -> Double {
        mps * (isMetric ? 3.6 : Self.mphPerMps)
    }

    func speed(_ mps: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", speedValue(mps))
    }

    // MARK: Pace (source: m/s) → "m:ss" per km / per mi

    var paceUnit: String { isMetric ? "/km" : "/mi" }

    /// Below ~0.4 m/s (≈1.5 km/h) treat as stopped to avoid nonsense paces.
    func pace(_ mps: Double) -> String {
        guard mps > 0.4 else { return "--" }
        let metersPerUnit = isMetric ? 1000.0 : Self.metersPerMile
        let secPerUnit = metersPerUnit / mps
        guard secPerUnit.isFinite, secPerUnit < 60 * 60 else { return "--" }
        let m = Int(secPerUnit) / 60
        let s = Int(secPerUnit) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// App-wide settings, persisted to `UserDefaults`. Injected as an
/// environment object so views re-render when the preference changes.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let unitKey = "unitPreference"

    @Published var unitPreference: UnitPreference {
        didSet { UserDefaults.standard.set(unitPreference.rawValue, forKey: unitKey) }
    }

    /// Formatter reflecting the current (resolved) preference.
    var units: UnitFormatter { UnitFormatter(isMetric: unitPreference.isMetric) }

    init() {
        let raw = UserDefaults.standard.string(forKey: unitKey)
        unitPreference = raw.flatMap(UnitPreference.init(rawValue:)) ?? .automatic
    }
}

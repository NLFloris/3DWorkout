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
///
/// Holds three groups: measurement units, workout-view defaults (consumed by
/// `WorkoutDetailViewModel.init`), and heatmap defaults (consumed by
/// `HeatmapViewModel` and the heatmap renderer).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // MARK: - Units

    @Published var unitPreference: UnitPreference {
        didSet { d.set(unitPreference.rawValue, forKey: K.unitPreference) }
    }

    var units: UnitFormatter { UnitFormatter(isMetric: unitPreference.isMetric) }

    // MARK: - Workout view defaults

    @Published var defaultGradientMetric: String {
        didSet { d.set(defaultGradientMetric, forKey: K.wvGradientMetric) }
    }
    @Published var defaultMapStyle: String {
        didSet { d.set(defaultMapStyle, forKey: K.wvMapStyle) }
    }
    @Published var defaultIs3DMode: Bool {
        didSet { d.set(defaultIs3DMode, forKey: K.wvIs3D) }
    }
    @Published var defaultPitch: Double {
        didSet { d.set(defaultPitch, forKey: K.wvPitch) }
    }
    @Published var defaultCameraDistance: Double {
        didSet { d.set(defaultCameraDistance, forKey: K.wvCameraDistance) }
    }
    @Published var defaultLineWidth: Double {
        didSet { d.set(defaultLineWidth, forKey: K.wvLineWidth) }
    }
    @Published var defaultAnimationSpeed: Double {
        didSet { d.set(defaultAnimationSpeed, forKey: K.wvAnimationSpeed) }
    }
    @Published var defaultRouteColorHex: String {
        didSet { d.set(defaultRouteColorHex, forKey: K.wvRouteColorHex) }
    }

    // MARK: - Workouts list defaults

    /// Determines how far back HealthKit is queried on cold launch — fetching
    /// "All time" out of HK can take seconds for long-time users, so the
    /// default is "30 days" and the user has to opt into more.
    @Published var workoutsListDateRange: HeatmapDateRange {
        didSet { d.set(workoutsListDateRange.rawValue, forKey: K.wlDateRange) }
    }

    // MARK: - Heatmap defaults

    @Published var heatmapDateRange: HeatmapDateRange {
        didSet { d.set(heatmapDateRange.rawValue, forKey: K.hmDateRange) }
    }
    @Published var heatmapSelectedSports: Set<String> {
        didSet {
            d.set(Array(heatmapSelectedSports), forKey: K.hmSelectedSports)
        }
    }
    @Published var heatmapLineAlpha: Double {
        didSet { d.set(heatmapLineAlpha, forKey: K.hmLineAlpha) }
    }
    @Published var heatmapLineWidth: Double {
        didSet { d.set(heatmapLineWidth, forKey: K.hmLineWidth) }
    }

    private enum K {
        static let unitPreference     = "unitPreference"
        static let wvGradientMetric   = "wv.gradientMetric"
        static let wvMapStyle         = "wv.mapStyle"
        static let wvIs3D             = "wv.is3D"
        static let wvPitch            = "wv.pitch"
        static let wvCameraDistance   = "wv.cameraDistance"
        static let wvLineWidth        = "wv.lineWidth"
        static let wvAnimationSpeed   = "wv.animationSpeed"
        static let wvRouteColorHex    = "wv.routeColorHex"
        static let wlDateRange        = "wl.dateRange"
        static let hmDateRange        = "hm.dateRange"
        static let hmSelectedSports   = "hm.selectedSports"
        static let hmLineAlpha        = "hm.lineAlpha"
        static let hmLineWidth        = "hm.lineWidth"
    }

    init() {
        // Units
        let unitRaw = d.string(forKey: K.unitPreference)
        unitPreference = unitRaw.flatMap(UnitPreference.init(rawValue:)) ?? .automatic

        // Workout view
        defaultGradientMetric = d.string(forKey: K.wvGradientMetric) ?? "pace"
        defaultMapStyle = d.string(forKey: K.wvMapStyle) ?? "hybrid"
        defaultIs3DMode = (d.object(forKey: K.wvIs3D) as? Bool) ?? true
        defaultPitch = (d.object(forKey: K.wvPitch) as? Double) ?? 60.0
        defaultCameraDistance = (d.object(forKey: K.wvCameraDistance) as? Double) ?? 400.0
        defaultLineWidth = (d.object(forKey: K.wvLineWidth) as? Double) ?? 4.0
        defaultAnimationSpeed = (d.object(forKey: K.wvAnimationSpeed) as? Double) ?? 4.0
        defaultRouteColorHex = d.string(forKey: K.wvRouteColorHex) ?? "#0A84FF"

        // Workouts list
        let wlRaw = d.string(forKey: K.wlDateRange)
        workoutsListDateRange = wlRaw.flatMap(HeatmapDateRange.init(rawValue:)) ?? .lastMonth

        // Heatmap
        let hmRaw = d.string(forKey: K.hmDateRange)
        heatmapDateRange = hmRaw.flatMap(HeatmapDateRange.init(rawValue:)) ?? .lastMonth
        let hmSports = (d.array(forKey: K.hmSelectedSports) as? [String]) ?? []
        heatmapSelectedSports = Set(hmSports)
        heatmapLineAlpha = (d.object(forKey: K.hmLineAlpha) as? Double) ?? 0.20
        heatmapLineWidth = (d.object(forKey: K.hmLineWidth) as? Double) ?? 3.0
    }
}

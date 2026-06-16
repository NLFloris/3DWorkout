import Foundation
import MapKit
import SwiftUI
import CoreLocation

enum HeatmapDateRange: String, CaseIterable, Identifiable, Codable {
    case lastWeek
    case lastMonth
    case lastYear
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lastWeek:  return "7 days"
        case .lastMonth: return "30 days"
        case .lastYear:  return "1 year"
        case .allTime:   return "All time"
        }
    }

    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .lastWeek:  return cal.date(byAdding: .day,   value: -7,  to: .now)
        case .lastMonth: return cal.date(byAdding: .day,   value: -30, to: .now)
        case .lastYear:  return cal.date(byAdding: .year,  value: -1,  to: .now)
        case .allTime:   return nil
        }
    }
}

/// One workout's track ready to be turned into an `MKPolyline`. We keep these
/// plain structs in the view model so the SwiftUI / MapKit boundary doesn't
/// have to know about SwiftData identity.
struct HeatmapTrack: Identifiable, Hashable {
    let id: UUID
    let sportType: String
    let coordinates: [CLLocationCoordinate2D]

    static func == (lhs: HeatmapTrack, rhs: HeatmapTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Selects which `CachedHeatmapTrack` records belong on the map. All work
/// happens on small, pre-summarized records — no per-point iteration.
@MainActor
final class HeatmapViewModel: ObservableObject {
    @Published var dateRange: HeatmapDateRange {
        didSet {
            settings.heatmapDateRange = dateRange
            reaggregate()
        }
    }
    @Published var selectedSports: Set<String> {
        didSet {
            settings.heatmapSelectedSports = selectedSports
            reaggregate()
        }
    }

    @Published private(set) var tracks: [HeatmapTrack] = []
    @Published private(set) var availableSports: [String] = []
    @Published private(set) var aggregatedBounds: MKCoordinateRegion?

    private let store: WorkoutStore
    private let settings: AppSettings

    init(store: WorkoutStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.dateRange = settings.heatmapDateRange
        self.selectedSports = settings.heatmapSelectedSports
        refreshAvailableSports()
        if selectedSports.isEmpty { selectedSports = Set(availableSports) }
        reaggregate()
    }

    func refreshAvailableSports() {
        let known = store.indexedSportTypes()
        availableSports = known
        // Auto-include newly-indexed sports we haven't seen before, but don't
        // touch user de-selections.
        if selectedSports.isEmpty { selectedSports = Set(known) }
    }

    /// Re-fetch the matching SwiftData track records and recompute the
    /// aggregated bounding box. Cheap — N records, no point-level work.
    func reaggregate() {
        let records = store.fetchHeatmapTracks(
            startDate: dateRange.startDate,
            sports: selectedSports
        )

        var newTracks: [HeatmapTrack] = []
        newTracks.reserveCapacity(records.count)
        var loLat = Double.infinity, hiLat = -Double.infinity
        var loLon = Double.infinity, hiLon = -Double.infinity
        for r in records {
            newTracks.append(HeatmapTrack(
                id: r.hkWorkoutUUID,
                sportType: r.sportType,
                coordinates: r.coordinates
            ))
            if r.minLat < loLat { loLat = r.minLat }
            if r.maxLat > hiLat { hiLat = r.maxLat }
            if r.minLon < loLon { loLon = r.minLon }
            if r.maxLon > hiLon { hiLon = r.maxLon }
        }

        tracks = newTracks
        aggregatedBounds = (loLat.isFinite && hiLat.isFinite)
            ? region(from: loLat, hiLat: hiLat, loLon: loLon, hiLon: hiLon)
            : nil
    }

    private func region(from loLat: Double, hiLat: Double,
                        loLon: Double, hiLon: Double) -> MKCoordinateRegion {
        let centre = CLLocationCoordinate2D(
            latitude: (loLat + hiLat) / 2,
            longitude: (loLon + hiLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((hiLat - loLat) * 1.2, 0.01),
            longitudeDelta: max((hiLon - loLon) * 1.2, 0.01)
        )
        return MKCoordinateRegion(center: centre, span: span)
    }
}

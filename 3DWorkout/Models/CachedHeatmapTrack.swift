import Foundation
import SwiftData
import CoreLocation

/// One workout's GPS track, downsampled and packed for the heatmap. We pack
/// `Float32` lat/lon pairs (8 B/point) and cap at ~200 points per route via a
/// Ramer–Douglas–Peucker simplification — a 1-hour run reduces from thousands
/// of samples to ~1.6 KB, and the heatmap is rendered as a single `MKPolyline`
/// per workout instead of thousands of per-point overlays.
@Model
final class CachedHeatmapTrack {
    @Attribute(.unique) var hkWorkoutUUID: UUID
    var sportType: String
    var startDate: Date

    // Bounding box used for cheap viewport intersection in viewmodel filters.
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    // Packed little-endian Float32 (lat, lon) pairs. Empty signals
    // "indexed, no GPS" so we don't try to refetch.
    var polylineData: Data
    var pointCount: Int

    init(hkWorkoutUUID: UUID,
         sportType: String,
         startDate: Date,
         coords: [CLLocationCoordinate2D]) {
        self.hkWorkoutUUID = hkWorkoutUUID
        self.sportType = sportType
        self.startDate = startDate

        if coords.isEmpty {
            self.minLat = 0; self.maxLat = 0
            self.minLon = 0; self.maxLon = 0
        } else {
            var loLat =  Double.infinity, hiLat = -Double.infinity
            var loLon =  Double.infinity, hiLon = -Double.infinity
            for c in coords {
                if c.latitude  < loLat { loLat = c.latitude  }
                if c.latitude  > hiLat { hiLat = c.latitude  }
                if c.longitude < loLon { loLon = c.longitude }
                if c.longitude > hiLon { hiLon = c.longitude }
            }
            self.minLat = loLat; self.maxLat = hiLat
            self.minLon = loLon; self.maxLon = hiLon
        }
        self.polylineData = CachedHeatmapTrack.pack(coords)
        self.pointCount = coords.count
    }

    /// Decoded coordinates — cheap, but call once per render and reuse.
    var coordinates: [CLLocationCoordinate2D] {
        CachedHeatmapTrack.unpack(polylineData)
    }

    static let coordByteSize = MemoryLayout<Float32>.size * 2  // 8 bytes

    static func pack(_ coords: [CLLocationCoordinate2D]) -> Data {
        var data = Data(capacity: coords.count * coordByteSize)
        for c in coords {
            var lat = Float32(c.latitude).bitPattern.littleEndian
            var lon = Float32(c.longitude).bitPattern.littleEndian
            withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [CLLocationCoordinate2D] {
        let count = data.count / coordByteSize
        guard count > 0 else { return [] }
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for i in 0..<count {
                let p = base.advanced(by: i * coordByteSize)
                let lat = Float32(bitPattern: p.load(as: UInt32.self).littleEndian)
                let lon = Float32(bitPattern: p.advanced(by: 4).load(as: UInt32.self).littleEndian)
                out.append(CLLocationCoordinate2D(
                    latitude: Double(lat),
                    longitude: Double(lon)
                ))
            }
        }
        return out
    }
}

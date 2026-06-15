import Foundation
import CoreLocation
import MapKit

struct RoutePoint: Identifiable, Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    var speed: Double?              // m/s, derived after full route is built
    var cumulativeDistance: Double  // meters from start

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct WorkoutRoute: Codable {
    var points: [RoutePoint]
    var totalDistance: Double
    var elevationGain: Double
    var elevationLoss: Double
    var minAltitude: Double
    var maxAltitude: Double
    var minSpeed: Double
    var maxSpeed: Double

    var boundingRegion: MKCoordinateRegion {
        guard !points.isEmpty else { return MKCoordinateRegion() }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.002),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.002)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    static func build(from locations: [CLLocation]) -> WorkoutRoute {
        guard !locations.isEmpty else {
            return WorkoutRoute(points: [], totalDistance: 0, elevationGain: 0,
                                elevationLoss: 0, minAltitude: 0, maxAltitude: 0,
                                minSpeed: 0, maxSpeed: 0)
        }

        var points: [RoutePoint] = []
        var cumulative = 0.0
        var elevGain = 0.0
        var elevLoss = 0.0

        for (i, loc) in locations.enumerated() {
            if i > 0 {
                cumulative += loc.distance(from: locations[i - 1])
                let dAlt = loc.altitude - locations[i - 1].altitude
                if dAlt > 0 { elevGain += dAlt } else { elevLoss += abs(dAlt) }
            }
            points.append(RoutePoint(
                id: UUID(),
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude,
                timestamp: loc.timestamp,
                speed: nil,
                cumulativeDistance: cumulative
            ))
        }

        // Derive per-point speed from neighbors
        for i in points.indices {
            guard i > 0, i < points.count - 1 else { points[i].speed = 0; continue }
            let prev = points[i - 1]
            let next = points[i + 1]
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            let dt = next.timestamp.timeIntervalSince(prev.timestamp)
            points[i].speed = dt > 0 ? dist / dt : 0
        }

        let speeds = points.compactMap(\.speed).filter { $0 > 0 }
        let alts = points.map(\.altitude)

        return WorkoutRoute(
            points: points,
            totalDistance: cumulative,
            elevationGain: elevGain,
            elevationLoss: elevLoss,
            minAltitude: alts.min() ?? 0,
            maxAltitude: alts.max() ?? 0,
            minSpeed: speeds.min() ?? 0,
            maxSpeed: speeds.max() ?? 0
        )
    }
}

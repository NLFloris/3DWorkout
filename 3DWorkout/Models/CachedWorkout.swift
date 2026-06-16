import Foundation
import SwiftData

/// On-disk cache of a workout, keyed by its stable HealthKit UUID. Metadata is
/// stored as columns; the heavy route/metrics payloads are encoded blobs filled
/// lazily on first open so the list loads instantly and routes aren't refetched
/// from HealthKit every time.
@Model
final class CachedWorkout {
    @Attribute(.unique) var hkWorkoutUUID: UUID

    var workoutType: String
    var workoutTypeIcon: String
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var totalDistance: Double?
    var totalEnergyBurned: Double?
    var usesPace: Bool

    // Lazily-filled payloads (encoded Codable).
    var routeData: Data?
    /// Distinguishes "fetched, has no GPS route" from "not yet fetched".
    var routeFetched: Bool
    var metricsData: Data?

    // Reserved for upcoming features; declared now so the schema is
    // forward-compatible and won't need a migration later.
    var segmentsData: Data?      // Feature 4 — Segment PRs
    var routeFingerprint: String? // Feature 5 — Ghost runner route matching

    var lastSyncedAt: Date

    init(session: WorkoutSession, syncedAt: Date = .now) {
        hkWorkoutUUID = session.hkWorkoutUUID
        workoutType = session.workoutType
        workoutTypeIcon = session.workoutTypeIcon
        startDate = session.startDate
        endDate = session.endDate
        duration = session.duration
        totalDistance = session.totalDistance
        totalEnergyBurned = session.totalEnergyBurned
        usesPace = session.usesPace
        routeData = nil
        routeFetched = false
        metricsData = nil
        segmentsData = nil
        routeFingerprint = nil
        lastSyncedAt = syncedAt
    }

    /// Refreshes metadata fields from a freshly-fetched session, leaving the
    /// cached route/metrics payloads intact.
    func applyMetadata(from session: WorkoutSession, syncedAt: Date = .now) {
        workoutType = session.workoutType
        workoutTypeIcon = session.workoutTypeIcon
        startDate = session.startDate
        endDate = session.endDate
        duration = session.duration
        totalDistance = session.totalDistance
        totalEnergyBurned = session.totalEnergyBurned
        usesPace = session.usesPace
        lastSyncedAt = syncedAt
    }

    /// Metadata-only `WorkoutSession`. Identity uses the stable HealthKit UUID
    /// so list/navigation identity is consistent across refreshes.
    var asSession: WorkoutSession {
        WorkoutSession(
            id: hkWorkoutUUID,
            hkWorkoutUUID: hkWorkoutUUID,
            workoutType: workoutType,
            workoutTypeIcon: workoutTypeIcon,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            totalDistance: totalDistance,
            totalEnergyBurned: totalEnergyBurned,
            usesPace: usesPace,
            route: nil,
            metrics: nil
        )
    }
}

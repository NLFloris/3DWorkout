import Foundation
import SwiftData

/// Local persistence layer backed by SwiftData. Mirrors HealthKit so the app
/// launches instantly from disk and avoids refetching heavy route data. Also
/// the foundation for cross-workout features (Segment PRs, heatmap, ghost runner).
@MainActor
final class WorkoutStore: ObservableObject {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let schema = Schema([CachedWorkout.self])
        if let onDisk = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ) {
            container = onDisk
        } else {
            // Fall back to an in-memory store so the app still runs even if the
            // on-disk store can't be opened (e.g. a failed migration).
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    // MARK: - Metadata

    /// Cached workouts as metadata-only sessions, newest first.
    func cachedSessions() -> [WorkoutSession] {
        let descriptor = FetchDescriptor<CachedWorkout>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.map(\.asSession)
    }

    /// Inserts new workouts and refreshes metadata for existing ones, keyed by
    /// HealthKit UUID. Cached route/metrics payloads are preserved.
    func syncMetadata(_ sessions: [WorkoutSession]) {
        let now = Date.now
        for session in sessions {
            if let existing = model(for: session.hkWorkoutUUID) {
                existing.applyMetadata(from: session, syncedAt: now)
            } else {
                context.insert(CachedWorkout(session: session, syncedAt: now))
            }
        }
        save()
    }

    // MARK: - Route

    /// Cached route. `fetched` distinguishes "known to have no GPS route" from
    /// "not yet fetched from HealthKit".
    func cachedRoute(for uuid: UUID) -> (fetched: Bool, route: WorkoutRoute?) {
        guard let model = model(for: uuid), model.routeFetched else { return (false, nil) }
        guard let data = model.routeData else { return (true, nil) }
        return (true, try? decoder.decode(WorkoutRoute.self, from: data))
    }

    func storeRoute(_ route: WorkoutRoute?, for uuid: UUID) {
        guard let model = model(for: uuid) else { return }
        model.routeData = route.flatMap { try? encoder.encode($0) }
        model.routeFetched = true
        save()
    }

    // MARK: - Metrics

    func cachedMetrics(for uuid: UUID) -> WorkoutMetrics? {
        guard let data = model(for: uuid)?.metricsData else { return nil }
        return try? decoder.decode(WorkoutMetrics.self, from: data)
    }

    func storeMetrics(_ metrics: WorkoutMetrics, for uuid: UUID) {
        guard let model = model(for: uuid) else { return }
        model.metricsData = try? encoder.encode(metrics)
        save()
    }

    // MARK: - Private

    private func model(for uuid: UUID) -> CachedWorkout? {
        var descriptor = FetchDescriptor<CachedWorkout>(
            predicate: #Predicate { $0.hkWorkoutUUID == uuid }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        try? context.save()  // best-effort cache; transient failures are non-fatal
    }
}

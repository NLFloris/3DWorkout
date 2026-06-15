import Foundation
import HealthKit
import CoreLocation

enum HKAuthorizationStatus {
    case notDetermined, authorized, denied
}

@MainActor
final class HealthKitService: ObservableObject {
    @Published var authorizationStatus: HKAuthorizationStatus = .notDetermined

    private let store = HKHealthStore()

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        for id: HKQuantityTypeIdentifier in [
            .heartRate, .activeEnergyBurned,
            .distanceWalkingRunning, .distanceCycling, .stepCount
        ] {
            types.insert(HKQuantityType(id))
        }
        return types
    }()

    init() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = .denied
            return
        }
        refreshStatus()
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = .denied
            return
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        refreshStatus()
    }

    func refreshStatus() {
        let status = store.authorizationStatus(for: HKObjectType.workoutType())
        switch status {
        case .sharingAuthorized: authorizationStatus = .authorized
        case .sharingDenied:     authorizationStatus = .denied
        case .notDetermined:     authorizationStatus = .notDetermined
        @unknown default:        authorizationStatus = .notDetermined
        }
    }

    // MARK: - Workouts

    func fetchWorkouts() async throws -> [WorkoutSession] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .running),
            HKQuery.predicateForWorkouts(with: .cycling),
            HKQuery.predicateForWorkouts(with: .walking),
            HKQuery.predicateForWorkouts(with: .hiking),
            HKQuery.predicateForWorkouts(with: .swimming),
        ])

        let hkWorkouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 100,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }

        return hkWorkouts.map { WorkoutSession(from: $0) }
    }

    // MARK: - Route

    func fetchRoute(for session: WorkoutSession) async throws -> WorkoutRoute? {
        guard let hkWorkout = try await fetchHKWorkout(uuid: session.hkWorkoutUUID) else { return nil }

        let routeSamples: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let predicate = HKQuery.predicateForObjects(from: hkWorkout)
            let q = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }

        guard let routeSample = routeSamples.first else { return nil }
        let locations = try await fetchLocations(from: routeSample)
        guard !locations.isEmpty else { return nil }
        return WorkoutRoute.build(from: locations)
    }

    // MARK: - Metrics

    func fetchMetrics(for session: WorkoutSession) async throws -> WorkoutMetrics {
        let interval = DateInterval(start: session.startDate, end: session.endDate)
        async let hr = fetchQuantitySamples(type: HKQuantityType(.heartRate),
                                            unit: HKUnit(from: "count/min"),
                                            interval: interval)
        async let dist = fetchQuantitySamples(type: HKQuantityType(.distanceWalkingRunning),
                                              unit: .meter(),
                                              interval: interval)

        let hrSamples = try await hr
        let distSamples = try await dist

        let avgHR: Double? = hrSamples.isEmpty ? nil : hrSamples.map(\.value).reduce(0, +) / Double(hrSamples.count)
        let maxHR = hrSamples.map(\.value).max()
        let minHR = hrSamples.map(\.value).min()

        return WorkoutMetrics(
            heartRateSamples: hrSamples,
            paceIntervals: distSamples,
            cadenceSamples: [],
            powerSamples: [],
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            minHeartRate: minHR,
            avgPaceSecPerKm: nil,
            totalCalories: session.totalEnergyBurned
        )
    }

    // MARK: - Private helpers

    private func fetchHKWorkout(uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        let results: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        return results.first
    }

    private func fetchLocations(from route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { cont in
            var accumulated: [CLLocation] = []
            var resumed = false
            let q = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                    return
                }
                accumulated.append(contentsOf: locations ?? [])
                if done && !resumed {
                    resumed = true
                    cont.resume(returning: accumulated)
                }
            }
            store.execute(q)
        }
    }

    private func fetchQuantitySamples(
        type: HKQuantityType,
        unit: HKUnit,
        interval: DateInterval
    ) async throws -> [MetricSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let result = (samples as? [HKQuantitySample] ?? []).map {
                    MetricSample(timestamp: $0.startDate, value: $0.quantity.doubleValue(for: unit))
                }
                cont.resume(returning: result)
            }
            store.execute(q)
        }
    }
}

import Foundation
import HealthKit

struct WorkoutSession: Identifiable, Codable {
    let id: UUID
    let hkWorkoutUUID: UUID
    let workoutType: String
    let workoutTypeIcon: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistance: Double?      // meters
    let totalEnergyBurned: Double?  // kcal
    var route: WorkoutRoute?
    var metrics: WorkoutMetrics?

    var formattedDuration: String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var formattedDistance: String? {
        guard let d = totalDistance else { return nil }
        return String(format: "%.2f km", d / 1000)
    }

    var formattedCalories: String? {
        guard let c = totalEnergyBurned else { return nil }
        return "\(Int(c)) kcal"
    }
}

extension WorkoutSession {
    init(from workout: HKWorkout) {
        self.id = UUID()
        self.hkWorkoutUUID = workout.uuid
        self.workoutType = workout.workoutActivityType.displayName
        self.workoutTypeIcon = workout.workoutActivityType.systemIcon
        self.startDate = workout.startDate
        self.endDate = workout.endDate
        self.duration = workout.duration
        self.totalDistance = workout.totalDistance?.doubleValue(for: .meter())
        self.totalEnergyBurned = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        self.route = nil
        self.metrics = nil
    }
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running:  return "Running"
        case .cycling:  return "Cycling"
        case .walking:  return "Walking"
        case .hiking:   return "Hiking"
        case .swimming: return "Swimming"
        default:        return "Workout"
        }
    }

    var systemIcon: String {
        switch self {
        case .running:  return "figure.run"
        case .cycling:  return "figure.outdoor.cycle"
        case .walking:  return "figure.walk"
        case .hiking:   return "figure.hiking"
        case .swimming: return "figure.pool.swim"
        default:        return "heart.fill"
        }
    }
}

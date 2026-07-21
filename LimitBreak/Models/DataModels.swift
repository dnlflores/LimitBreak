import Foundation
import SwiftData

// MARK: - Enums

enum TrackingType: String, Codable, CaseIterable, Identifiable {
    case weightAndReps = "Weight & Reps"
    case bodyweightAndReps = "Bodyweight + Reps"
    case durationAndReps = "Duration & Reps"
    case timeAndDistance = "Time & Distance"
    case customMetric = "Custom Metric"

    var id: String { rawValue }
}

enum OneRMFormula: String, Codable, CaseIterable, Identifiable {
    case epley = "Epley"
    case brzycki = "Brzycki"
    case rawMax = "Raw Max Weight"

    var id: String { rawValue }

    func estimate(weight: Double, reps: Int) -> Double {
        guard reps > 0, weight > 0 else { return 0 }
        guard reps > 1 else { return weight }
        switch self {
        case .epley:   return weight * (1.0 + Double(reps) / 30.0)
        case .brzycki: return reps < 37 ? weight * 36.0 / (37.0 - Double(reps)) : weight * 2
        case .rawMax:  return weight
        }
    }
}

enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest = "Chest", lats = "Lats", quads = "Quads", hamstrings = "Hamstrings"
    case deltoids = "Deltoids", triceps = "Triceps", biceps = "Biceps", core = "Core"
    case calves = "Calves", glutes = "Glutes", forearms = "Forearms"

    var id: String { rawValue }
}

enum EquipmentType: String, Codable, CaseIterable, Identifiable {
    case barbell = "Barbell", dumbbell = "Dumbbell", cable = "Cable", machine = "Machine"
    case kettlebell = "Kettlebell", bodyweight = "Bodyweight"
    case resistanceBand = "Resistance Band", specialtyBar = "Specialty Bar"

    var id: String { rawValue }
}

// MARK: - Exercise Model

@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var name: String
    var muscleGroupRaw: String
    var secondaryMuscles: [String]
    var trackingTypeRaw: String
    var equipmentType: String
    var defaultIncrement: Double
    var defaultRestSeconds: Int
    var formulaRaw: String
    var customMetricUnit: String?
    var isCustom: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.exercise)
    var sets: [ExerciseSet]

    @Relationship(deleteRule: .cascade, inverse: \PRRecord.exercise)
    var prRecords: [PRRecord]

    init(
        name: String,
        muscleGroup: String,
        secondaryMuscles: [String] = [],
        trackingType: TrackingType = .weightAndReps,
        equipmentType: String = "Barbell",
        defaultIncrement: Double = 5.0,
        defaultRestSeconds: Int = 90,
        formula: OneRMFormula = .epley,
        customMetricUnit: String? = nil,
        isCustom: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.muscleGroupRaw = muscleGroup
        self.secondaryMuscles = secondaryMuscles
        self.trackingTypeRaw = trackingType.rawValue
        self.equipmentType = equipmentType
        self.defaultIncrement = defaultIncrement
        self.defaultRestSeconds = defaultRestSeconds
        self.formulaRaw = formula.rawValue
        self.customMetricUnit = customMetricUnit
        self.isCustom = isCustom
        self.createdAt = Date()
        self.sets = []
        self.prRecords = []
    }

    var trackingType: TrackingType { TrackingType(rawValue: trackingTypeRaw) ?? .weightAndReps }
    var formula: OneRMFormula { OneRMFormula(rawValue: formulaRaw) ?? .epley }
    var muscleGroup: MuscleGroup { MuscleGroup(rawValue: muscleGroupRaw) ?? .chest }

    /// All muscle groups this exercise hits: primary first, then secondaries.
    var allMuscleGroups: [MuscleGroup] {
        var groups = [muscleGroup]
        for raw in secondaryMuscles {
            if let group = MuscleGroup(rawValue: raw), !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }

    /// Historical best value for the given record type (the LimitBreak "ceiling").
    func ceiling(for recordType: String) -> Double {
        prRecords.filter { $0.recordType == recordType }.map(\.numericValue).max() ?? 0
    }
}

// MARK: - Workout Session Model

@Model
final class WorkoutSession {
    @Attribute(.unique) var id: UUID
    var name: String
    var startDate: Date
    var endDate: Date?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.session)
    var sets: [ExerciseSet]

    init(name: String, startDate: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.startDate = startDate
        self.sets = []
    }

    var totalVolume: Double {
        sets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.weight * Double($1.reps) }
    }

    var prCount: Int { sets.filter(\.isPR).count }

    var duration: TimeInterval {
        let end = endDate ?? sets.map(\.timestamp).max() ?? startDate
        return end.timeIntervalSince(startDate)
    }

    /// Sets grouped by exercise, in first-logged order — powers day breakdowns.
    var setsByExercise: [(exercise: Exercise, sets: [ExerciseSet])] {
        var order: [UUID] = []
        var buckets: [UUID: (exercise: Exercise, sets: [ExerciseSet])] = [:]
        for set in sets.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let exercise = set.exercise else { continue }
            if buckets[exercise.id] == nil {
                order.append(exercise.id)
                buckets[exercise.id] = (exercise, [])
            }
            buckets[exercise.id]?.sets.append(set)
        }
        return order.compactMap { buckets[$0] }
    }
}

// MARK: - Exercise Set Model

@Model
final class ExerciseSet {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var weight: Double
    var reps: Int
    var durationSeconds: Double?
    var distanceMeters: Double?
    var isWarmup: Bool
    var isPR: Bool

    var exercise: Exercise?
    var session: WorkoutSession?

    init(
        weight: Double,
        reps: Int,
        durationSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        isWarmup: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.weight = weight
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.isWarmup = isWarmup
        self.isPR = false
    }

    /// Estimated 1RM using the parent exercise's configured formula (Epley by default).
    var estimatedOneRepMax: Double {
        (exercise?.formula ?? .epley).estimate(weight: weight, reps: reps)
    }
}

// MARK: - PR Record Model

@Model
final class PRRecord {
    @Attribute(.unique) var id: UUID
    var dateAchieved: Date
    var recordType: String // "1RM", "Max Reps", "Max Duration", "Max Distance", "Max Value"
    var numericValue: Double
    var repsAchieved: Int

    var exercise: Exercise?

    init(
        recordType: String,
        numericValue: Double,
        repsAchieved: Int,
        exercise: Exercise? = nil,
        dateAchieved: Date = Date()
    ) {
        self.id = UUID()
        self.dateAchieved = dateAchieved
        self.recordType = recordType
        self.numericValue = numericValue
        self.repsAchieved = repsAchieved
        self.exercise = exercise
    }
}

// MARK: - Walk Model

/// A single coordinate sample along a hand-drawn walk route.
struct RoutePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
}

@Model
final class Walk {
    @Attribute(.unique) var id: UUID
    var date: Date
    var durationSeconds: Double
    var distanceMeters: Double
    var routePoints: [RoutePoint]
    var notes: String?

    init(
        date: Date = Date(),
        durationSeconds: Double = 0,
        distanceMeters: Double = 0,
        routePoints: [RoutePoint] = [],
        notes: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.routePoints = routePoints
        self.notes = notes
    }

    var distanceMiles: Double { distanceMeters / 1609.344 }
}

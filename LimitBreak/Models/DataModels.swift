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
    /// Assisted movements (e.g. assisted pull-ups) accept negative weight:
    /// the value is assistance provided, so more negative = easier.
    var isAssisted: Bool = false
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.exercise)
    var sets: [ExerciseSet]

    @Relationship(deleteRule: .cascade, inverse: \PRRecord.exercise)
    var prRecords: [PRRecord]

    /// Routine slots that reference this exercise. Nullified (not cascaded) when
    /// the exercise is deleted so a routine simply drops the missing movement.
    @Relationship(deleteRule: .nullify, inverse: \RoutineItem.exercise)
    var routineItems: [RoutineItem] = []

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
        isCustom: Bool = false,
        isAssisted: Bool = false
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
        self.isAssisted = isAssisted
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
        // Assisted sets carry negative weight (assistance); they add no volume.
        sets.filter { !$0.isWarmup }.reduce(0) { $0 + max(0, $1.weight) * Double($1.reps) }
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

    /// Per-rep values captured with the expanding rep-row logging UX. For
    /// weight-based types these are the weight lifted on each rep (lbs); for
    /// duration-based types they are the seconds held per rep. Empty for sets
    /// logged before this UX existed or via the time/distance dials — those
    /// remain fully described by `weight`/`reps`/`durationSeconds`.
    var repWeights: [Double] = []

    var exercise: Exercise?
    var session: WorkoutSession?

    init(
        weight: Double,
        reps: Int,
        durationSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        isWarmup: Bool = false,
        repWeights: [Double] = [],
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.weight = weight
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.isWarmup = isWarmup
        self.repWeights = repWeights
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

// MARK: - Routine (saved workout curation)

/// A reusable, curated workout: a named, ordered list of exercises with a
/// target set count each. Started with one tap to pre-load a live session, or
/// generated by the on-device AI. This is the "curation" the user builds up.
@Model
final class Routine {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String?
    var createdAt: Date
    var isAIGenerated: Bool
    /// Optional focus tag (e.g. "Push", "Legs") for AI-generated routines.
    var focusLabel: String?

    @Relationship(deleteRule: .cascade, inverse: \RoutineItem.routine)
    var items: [RoutineItem]

    init(
        name: String,
        notes: String? = nil,
        isAIGenerated: Bool = false,
        focusLabel: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.isAIGenerated = isAIGenerated
        self.focusLabel = focusLabel
        self.createdAt = createdAt
        self.items = []
    }

    /// Items in their curated order.
    var orderedItems: [RoutineItem] {
        items.sorted { $0.order < $1.order }
    }

    /// The ordered exercises, dropping any slot whose exercise was deleted.
    var exercises: [Exercise] {
        orderedItems.compactMap(\.exercise)
    }

    /// Number of live movements (ignores slots orphaned by a deleted exercise).
    var exerciseCount: Int {
        items.reduce(0) { $0 + ($1.exercise == nil ? 0 : 1) }
    }
}

/// One slot in a `Routine`: an exercise plus how many working sets to aim for.
@Model
final class RoutineItem {
    @Attribute(.unique) var id: UUID
    var order: Int
    var targetSets: Int

    var exercise: Exercise?
    var routine: Routine?

    init(order: Int, targetSets: Int = 3, exercise: Exercise? = nil) {
        self.id = UUID()
        self.order = order
        self.targetSets = max(1, targetSets)
        self.exercise = exercise
    }
}

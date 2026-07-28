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
    case chest = "Chest", lats = "Lats", traps = "Traps", quads = "Quads"
    case hamstrings = "Hamstrings", deltoids = "Deltoids", triceps = "Triceps"
    case biceps = "Biceps", core = "Core", calves = "Calves", glutes = "Glutes"
    case forearms = "Forearms"

    var id: String { rawValue }

    /// What the app calls this muscle everywhere the user can see it. Raw values
    /// are the stored identity (SwiftData, the bundled catalog JSON, the watch
    /// payload) and must never change — so the two groups whose anatomical names
    /// read as jargon get gym names here instead of a data migration.
    var displayName: String {
        switch self {
        case .lats: return "Back"
        case .deltoids: return "Shoulders"
        default: return rawValue
        }
    }
}

enum EquipmentType: String, Codable, CaseIterable, Identifiable {
    case barbell = "Barbell", dumbbell = "Dumbbell", cable = "Cable", machine = "Machine"
    case kettlebell = "Kettlebell", bodyweight = "Bodyweight"
    case resistanceBand = "Resistance Band", specialtyBar = "Specialty Bar"

    var id: String { rawValue }
}

/// The unit a weight-tracked exercise is entered and displayed in. Weight is
/// always *stored* in pounds (the app's canonical currency for volume, XP, PRs
/// and 1RM); this only governs how a movement's loads are shown and typed, so
/// switching it is instant and never rewrites history.
enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case pounds = "lb"
    case kilograms = "kg"

    var id: String { rawValue }

    /// Label shown next to a value, e.g. "185 lbs" / "84 kg".
    var abbreviation: String {
        switch self {
        case .pounds: return "lbs"
        case .kilograms: return "kg"
        }
    }

    /// Compact two-letter tag for toggles.
    var tag: String { rawValue }

    private static let poundsPerKilogram = 2.2046226218

    /// Convert a value expressed in this unit into canonical pounds.
    func toPounds(_ value: Double) -> Double {
        self == .pounds ? value : value * Self.poundsPerKilogram
    }

    /// Convert canonical pounds into a value expressed in this unit.
    func fromPounds(_ pounds: Double) -> Double {
        self == .pounds ? pounds : pounds / Self.poundsPerKilogram
    }
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
    /// The unit this movement's weights are entered and shown in. Defaults to
    /// pounds so existing data (all stored in pounds) is unaffected.
    var weightUnitRaw: String = WeightUnit.pounds.rawValue
    var isCustom: Bool
    /// Assisted movements (e.g. assisted pull-ups) accept negative weight:
    /// the value is assistance provided, so more negative = easier.
    var isAssisted: Bool = false
    /// Optional guide: what this movement is for.
    var exerciseDescription: String? = nil
    /// Optional how-to, one step per line.
    var instructions: String? = nil
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
        weightUnit: WeightUnit = .pounds,
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
        self.weightUnitRaw = weightUnit.rawValue
        self.isCustom = isCustom
        self.isAssisted = isAssisted
        self.createdAt = Date()
        self.sets = []
        self.prRecords = []
    }

    var trackingType: TrackingType { TrackingType(rawValue: trackingTypeRaw) ?? .weightAndReps }
    var formula: OneRMFormula { OneRMFormula(rawValue: formulaRaw) ?? .epley }
    var muscleGroup: MuscleGroup { MuscleGroup(rawValue: muscleGroupRaw) ?? .chest }
    var weightUnit: WeightUnit {
        get { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }
        set { weightUnitRaw = newValue.rawValue }
    }

    /// Whether loads for this movement are a real weight (so a lb/kg unit
    /// applies). Duration, distance and custom-metric movements have their own
    /// units and ignore `weightUnit`.
    var usesWeightUnit: Bool {
        trackingType == .weightAndReps || trackingType == .bodyweightAndReps
    }

    /// Whether having a spotter meaningfully changes how heavy this movement can
    /// be run. A spot only buys confidence on free-weight lifts where the load
    /// can pin you — pressing, squatting, overhead work. Machines, cables and
    /// bodyweight movements have their own bail-outs, so a partner doesn't
    /// license more weight there.
    var benefitsFromSpotter: Bool {
        guard trackingType == .weightAndReps else { return false }
        switch EquipmentType(rawValue: equipmentType) {
        case .barbell, .dumbbell, .specialtyBar: return true
        default: return false
        }
    }

    /// The load to suggest when a partner is spotting: `pounds` nudged up by 5%
    /// and snapped to this movement's increment, but never by less than one
    /// increment (so a light lift still moves). Movements a spot doesn't help
    /// come back unchanged.
    func spottedLoad(fromPounds pounds: Double) -> Double {
        guard benefitsFromSpotter, pounds > 0 else { return pounds }
        let increment = defaultIncrement > 0 ? defaultIncrement : 5
        let bumped = (pounds * 1.05 / increment).rounded() * increment
        return max(bumped, pounds + increment)
    }

    /// Format a canonical pounds value in this movement's unit, e.g. "84".
    func displayWeightString(fromPounds pounds: Double) -> String {
        weightUnit.fromPounds(pounds).cleanWeight
    }

    /// The primary muscle's UI name — use this anywhere a muscle is shown,
    /// never `muscleGroupRaw` (see `MuscleGroup.displayName`).
    var muscleGroupDisplay: String { muscleGroup.displayName }

    /// Secondary muscles under their UI names, in stored order.
    var secondaryMuscleDisplayNames: [String] {
        secondaryMuscles.compactMap { MuscleGroup(rawValue: $0)?.displayName }
    }

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

    /// The how-to split into displayable steps (one per non-empty line).
    var instructionSteps: [String] {
        (instructions ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    /// Whether this session was trained alongside a partner. Defaults to false
    /// so every session logged before this existed reads as solo.
    var trainedWithPartner: Bool = false

    /// The routine this session was started from, if any. Stamped so routine
    /// mastery can count how many times a saved workout has been run. Nil for
    /// ad-hoc sessions and every session logged before this existed.
    var startedFromRoutineID: UUID? = nil

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.session)
    var sets: [ExerciseSet]

    init(name: String, startDate: Date = Date(), trainedWithPartner: Bool = false) {
        self.id = UUID()
        self.name = name
        self.startDate = startDate
        self.trainedWithPartner = trainedWithPartner
        self.sets = []
    }

    var totalVolume: Double {
        // Effective load counts body weight on stamped sets; a fully assisted
        // set can't go below zero contribution.
        sets.filter { !$0.isWarmup }.reduce(0) { $0 + max(0, $1.effectiveLoad) * Double($1.reps) }
    }

    var prCount: Int { sets.filter(\.isPR).count }

    /// The session's whole-body effort signal, derived from the per-exercise
    /// "reps in reserve" reads captured as each movement finished (1–5, lower =
    /// closer to failure). One read per rated exercise — all its working sets
    /// carry the same stamp — averaged into a single number the coach can weigh.
    /// Nil when no movement was rated.
    var repsInReserve: Int? {
        var perExercise: [UUID: Int] = [:]
        for set in sets where !set.isWarmup {
            guard let rir = set.repsInReserve, let exercise = set.exercise else { continue }
            perExercise[exercise.id] = rir
        }
        guard !perExercise.isEmpty else { return nil }
        let total = perExercise.values.reduce(0, +)
        return Int((Double(total) / Double(perExercise.count)).rounded())
    }

    var duration: TimeInterval {
        let end = endDate ?? sets.map(\.timestamp).max() ?? startDate
        return end.timeIntervalSince(startDate)
    }

    /// Rough active-energy estimate for the session, in kilocalories, so the
    /// Health sync and the history view always report the same number.
    /// Traditional strength training runs ~5 METs, and
    /// kcal = MET × bodyMass(kg) × hours. Body weight is passed in from Health
    /// (with the manual fallback); defaults to 155 lb when unknown.
    func estimatedActiveCalories(bodyWeightLbs: Double?) -> Double {
        let weightKg = (bodyWeightLbs ?? 155) * 0.453592
        let hours = max(duration, 60) / 3600
        return 5.0 * weightKg * hours
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

    /// `setsByExercise` collapsed into superset runs: each element is a run of
    /// consecutive movements that shared the same non-nil `supersetGroup` tag.
    /// Standalone movements come back as single-element runs, so history views
    /// can render supersets grouped while leaving everything else flat.
    var exerciseGroups: [[(exercise: Exercise, sets: [ExerciseSet])]] {
        let entries = setsByExercise
        return supersetRuns(Array(entries.indices)) { index in
            entries[index].sets.first?.supersetGroup
        }.map { run in run.map { entries[$0] } }
    }
}

/// Groups an ordered id list into runs of consecutive entries that share the
/// same non-nil superset tag. A `nil` tag (standalone) always breaks a run, so
/// unpaired items come back as singletons. Shared by the routine editor, the
/// live session manager, and history rendering.
func supersetRuns<ID: Hashable>(_ ids: [ID], tag: (ID) -> Int?) -> [[ID]] {
    var runs: [[ID]] = []
    for id in ids {
        if let last = runs.last?.last,
           let lastTag = tag(last), let thisTag = tag(id),
           lastTag == thisTag {
            runs[runs.count - 1].append(id)
        } else {
            runs.append([id])
        }
    }
    return runs
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

    /// The lifter's body weight (lbs) when this set was logged — stamped for
    /// bodyweight and assisted movements so effective load survives future
    /// weight changes. Nil for barbell-style sets or when weight was unknown.
    var bodyweightAtTime: Double? = nil

    /// Superset grouping tag stamped from the live session so history and
    /// "save as routine" remember which movements were paired. Nil (or 0) means
    /// this set's exercise was performed standalone. Movements sharing the same
    /// non-nil tag within a session were run as one superset.
    var supersetGroup: Int? = nil

    /// The lifter's "reps in reserve" read for this movement, captured mid-session
    /// once every set for the exercise is logged: how many more reps they could
    /// have done (1–5, lower = closer to failure). Stamped identically onto every
    /// working set of the exercise so the effort travels with the lift. Nil when
    /// unrated or for sets logged before this was asked, so the coach and the
    /// progression engine only weigh it when present.
    var repsInReserve: Int? = nil

    var exercise: Exercise?
    var session: WorkoutSession?

    init(
        weight: Double,
        reps: Int,
        durationSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        isWarmup: Bool = false,
        repWeights: [Double] = [],
        supersetGroup: Int? = nil,
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
        self.supersetGroup = supersetGroup
        self.isPR = false
    }

    /// The real load moved: body weight plus added weight for stamped sets
    /// (assistance is negative added weight), otherwise just the bar weight.
    var effectiveLoad: Double {
        (bodyweightAtTime ?? 0) + weight
    }

    /// Estimated 1RM using the parent exercise's configured formula (Epley by default).
    var estimatedOneRepMax: Double {
        (exercise?.formula ?? .epley).estimate(weight: effectiveLoad, reps: reps)
    }
}

// MARK: - Activity Model

enum SportType: String, Codable, CaseIterable, Identifiable {
    case basketball = "Basketball"
    case volleyball = "Volleyball"
    case soccer = "Soccer"
    case tennis = "Tennis"
    case pickleball = "Pickleball"
    case swimming = "Swimming"
    case cycling = "Cycling"
    case hiking = "Hiking"
    case yoga = "Yoga"
    case climbing = "Climbing"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .basketball: "basketball.fill"
        case .volleyball: "volleyball.fill"
        case .soccer: "soccerball"
        case .tennis: "tennisball.fill"
        case .pickleball: "figure.pickleball"
        case .swimming: "figure.pool.swim"
        case .cycling: "bicycle"
        case .hiking: "figure.hiking"
        case .yoga: "figure.yoga"
        case .climbing: "figure.climbing"
        case .other: "sportscourt.fill"
        }
    }
}

/// A non-lifting activity — pickup basketball, a volleyball night, a swim.
/// Time played converts to XP so cross-training feeds the level curve.
@Model
final class Activity {
    @Attribute(.unique) var id: UUID
    var sportRaw: String
    var date: Date
    var durationMinutes: Int
    var createdAt: Date

    init(sport: SportType, date: Date = Date(), durationMinutes: Int) {
        self.id = UUID()
        self.sportRaw = sport.rawValue
        self.date = date
        self.durationMinutes = durationMinutes
        self.createdAt = Date()
    }

    var sport: SportType { SportType(rawValue: sportRaw) ?? .other }
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

    /// Duration to reason with — the entered time, or a 20 min/mile estimate
    /// from the distance when the walk wasn't timed. Shared by the Health sync
    /// so the workout interval and its calorie math always agree.
    var effectiveDurationSeconds: Double {
        durationSeconds > 0 ? durationSeconds : max(distanceMiles * 20 * 60, 60)
    }

    /// Rough active-energy estimate for the walk, in kilocalories, matching the
    /// strength-session math. Brisk walking runs ~3.5 METs, and
    /// kcal = MET × bodyMass(kg) × hours. Body weight is passed in from Health
    /// (with the manual fallback); defaults to 155 lb when unknown.
    func estimatedActiveCalories(bodyWeightLbs: Double?) -> Double {
        let weightKg = (bodyWeightLbs ?? 155) * 0.453592
        let hours = effectiveDurationSeconds / 3600
        return 3.5 * weightKg * hours
    }
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

    /// Whether any slot carries a coached rep or load target — used to surface a
    /// hint that this routine remembers more than just its set counts.
    var hasPrescriptions: Bool {
        items.contains { $0.targetReps != nil || ($0.targetWeight ?? 0) > 0 }
    }
}

/// One slot in a `Routine`: an exercise plus how many working sets to aim for.
@Model
final class RoutineItem {
    @Attribute(.unique) var id: UUID
    var order: Int
    var targetSets: Int
    /// The single resolved rep target carried over from a coached plan. Nil for
    /// hand-built routines that only track a set count.
    var targetReps: Int?
    /// Suggested working weight in canonical pounds from a coached plan. Nil when
    /// unset or for bodyweight movements.
    var targetWeight: Double?

    /// Superset grouping tag. Consecutive routine items sharing the same non-nil
    /// value form one superset. Nil (or 0) means the slot is performed standalone.
    var supersetGroup: Int? = nil

    var exercise: Exercise?
    var routine: Routine?

    init(
        order: Int,
        targetSets: Int = 3,
        targetReps: Int? = nil,
        targetWeight: Double? = nil,
        supersetGroup: Int? = nil,
        exercise: Exercise? = nil
    ) {
        self.id = UUID()
        self.order = order
        self.targetSets = max(1, targetSets)
        self.targetReps = targetReps
        self.targetWeight = targetWeight
        self.supersetGroup = supersetGroup
        self.exercise = exercise
    }
}

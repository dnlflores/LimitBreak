import Foundation
import SwiftData
import SwiftUI

/// A record-shattering moment, surfaced to the UI as a full-screen celebration.
struct LimitBreakEvent: Identifiable, Equatable {
    let id = UUID()
    let exerciseName: String
    let recordType: String
    let newValue: Double
    let previousValue: Double
    let unit: String

    /// Delta improvement percentage over the previous ceiling (nil for first-ever records).
    var deltaPercent: Double? {
        guard previousValue > 0 else { return nil }
        return (newValue - previousValue) / previousValue * 100
    }
}

/// One set's worth of input when logging a workout retroactively.
struct PastSetEntry {
    var weight: Double
    var reps: Int
    var isWarmup: Bool = false
    var durationSeconds: Double? = nil
    var distanceMeters: Double? = nil
}

/// Owns the live workout session, the rest timer, and the LimitBreak PR engine.
@MainActor
@Observable
final class WorkoutManager {
    /// The app's single live instance; lets App Intents and the watch bridge
    /// reach the session without threading references through SwiftUI.
    static var shared: WorkoutManager?

    private let context: ModelContext

    var activeSession: WorkoutSession?
    /// Exercises added to the current session, in the order the user picked them
    /// (includes exercises with no sets logged yet).
    var sessionExercises: [Exercise] = []
    /// Planned working-set counts per exercise (routine targets or default 3) —
    /// drives ordered logging from the watch and Live Activity.
    var sessionTargets: [UUID: Int] = [:]
    /// Planned rep target per exercise, carried from a coached routine so the
    /// log card and one-tap logging open on the prescribed reps instead of a
    /// generic default. Empty for ad-hoc sessions and history-built routines.
    var sessionRepTargets: [UUID: Int] = [:]
    /// Planned working weight (canonical pounds) per exercise from a coached
    /// routine, prefilled the same way as `sessionRepTargets`.
    var sessionWeightTargets: [UUID: Double] = [:]
    /// Exercises the user skipped ahead of (watch "next exercise").
    var skippedExercises: Set<UUID> = []
    /// Superset grouping for the live session: exercise id → group tag. Movements
    /// sharing a non-nil tag are one superset. Populated from a routine and
    /// editable mid-session; each logged set is stamped with its exercise's tag.
    var sessionSupersets: [UUID: Int] = [:]

    var limitBreakEvent: LimitBreakEvent?

    /// A campaign milestone the lifter tapped "train this" on.
    ///
    /// The campaign tab can't push a view onto the Train tab's navigation stack,
    /// and tab selection lives in `RootTabView` — so the intent is published here,
    /// where both tabs already look. `RootTabView` switches tabs on it and the
    /// session launcher reads it as a banner and a pre-selected focus. Cleared
    /// once the lifter starts a session or dismisses the banner.
    var campaignIntent: CampaignTrainingIntent?

    /// Test seam for body weight; production reads Health (with manual fallback).
    var bodyWeightOverride: Double?

    private var currentBodyWeight: Double? {
        bodyWeightOverride ?? HealthKitManager.shared.currentBodyWeightLbs
    }

    /// Bodyweight and assisted movements get the lifter's weight stamped on
    /// each set so effective load is preserved forever.
    private func stampBodyweightIfNeeded(_ set: ExerciseSet, exercise: Exercise) {
        guard exercise.trackingType == .bodyweightAndReps || exercise.isAssisted else { return }
        set.bodyweightAtTime = currentBodyWeight
    }

    // Rest timer
    var restRemaining: TimeInterval = 0
    var restTotal: TimeInterval = 0
    private var restTimer: Timer?

    var isResting: Bool { restRemaining > 0 }

    init(context: ModelContext) {
        self.context = context
        WorkoutManager.shared = self
    }

    // MARK: - Session lifecycle

    func startSession(
        named name: String,
        exercises: [Exercise] = [],
        targets: [UUID: Int]? = nil,
        repTargets: [UUID: Int] = [:],
        weightTargets: [UUID: Double] = [:],
        supersets: [UUID: Int] = [:],
        withPartner: Bool = false,
        routineID: UUID? = nil
    ) {
        let session = WorkoutSession(
            name: name.isEmpty ? "Training Session" : name,
            trainedWithPartner: withPartner
        )
        session.startedFromRoutineID = routineID
        context.insert(session)
        activeSession = session
        sessionExercises = exercises
        sessionTargets = targets ?? Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, 3) })
        sessionRepTargets = repTargets
        sessionWeightTargets = weightTargets
        sessionSupersets = supersets
        skippedExercises = []
        try? context.save()
        Haptics.shared.success()
        SessionSync.shared.broadcast(from: self)
    }

    /// Closes out the active session. Effort is captured per exercise during the
    /// session (see `setRepsInReserve(_:for:)`), so ending is just a matter of
    /// stamping the end date and saving.
    func endSession() {
        activeSession?.endDate = Date()
        try? context.save()
        if let session = activeSession {
            HealthKitManager.shared.syncIfEnabled(session: session)
        }
        activeSession = nil
        sessionExercises = []
        sessionTargets = [:]
        sessionRepTargets = [:]
        sessionWeightTargets = [:]
        sessionSupersets = [:]
        skippedExercises = []
        stopRest()
        SessionSync.shared.broadcast(from: self)
    }

    /// Discards the active session entirely — deletes it and any logged sets
    /// (which cascade away) without saving to history or syncing to HealthKit.
    /// For sessions started by mistake.
    func cancelSession() {
        if let session = activeSession {
            let affected = Set(session.sets.compactMap(\.exercise))
            context.delete(session)
            try? context.save()
            recomputePRs(for: affected)
            try? context.save()
        }
        activeSession = nil
        sessionExercises = []
        sessionTargets = [:]
        sessionRepTargets = [:]
        sessionWeightTargets = [:]
        sessionSupersets = [:]
        skippedExercises = []
        stopRest()
        Haptics.shared.logSet()
        SessionSync.shared.broadcast(from: self)
    }

    /// Whether the live session is being trained with a partner.
    var isTrainingWithPartner: Bool { activeSession?.trainedWithPartner ?? false }

    /// Flips the live session's partner flag — for when a partner turns up (or
    /// bails) after the session already started.
    func setTrainingWithPartner(_ withPartner: Bool) {
        guard let session = activeSession, session.trainedWithPartner != withPartner else { return }
        session.trainedWithPartner = withPartner
        try? context.save()
        Haptics.shared.tick()
    }

    func addExercise(_ exercise: Exercise) {
        guard !sessionExercises.contains(where: { $0.id == exercise.id }) else { return }
        sessionExercises.append(exercise)
        if sessionTargets[exercise.id] == nil { sessionTargets[exercise.id] = 3 }
        SessionSync.shared.broadcast(from: self)
    }

    // MARK: - Ordered logging (watch & Live Activity)

    /// Planned working sets for an exercise, never less than what's logged.
    func targetSets(for exercise: Exercise) -> Int {
        max(sessionTargets[exercise.id] ?? 3, sets(for: exercise).count)
    }

    /// The exercise LOG SET works through next: first in session order that
    /// isn't skipped and still has planned sets remaining.
    var currentExercise: Exercise? {
        sessionExercises.first {
            !skippedExercises.contains($0.id) && sets(for: $0).count < targetSets(for: $0)
        }
    }

    /// One-tap logging: checks off the next planned set in exercise order,
    /// quick-filling values from this session (or history, or defaults).
    @discardableResult
    func logNextSetInOrder() -> LimitBreakEvent? {
        guard activeSession != nil, let exercise = currentExercise else { return nil }
        let template = lastSet(for: exercise)
            ?? exercise.sets.max(by: { $0.timestamp < $1.timestamp })
        // A coached routine's prescription wins; failing that, the progression
        // target advances on last session (add a rep, or cash in for load);
        // history and the generic default are the last resorts.
        let target = progressionTarget(for: exercise)
        let reps = plannedReps(for: exercise) ?? target?.targetReps ?? template?.reps ?? 8
        let plannedLoad = plannedWeight(for: exercise) ?? target?.targetWeightPounds

        switch exercise.trackingType {
        case .weightAndReps:
            return logSet(exercise: exercise, weight: plannedLoad ?? template?.weight ?? 45, reps: reps)
        case .bodyweightAndReps, .customMetric:
            return logSet(exercise: exercise, weight: plannedLoad ?? template?.weight ?? 0, reps: reps)
        case .durationAndReps:
            return logSet(exercise: exercise, weight: 0, reps: reps,
                          durationSeconds: template?.durationSeconds ?? 30)
        case .timeAndDistance:
            return logSet(exercise: exercise, weight: 0, reps: 1,
                          durationSeconds: template?.durationSeconds ?? 300,
                          distanceMeters: template?.distanceMeters ?? 1600)
        }
    }

    /// Skips what's left of the current exercise and moves to the next one.
    func advanceToNextExercise() {
        guard let exercise = currentExercise else { return }
        skippedExercises.insert(exercise.id)
        Haptics.shared.tick()
        SessionSync.shared.broadcast(from: self)
    }

    /// Removes an exercise from the active session, deleting any sets already
    /// logged for it here and rebuilding records so no ceiling is stranded.
    func removeExercise(_ exercise: Exercise) {
        sessionExercises.removeAll { $0.id == exercise.id }
        let doomed = sets(for: exercise)
        guard !doomed.isEmpty else {
            Haptics.shared.logSet()
            return
        }
        for set in doomed {
            context.delete(set)
        }
        try? context.save()
        recomputePRs(for: [exercise])
        try? context.save()
        Haptics.shared.logSet()
        SessionSync.shared.broadcast(from: self)
    }

    /// Rewrites the session's exercise order (drag-to-reorder in the log). Only
    /// the running order changes — logged sets, targets and skips all key off
    /// the exercise, so they follow their movement to its new slot.
    func reorderExercises(to ordered: [Exercise]) {
        guard ordered.count == sessionExercises.count else { return }
        sessionExercises = ordered
        SessionSync.shared.broadcast(from: self)
    }

    /// Swaps one exercise slot for another (machine taken, equipment change).
    /// Sets already logged on the old movement stay in the session history.
    func replaceExercise(_ old: Exercise, with new: Exercise) {
        guard let index = sessionExercises.firstIndex(where: { $0.id == old.id }) else { return }
        if sessionExercises.contains(where: { $0.id == new.id }) {
            sessionExercises.remove(at: index)
        } else {
            sessionExercises[index] = new
            sessionTargets[new.id] = sessionTargets[old.id] ?? 3
        }
        sessionTargets[old.id] = nil
        Haptics.shared.logSet()
        SessionSync.shared.broadcast(from: self)
    }

    /// Switches a movement's display/entry unit (lb/kg). Stored weights are
    /// canonical pounds, so this only changes how loads are typed and shown —
    /// no history is rewritten.
    func setWeightUnit(_ unit: WeightUnit, for exercise: Exercise) {
        guard exercise.weightUnit != unit else { return }
        exercise.weightUnit = unit
        try? context.save()
        SessionSync.shared.broadcast(from: self)
    }

    // MARK: - Supersets

    /// The live superset tag for an exercise, or nil when it's standalone.
    func supersetTag(for exercise: Exercise) -> Int? {
        sessionSupersets[exercise.id]
    }

    /// The other movements sharing an exercise's superset (excludes itself).
    /// Empty when the exercise is standalone.
    func supersetPartners(for exercise: Exercise) -> [Exercise] {
        guard let tag = sessionSupersets[exercise.id] else { return [] }
        return sessionExercises.filter { $0.id != exercise.id && sessionSupersets[$0.id] == tag }
    }

    /// The session's exercises collapsed into superset runs, in logging order.
    /// Standalone movements come back as single-element runs.
    func sessionSupersetRuns() -> [[Exercise]] {
        let byID = Dictionary(uniqueKeysWithValues: sessionExercises.map { ($0.id, $0) })
        return supersetRuns(sessionExercises.map(\.id)) { sessionSupersets[$0] }
            .map { run in run.compactMap { byID[$0] } }
    }

    /// The one-based display label ("A", "B", …) for a superset run, so the UI can
    /// badge grouped movements. Nil for standalone exercises.
    func supersetLabel(for exercise: Exercise) -> String? {
        guard sessionSupersets[exercise.id] != nil else { return nil }
        let runs = sessionSupersetRuns().filter { $0.count > 1 }
        guard let index = runs.firstIndex(where: { $0.contains(where: { $0.id == exercise.id }) }) else {
            return nil
        }
        return String(UnicodeScalar(UInt8(65 + min(index, 25))))
    }

    /// Groups a set of movements into one superset, tagging them with a fresh
    /// group id and pulling them adjacent (keeping their relative order) right
    /// after the earliest member, so a superset always renders as a contiguous run.
    func groupAsSuperset(_ exercises: [Exercise]) {
        let ids = Set(exercises.map(\.id))
        let members = sessionExercises.filter { ids.contains($0.id) }
        guard members.count > 1 else { return }
        let tag = (sessionSupersets.values.max() ?? 0) + 1
        for member in members { sessionSupersets[member.id] = tag }

        // Rebuild order: keep everything, but relocate later members up next to
        // the first member so the group is contiguous.
        guard let anchorIndex = sessionExercises.firstIndex(where: { ids.contains($0.id) }) else { return }
        var reordered = sessionExercises.filter { !ids.contains($0.id) }
        let insertAt = min(anchorIndex, reordered.count)
        reordered.insert(contentsOf: members, at: insertAt)
        sessionExercises = reordered
        Haptics.shared.success()
        SessionSync.shared.broadcast(from: self)
    }

    /// Whether an exercise has a following movement in session order it can be
    /// paired with (and isn't already grouped with it).
    func canGroupWithNextInSession(_ exercise: Exercise) -> Bool {
        guard let i = sessionExercises.firstIndex(where: { $0.id == exercise.id }),
              i < sessionExercises.count - 1 else { return false }
        let next = sessionExercises[i + 1]
        let tag = sessionSupersets[exercise.id]
        return tag == nil || sessionSupersets[next.id] != tag
    }

    /// Supersets a movement with the one right after it in session order, joining
    /// an existing group when either already has one.
    func groupWithNextInSession(_ exercise: Exercise) {
        guard let i = sessionExercises.firstIndex(where: { $0.id == exercise.id }),
              i < sessionExercises.count - 1 else { return }
        let next = sessionExercises[i + 1]
        if let tag = sessionSupersets[exercise.id] ?? sessionSupersets[next.id] {
            sessionSupersets[exercise.id] = tag
            sessionSupersets[next.id] = tag
            Haptics.shared.success()
            SessionSync.shared.broadcast(from: self)
        } else {
            groupAsSuperset([exercise, next])
        }
    }

    /// Removes an exercise from its superset. If only one movement is left in the
    /// group, that one becomes standalone too.
    func ungroupSuperset(_ exercise: Exercise) {
        guard let tag = sessionSupersets[exercise.id] else { return }
        sessionSupersets[exercise.id] = nil
        let remaining = sessionExercises.filter { sessionSupersets[$0.id] == tag }
        if remaining.count < 2 {
            for member in remaining { sessionSupersets[member.id] = nil }
        }
        Haptics.shared.tick()
        SessionSync.shared.broadcast(from: self)
    }

    /// Starts the rest timer after a logged set — unless the movement is in a
    /// superset and a partner still owes a set this round, in which case the pair
    /// is meant to run back-to-back with no rest between. When rest does fire for
    /// a superset, it uses the longest rest among the group's members.
    private func startRestAfterLogging(_ exercise: Exercise, isWarmup: Bool) {
        guard !isWarmup else { return }
        let partners = supersetPartners(for: exercise)
        if !partners.isEmpty {
            let mySets = sets(for: exercise).filter { !$0.isWarmup }.count
            let partnerIsUp = partners.contains { partner in
                !skippedExercises.contains(partner.id) &&
                sets(for: partner).filter { !$0.isWarmup }.count < mySets
            }
            if partnerIsUp { return }
            let rest = ([exercise] + partners).map(\.defaultRestSeconds).max() ?? exercise.defaultRestSeconds
            if rest > 0 { startRest(seconds: TimeInterval(rest)) }
            return
        }
        if exercise.defaultRestSeconds > 0 {
            startRest(seconds: TimeInterval(exercise.defaultRestSeconds))
        }
    }

    /// Reverts an accidentally logged set: deletes it and replays the exercise's
    /// history so any PR it minted is withdrawn.
    func undoSet(_ set: ExerciseSet) {
        guard let exercise = set.exercise else {
            context.delete(set)
            try? context.save()
            return
        }
        context.delete(set)
        try? context.save()
        recomputePRs(for: [exercise])
        try? context.save()
        Haptics.shared.tick()
        SessionSync.shared.broadcast(from: self)
    }

    // MARK: - Set logging & LimitBreak engine

    @discardableResult
    func logSet(
        exercise: Exercise,
        weight: Double,
        reps: Int,
        durationSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        isWarmup: Bool = false,
        repWeights: [Double] = []
    ) -> LimitBreakEvent? {
        guard let session = activeSession else { return nil }

        let set = ExerciseSet(
            weight: weight,
            reps: reps,
            durationSeconds: durationSeconds,
            distanceMeters: distanceMeters,
            isWarmup: isWarmup,
            repWeights: repWeights,
            supersetGroup: sessionSupersets[exercise.id]
        )
        set.exercise = exercise
        set.session = session
        stampBodyweightIfNeeded(set, exercise: exercise)
        context.insert(set)

        let event = registerPRIfNeeded(for: set, exercise: exercise, celebrating: true)

        try? context.save()

        if let event {
            limitBreakEvent = event
            Haptics.shared.limitBreakBurst()
        } else {
            Haptics.shared.logSet()
        }

        startRestAfterLogging(exercise, isWarmup: isWarmup)
        SessionSync.shared.broadcast(from: self)
        return event
    }

    /// Logs a complete workout that happened in the past. Sets are timestamped
    /// starting at `date`; records that beat the all-time ceiling are registered
    /// quietly (no LimitBreak celebration for old news).
    func logPastSession(
        name: String,
        date: Date,
        withPartner: Bool = false,
        entries: [(exercise: Exercise, supersetGroup: Int?, sets: [PastSetEntry])]
    ) {
        let session = WorkoutSession(
            name: name.isEmpty ? "Training Session" : name,
            startDate: date,
            trainedWithPartner: withPartner
        )
        context.insert(session)

        var offset: TimeInterval = 0
        for entry in entries {
            for draft in entry.sets {
                let set = ExerciseSet(
                    weight: draft.weight,
                    reps: draft.reps,
                    durationSeconds: draft.durationSeconds,
                    distanceMeters: draft.distanceMeters,
                    isWarmup: draft.isWarmup,
                    supersetGroup: entry.supersetGroup,
                    timestamp: date.addingTimeInterval(offset)
                )
                set.exercise = entry.exercise
                set.session = session
                stampBodyweightIfNeeded(set, exercise: entry.exercise)
                context.insert(set)
                registerPRIfNeeded(for: set, exercise: entry.exercise, celebrating: false)
                offset += 150 // ~2.5 min per set keeps timestamps ordered and plausible
            }
        }
        session.endDate = date.addingTimeInterval(max(offset, 60))

        try? context.save()
        HealthKitManager.shared.syncIfEnabled(session: session)
        Haptics.shared.success()
    }

    // MARK: - Editing & deleting past sessions

    /// Rewrites an existing session in place: its name, date, and full set list.
    /// The old sets are cleared and rebuilt from `entries`, then PR records are
    /// recomputed for every affected exercise so ceilings stay honest.
    func updateSession(
        _ session: WorkoutSession,
        name: String,
        date: Date,
        withPartner: Bool,
        entries: [(exercise: Exercise, supersetGroup: Int?, sets: [PastSetEntry])]
    ) {
        var affected = Set(session.sets.compactMap(\.exercise))

        for set in session.sets {
            context.delete(set)
        }
        try? context.save()

        session.name = name.isEmpty ? "Training Session" : name
        session.startDate = date
        session.trainedWithPartner = withPartner

        var offset: TimeInterval = 0
        for entry in entries {
            affected.insert(entry.exercise)
            for draft in entry.sets {
                let set = ExerciseSet(
                    weight: draft.weight,
                    reps: draft.reps,
                    durationSeconds: draft.durationSeconds,
                    distanceMeters: draft.distanceMeters,
                    isWarmup: draft.isWarmup,
                    supersetGroup: entry.supersetGroup,
                    timestamp: date.addingTimeInterval(offset)
                )
                set.exercise = entry.exercise
                set.session = session
                stampBodyweightIfNeeded(set, exercise: entry.exercise)
                context.insert(set)
                offset += 150
            }
        }
        session.endDate = date.addingTimeInterval(max(offset, 60))
        try? context.save()

        recomputePRs(for: affected)
        try? context.save()

        HealthKitManager.shared.syncIfEnabled(session: session)
        Haptics.shared.success()
    }

    /// Deletes a session (its sets cascade away), then rebuilds PR records for
    /// every exercise it touched so no ceiling is stranded above the new best.
    func deleteSession(_ session: WorkoutSession) {
        let affected = Set(session.sets.compactMap(\.exercise))
        context.delete(session)
        try? context.save()

        recomputePRs(for: affected)
        try? context.save()

        Haptics.shared.success()
    }

    /// Replays each exercise's full set history chronologically and rebuilds its
    /// PRRecord list, flagging exactly the sets that were record-setting at the
    /// time. Run after any retroactive edit or delete.
    private func recomputePRs(for exercises: Set<Exercise>) {
        for exercise in exercises {
            for record in exercise.prRecords {
                context.delete(record)
            }
            var ceilings: [String: Double] = [:]
            for set in exercise.sets.sorted(by: { $0.timestamp < $1.timestamp }) {
                set.isPR = false
                guard !set.isWarmup,
                      let candidate = prCandidate(for: set, exercise: exercise) else { continue }
                guard candidate.value > (ceilings[candidate.type] ?? 0) else { continue }
                set.isPR = true
                ceilings[candidate.type] = candidate.value
                let record = PRRecord(
                    recordType: candidate.type,
                    numericValue: candidate.value,
                    repsAchieved: set.reps,
                    exercise: exercise,
                    dateAchieved: set.timestamp
                )
                context.insert(record)
            }
        }
    }

    /// Runs the LimitBreak check for a set; returns an event only when celebrating.
    @discardableResult
    private func registerPRIfNeeded(
        for set: ExerciseSet,
        exercise: Exercise,
        celebrating: Bool
    ) -> LimitBreakEvent? {
        guard !set.isWarmup, let candidate = prCandidate(for: set, exercise: exercise) else { return nil }
        let ceiling = exercise.ceiling(for: candidate.type)
        guard candidate.value > ceiling else { return nil }

        set.isPR = true
        let record = PRRecord(
            recordType: candidate.type,
            numericValue: candidate.value,
            repsAchieved: set.reps,
            exercise: exercise,
            dateAchieved: set.timestamp
        )
        context.insert(record)

        guard celebrating else { return nil }
        // Records are stored canonically in pounds; show the celebration in the
        // movement's own unit when it's a weight record.
        let isPoundsRecord = candidate.unit == "lbs" || candidate.unit == "lbs added"
        let convert = isPoundsRecord && exercise.usesWeightUnit
        let displayUnit: String
        if convert {
            displayUnit = candidate.unit == "lbs added"
                ? "\(exercise.weightUnit.abbreviation) added"
                : exercise.weightUnit.abbreviation
        } else {
            displayUnit = candidate.unit
        }
        return LimitBreakEvent(
            exerciseName: exercise.name,
            recordType: candidate.type,
            newValue: convert ? exercise.weightUnit.fromPounds(candidate.value) : candidate.value,
            previousValue: convert ? exercise.weightUnit.fromPounds(ceiling) : ceiling,
            unit: displayUnit
        )
    }

    /// Maps a set to the record dimension its exercise competes on.
    private func prCandidate(for set: ExerciseSet, exercise: Exercise) -> (type: String, value: Double, unit: String)? {
        switch exercise.trackingType {
        case .weightAndReps:
            let e1rm = set.estimatedOneRepMax
            return e1rm > 0 ? ("1RM", e1rm, "lbs") : nil
        case .bodyweightAndReps:
            // With a stamped body weight the true moved load is known, so the
            // record is a real 1RM (assistance already nets out of the load).
            if set.bodyweightAtTime != nil {
                let e1rm = set.estimatedOneRepMax
                return e1rm > 0 ? ("1RM", e1rm, "lbs") : nil
            }
            if set.weight > 0 {
                return ("1RM", set.estimatedOneRepMax, "lbs added")
            }
            return set.reps > 0 ? ("Max Reps", Double(set.reps), "reps") : nil
        case .durationAndReps:
            guard let duration = set.durationSeconds, duration > 0 else { return nil }
            return ("Max Duration", duration, "sec")
        case .timeAndDistance:
            guard let distance = set.distanceMeters, distance > 0 else { return nil }
            return ("Max Distance", distance, "m")
        case .customMetric:
            return set.weight > 0 ? ("Max Value", set.weight, exercise.customMetricUnit ?? "") : nil
        }
    }

    /// Last non-warmup set for an exercise in the active session — powers Quick-Fill.
    func lastSet(for exercise: Exercise) -> ExerciseSet? {
        activeSession?.sets
            .filter { $0.exercise?.id == exercise.id }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    func sets(for exercise: Exercise) -> [ExerciseSet] {
        (activeSession?.sets ?? [])
            .filter { $0.exercise?.id == exercise.id }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Reps in reserve (per-exercise effort)

    /// Records how many more reps the lifter felt they had on a movement, asked
    /// once its sets are all logged (1–5, lower = closer to failure). Stamped onto
    /// every working set of the exercise so the effort travels with the lift into
    /// history, the coach's prompt, and the progression engine. Pass nil to clear.
    func setRepsInReserve(_ value: Int?, for exercise: Exercise) {
        guard activeSession != nil else { return }
        for set in sets(for: exercise) where !set.isWarmup {
            set.repsInReserve = value
        }
        try? context.save()
        Haptics.shared.tick()
        SessionSync.shared.broadcast(from: self)
    }

    /// The reps-in-reserve read already recorded for a movement this session, if any.
    func repsInReserve(for exercise: Exercise) -> Int? {
        sets(for: exercise).first { !$0.isWarmup && $0.repsInReserve != nil }?.repsInReserve
    }

    // MARK: - Rest timer

    /// Wall-clock end of the current rest period, for countdown rendering on
    /// the watch and in the Live Activity.
    var restEndsAt: Date? {
        isResting ? Date().addingTimeInterval(restRemaining) : nil
    }

    func startRest(seconds: TimeInterval) {
        restTimer?.invalidate()
        restTotal = seconds
        restRemaining = seconds
        restTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restRemaining -= 1
                if self.restRemaining <= 0 {
                    self.stopRest()
                    Haptics.shared.success()
                }
            }
        }
    }

    func addRest(seconds: TimeInterval) {
        guard isResting else { return }
        restRemaining += seconds
        restTotal = max(restTotal, restRemaining)
    }

    func stopRest() {
        let wasResting = isResting
        restTimer?.invalidate()
        restTimer = nil
        restRemaining = 0
        restTotal = 0
        if wasResting { SessionSync.shared.broadcast(from: self) }
    }

    // MARK: - Routines (saved curations)

    /// One ordered slot handed to `createRoutine`/`updateRoutine`: an exercise,
    /// its target set count, and — when it came from a coached plan — the
    /// resolved rep target and suggested working weight.
    typealias RoutineDraftItem = (
        exercise: Exercise,
        targetSets: Int,
        targetReps: Int?,
        targetWeight: Double?,
        supersetGroup: Int?
    )

    /// Creates and persists a new routine from an ordered list of draft items.
    @discardableResult
    func createRoutine(
        name: String,
        notes: String? = nil,
        isAIGenerated: Bool = false,
        focusLabel: String? = nil,
        items: [RoutineDraftItem]
    ) -> Routine {
        let routine = Routine(
            name: name.isEmpty ? "Routine" : name,
            notes: notes?.isEmpty == true ? nil : notes,
            isAIGenerated: isAIGenerated,
            focusLabel: focusLabel
        )
        context.insert(routine)
        applyItems(items, to: routine)
        try? context.save()
        Haptics.shared.success()
        return routine
    }

    /// Rewrites a routine in place: its name, notes, and full ordered item list.
    func updateRoutine(
        _ routine: Routine,
        name: String,
        notes: String? = nil,
        items: [RoutineDraftItem]
    ) {
        for item in routine.items {
            context.delete(item)
        }
        try? context.save()

        routine.name = name.isEmpty ? "Routine" : name
        routine.notes = notes?.isEmpty == true ? nil : notes
        applyItems(items, to: routine)
        try? context.save()
        Haptics.shared.success()
    }

    /// Inserts ordered `RoutineItem`s for the given draft items and links them.
    private func applyItems(
        _ items: [RoutineDraftItem],
        to routine: Routine
    ) {
        for (index, entry) in items.enumerated() {
            let item = RoutineItem(
                order: index,
                targetSets: entry.targetSets,
                targetReps: entry.targetReps,
                targetWeight: entry.targetWeight,
                supersetGroup: entry.supersetGroup,
                exercise: entry.exercise
            )
            item.routine = routine
            context.insert(item)
        }
    }

    func deleteRoutine(_ routine: Routine) {
        context.delete(routine)
        try? context.save()
        Haptics.shared.logSet()
    }

    /// Builds a routine from a completed session: one slot per exercise, with
    /// the target set count taken from how many working sets were logged.
    @discardableResult
    func saveRoutine(from session: WorkoutSession) -> Routine {
        let items = session.setsByExercise.map { group -> RoutineDraftItem in
            let tag = group.sets.first?.supersetGroup
            return (group.exercise, max(1, group.sets.filter { !$0.isWarmup }.count), nil, nil, tag)
        }
        return createRoutine(name: session.name, items: items)
    }

    /// Starts a live session pre-loaded with a routine's exercises, in order,
    /// carrying each slot's target sets — plus any coached rep/weight targets —
    /// into the session plan so logging opens on the prescribed numbers.
    func startSession(from routine: Routine, withPartner: Bool = false) {
        var targets: [UUID: Int] = [:]
        var repTargets: [UUID: Int] = [:]
        var weightTargets: [UUID: Double] = [:]
        var supersets: [UUID: Int] = [:]
        for item in routine.orderedItems {
            if let exercise = item.exercise {
                targets[exercise.id] = max(1, item.targetSets)
                if let reps = item.targetReps { repTargets[exercise.id] = reps }
                if let weight = item.targetWeight, weight > 0 { weightTargets[exercise.id] = weight }
                if let tag = item.supersetGroup, tag != 0 { supersets[exercise.id] = tag }
            }
        }
        startSession(
            named: routine.name,
            exercises: routine.exercises,
            targets: targets,
            repTargets: repTargets,
            weightTargets: weightTargets,
            supersets: supersets,
            withPartner: withPartner,
            routineID: routine.id
        )
    }

    /// The coached rep target for an exercise in the live session, if the
    /// routine that started it prescribed one.
    func plannedReps(for exercise: Exercise) -> Int? {
        sessionRepTargets[exercise.id]
    }

    /// The coached working weight (canonical pounds) for an exercise in the
    /// live session, if the routine that started it prescribed one.
    func plannedWeight(for exercise: Exercise) -> Double? {
        sessionWeightTargets[exercise.id]
    }

    // MARK: - Progressive overload

    /// The next-session progression target for a movement, derived from its own
    /// history and the lifter's goal (double progression + heavy/volume
    /// undulation). Nil for movements progression doesn't model, or when there's
    /// nothing to suggest. Drives the log card's target banner, its prefill, and
    /// ordered one-tap logging.
    func progressionTarget(for exercise: Exercise) -> ProgressionTarget? {
        let goal = TrainingProfile.current(in: context).goal
        return ProgressionEngine.nextTarget(
            for: exercise,
            goal: goal,
            withPartner: isTrainingWithPartner
        )
    }
}

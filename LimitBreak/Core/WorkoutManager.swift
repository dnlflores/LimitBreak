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
    private let context: ModelContext

    var activeSession: WorkoutSession?
    /// Exercises added to the current session, in the order the user picked them
    /// (includes exercises with no sets logged yet).
    var sessionExercises: [Exercise] = []

    var limitBreakEvent: LimitBreakEvent?

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
    }

    // MARK: - Session lifecycle

    func startSession(named name: String, exercises: [Exercise] = []) {
        let session = WorkoutSession(name: name.isEmpty ? "Training Session" : name)
        context.insert(session)
        activeSession = session
        sessionExercises = exercises
        try? context.save()
        Haptics.shared.success()
    }

    func endSession() {
        activeSession?.endDate = Date()
        try? context.save()
        if let session = activeSession {
            HealthKitManager.shared.syncIfEnabled(session: session)
        }
        activeSession = nil
        sessionExercises = []
        stopRest()
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
        stopRest()
        Haptics.shared.logSet()
    }

    func addExercise(_ exercise: Exercise) {
        guard !sessionExercises.contains(where: { $0.id == exercise.id }) else { return }
        sessionExercises.append(exercise)
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
    }

    /// Swaps one exercise slot for another (machine taken, equipment change).
    /// Sets already logged on the old movement stay in the session history.
    func replaceExercise(_ old: Exercise, with new: Exercise) {
        guard let index = sessionExercises.firstIndex(where: { $0.id == old.id }) else { return }
        if sessionExercises.contains(where: { $0.id == new.id }) {
            sessionExercises.remove(at: index)
        } else {
            sessionExercises[index] = new
        }
        Haptics.shared.logSet()
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
            repWeights: repWeights
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

        if exercise.defaultRestSeconds > 0 {
            startRest(seconds: TimeInterval(exercise.defaultRestSeconds))
        }
        return event
    }

    /// Logs a complete workout that happened in the past. Sets are timestamped
    /// starting at `date`; records that beat the all-time ceiling are registered
    /// quietly (no LimitBreak celebration for old news).
    func logPastSession(
        name: String,
        date: Date,
        entries: [(exercise: Exercise, sets: [PastSetEntry])]
    ) {
        let session = WorkoutSession(
            name: name.isEmpty ? "Training Session" : name,
            startDate: date
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
        entries: [(exercise: Exercise, sets: [PastSetEntry])]
    ) {
        var affected = Set(session.sets.compactMap(\.exercise))

        for set in session.sets {
            context.delete(set)
        }
        try? context.save()

        session.name = name.isEmpty ? "Training Session" : name
        session.startDate = date

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
        return LimitBreakEvent(
            exerciseName: exercise.name,
            recordType: candidate.type,
            newValue: candidate.value,
            previousValue: ceiling,
            unit: candidate.unit
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

    // MARK: - Rest timer

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
        restTimer?.invalidate()
        restTimer = nil
        restRemaining = 0
        restTotal = 0
    }

    // MARK: - Routines (saved curations)

    /// Creates and persists a new routine from an ordered list of
    /// (exercise, targetSets) pairs.
    @discardableResult
    func createRoutine(
        name: String,
        notes: String? = nil,
        isAIGenerated: Bool = false,
        focusLabel: String? = nil,
        items: [(exercise: Exercise, targetSets: Int)]
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
        items: [(exercise: Exercise, targetSets: Int)]
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

    /// Inserts ordered `RoutineItem`s for the given pairs and links them.
    private func applyItems(
        _ items: [(exercise: Exercise, targetSets: Int)],
        to routine: Routine
    ) {
        for (index, entry) in items.enumerated() {
            let item = RoutineItem(order: index, targetSets: entry.targetSets, exercise: entry.exercise)
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
        let items = session.setsByExercise.map { group in
            (exercise: group.exercise, targetSets: max(1, group.sets.filter { !$0.isWarmup }.count))
        }
        return createRoutine(name: session.name, items: items)
    }

    /// Starts a live session pre-loaded with a routine's exercises, in order.
    func startSession(from routine: Routine) {
        startSession(named: routine.name, exercises: routine.exercises)
    }
}

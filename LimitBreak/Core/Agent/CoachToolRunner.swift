import Foundation
import SwiftData

/// Executes the coach's tool calls against the lifter's real data.
///
/// Two rules shape this whole file:
///
/// 1. **Every mutation goes through `WorkoutManager`.** Nothing here writes to
///    SwiftData directly when the manager already owns the operation, so an
///    agent-made change and a hand-made one are literally the same code path —
///    including the PR recomputation, plan timestamps, and haptics that hang
///    off it. There is no second write path to keep in sync.
///
/// 2. **A write is staged, never performed.** Mutating tools resolve and
///    validate everything up front, then hand a `PendingChange` to the lifter.
///    The mutation itself lives in a closure that only runs on approval, so a
///    declined change leaves nothing to undo — and a call that can't be
///    validated fails before the lifter is ever asked about it.
@MainActor
final class CoachToolRunner {

    /// A validated, not-yet-applied mutation awaiting the lifter's approval.
    struct PendingChange: Identifiable {
        let id = UUID()
        let toolName: String
        /// One line naming the change, e.g. `Create routine "Push Day A"`.
        let title: String
        /// What it will do, one bullet per line.
        let detail: [String]
        /// Whether it removes something. Drives the card's colour and wording;
        /// the approval requirement is identical either way.
        var isDestructive: Bool = false
        /// Performs the change and returns the confirmation the model reads.
        let apply: @MainActor () -> String
    }

    /// A tool call that can't proceed. Every message is written for the model:
    /// it says what was wrong and what to do instead, because this text lands
    /// in a `tool_result` and a well-aimed correction usually rescues the turn.
    enum ToolFailure: LocalizedError {
        case unknownTool(String)
        case missingArgument(String, tool: String)
        case noSuchExercise(String, suggestions: [String])
        case noSuchRoutine(String, available: [String])
        case emptyExerciseList
        case invalidValue(String, argument: String)
        case noWeeklyPlan
        case noActiveSession

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "There is no tool named \"\(name)\"."
            case .missingArgument(let argument, let tool):
                return "\(tool) needs the \"\(argument)\" argument. Call it again with that argument set."
            case .noSuchExercise(let name, let suggestions):
                let hint = suggestions.isEmpty
                    ? "Call search_exercises to find what the library actually has."
                    : "The closest matches are: \(suggestions.joined(separator: ", ")). "
                        + "Use one of those exactly, or call create_exercise to add the movement first."
                return "There is no movement named \"\(name)\" in the library. \(hint)"
            case .noSuchRoutine(let name, let available):
                let hint = available.isEmpty
                    ? "The lifter has no saved routines yet."
                    : "Saved routines: \(available.joined(separator: ", "))."
                return "There is no routine named \"\(name)\". \(hint)"
            case .emptyExerciseList:
                return "The exercises list was empty. A routine needs at least one movement."
            case .invalidValue(let value, let argument):
                return "\"\(value)\" isn't a valid \(argument). Check the allowed values and call again."
            case .noWeeklyPlan:
                return "The lifter hasn't built a training week yet. Use set_plan_day to create one."
            case .noActiveSession:
                return "There is no workout in progress right now."
            }
        }
    }

    private let context: ModelContext
    private let workout: WorkoutManager
    /// Asks the lifter to approve a staged change; `true` means apply it.
    /// Injected rather than owned so the agent controls the presentation and
    /// this stays testable without a UI.
    private let confirm: @MainActor (PendingChange) async -> Bool

    init(
        context: ModelContext,
        workout: WorkoutManager,
        confirm: @escaping @MainActor (PendingChange) async -> Bool
    ) {
        self.context = context
        self.workout = workout
        self.confirm = confirm
    }

    // MARK: - Dispatch

    /// Runs one call and produces the result the model reads next.
    ///
    /// This never throws: a failure is a `tool_result` with `isError`, which is
    /// what lets the model recover. Throwing would end the turn instead.
    func run(_ call: CoachToolCall) async -> CoachToolResult {
        do {
            let text = try await execute(call)
            return CoachToolResult(callID: call.id, text: text)
        } catch let failure as ToolFailure {
            return CoachToolResult(
                callID: call.id,
                text: failure.errorDescription ?? "The call failed.",
                isError: true
            )
        } catch {
            return CoachToolResult(callID: call.id, text: error.localizedDescription, isError: true)
        }
    }

    private func execute(_ call: CoachToolCall) async throws -> String {
        let arguments = call.arguments
        switch call.name {
        // Reads — run immediately, nothing to approve.
        case "list_routines":         return listRoutines()
        case "get_routine":           return try getRoutine(arguments)
        case "search_exercises":      return searchExercises(arguments)
        case "get_exercise_history":  return try exerciseHistory(arguments)
        case "get_recent_sessions":   return recentSessions(arguments)
        case "get_muscle_fatigue":    return muscleFatigue()
        case "get_profile":           return profileSummary()
        case "get_weekly_plan":       return try weeklyPlanSummary()
        case "get_active_session":    return try activeSessionSummary()

        // Writes — staged for approval.
        case "create_routine":              return try await createRoutine(arguments)
        case "update_routine":              return try await updateRoutine(arguments)
        case "delete_routine":              return try await deleteRoutine(arguments)
        case "add_exercise_to_routine":     return try await addExerciseToRoutine(arguments)
        case "remove_exercise_from_routine": return try await removeExerciseFromRoutine(arguments)
        case "generate_workout":            return try await generateWorkout(arguments)
        case "start_workout":               return try await startWorkout(arguments)
        case "set_plan_day":                return try await setPlanDay(arguments)
        case "clear_plan_day":              return try await clearPlanDay(arguments)
        case "update_profile":              return try await updateProfile(arguments)
        case "create_exercise":             return try await createExercise(arguments)
        case "log_activity":                return try await logActivity(arguments)

        default:
            throw ToolFailure.unknownTool(call.name)
        }
    }

    /// Stages a change and reports the outcome back to the model. A decline is
    /// a normal result, not an error — the model should acknowledge it and move
    /// on rather than retrying the same call.
    private func staged(_ change: PendingChange) async -> String {
        await confirm(change)
            ? change.apply()
            : "The lifter declined this change, so nothing was altered. "
                + "Acknowledge it briefly and ask what they'd rather do — do not retry this call."
    }

    // MARK: - Reads

    private func listRoutines() -> String {
        let routines = allRoutines()
        guard !routines.isEmpty else {
            return "The lifter has no saved routines yet."
        }
        let lines = routines.map { routine -> String in
            let count = routine.exerciseCount
            let focus = routine.focusLabel.map { " · \($0)" } ?? ""
            let targets = routine.hasPrescriptions ? " · has rep/weight targets" : ""
            return "- \(routine.name) (\(count) movement\(count == 1 ? "" : "s")\(focus)\(targets))"
        }
        return "Saved routines:\n" + lines.joined(separator: "\n")
    }

    private func getRoutine(_ arguments: [String: JSONValue]) throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "get_routine")
        }
        return describe(try resolveRoutine(named: name))
    }

    private func searchExercises(_ arguments: [String: JSONValue]) -> String {
        let limit = min(max(arguments.int("limit") ?? 25, 1), 60)
        let query = arguments.string("query")?.lowercased()
        let muscle = arguments.string("muscle").flatMap(Self.muscleGroup(from:))
        let equipment = arguments.string("equipment")?.lowercased()

        let matches = allExercises().filter { exercise in
            if let query, !exercise.name.lowercased().contains(query) { return false }
            if let muscle, !exercise.allMuscleGroups.contains(muscle) { return false }
            if let equipment, exercise.equipmentType.lowercased() != equipment { return false }
            return true
        }

        guard !matches.isEmpty else {
            return "No movements in the library match that. Try a broader search, "
                + "or call create_exercise to add the movement."
        }
        let shown = matches.prefix(limit)
        let lines = shown.map { exercise in
            "- \(exercise.name) (\(exercise.allMuscleGroups.map(\.displayName).joined(separator: ", ")); \(exercise.equipmentType))"
        }
        let more = matches.count > shown.count
            ? "\n…and \(matches.count - shown.count) more. Narrow the search to see them."
            : ""
        return "Matching movements (use these names exactly):\n" + lines.joined(separator: "\n") + more
    }

    private func exerciseHistory(_ arguments: [String: JSONValue]) throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "get_exercise_history")
        }
        let exercise = try resolveExercise(named: name)
        let limit = min(max(arguments.int("limit") ?? 8, 1), 20)

        // One entry per session rather than per set: the top set of each
        // session is what a progression decision actually turns on.
        var grouped: [UUID: (date: Date, sets: [ExerciseSet])] = [:]
        for set in exercise.sets where !set.isWarmup {
            guard let session = set.session else { continue }
            grouped[session.id, default: (session.startDate, [])].sets.append(set)
        }
        let ceiling = exercise.ceiling(for: "1RM")
        let ceilingLine = ceiling > 0
            ? "Best estimated 1RM: \(Int(ceiling.rounded())) lb."
            : "No recorded 1RM yet."

        guard !grouped.isEmpty else {
            return "\(exercise.name): no working sets logged yet. \(ceilingLine) "
                + "Start conservatively."
        }

        let recent = grouped.values.sorted { $0.date > $1.date }.prefix(limit)
        let formatter = Self.dayFormatter
        let lines = recent.map { entry -> String in
            let topWeight = entry.sets.map(\.weight).max() ?? 0
            let topReps = entry.sets.map(\.reps).max() ?? 0
            let load = topWeight > 0 ? "@ \(Int(topWeight.rounded())) lb" : "bodyweight"
            return "- \(formatter.string(from: entry.date)): \(entry.sets.count)×\(topReps) \(load)"
        }
        return "\(exercise.name) — \(ceilingLine)\nRecent sessions (newest first):\n"
            + lines.joined(separator: "\n")
    }

    private func recentSessions(_ arguments: [String: JSONValue]) -> String {
        let limit = min(max(arguments.int("limit") ?? 8, 1), 20)
        let now = Date()
        let finished = allSessions().filter { $0.startDate <= now }.prefix(limit)
        guard !finished.isEmpty else { return "No workouts logged yet." }

        let lines = finished.map { session -> String in
            let days = max(0, Int(now.timeIntervalSince(session.startDate) / 86_400))
            let ago = days == 0 ? "today" : (days == 1 ? "1 day ago" : "\(days) days ago")
            let groups = Set(session.sets.compactMap(\.exercise).flatMap(\.allMuscleGroups))
                .map(\.displayName).sorted()
            let working = session.sets.filter { !$0.isWarmup }.count
            var detail = "\(working) working set\(working == 1 ? "" : "s")"
            if let rir = session.repsInReserve {
                detail += rir == 0 ? ", trained to failure" : ", ~\(rir) reps in reserve"
            }
            let muscles = groups.isEmpty ? "no sets logged" : groups.joined(separator: ", ")
            return "- \(ago): \(session.name) — \(muscles) (\(detail))"
        }
        return "Recent workouts (newest first):\n" + lines.joined(separator: "\n")
    }

    private func muscleFatigue() -> String {
        let now = Date()
        let statuses = MuscleRecovery.statuses(sessions: allSessions(), now: now)
        let lines = MuscleGroup.allCases.compactMap { group -> String? in
            guard let status = statuses[group] else { return nil }
            let recency = status.lastTrained.map { date -> String in
                let days = Int(now.timeIntervalSince(date) / 86_400)
                return days <= 0 ? "today" : (days == 1 ? "1 day ago" : "\(days) days ago")
            } ?? "not in the last week"
            return "- \(group.displayName): \(status.state(now: now).rawValue) — "
                + "last trained \(recency), \(status.weeklySets) sets this week"
        }
        return "Muscle recovery right now:\n" + lines.joined(separator: "\n")
            + "\nAvoid heavy work on anything marked Needs Rest; Recovering takes light or "
            + "indirect work only; prefer Ready and especially Dormant muscles."
    }

    private func profileSummary() -> String {
        let profile = TrainingProfile.current(in: context)
        var lines = [
            "Goal: \(profile.goal.rawValue)",
            "Experience: \(profile.experience.rawValue)",
            "Trains about \(profile.daysPerWeek) days per week",
        ]
        if let weight = HealthKitManager.shared.currentBodyWeightLbs {
            lines.append("Body weight: \(Int(weight.rounded())) lb")
        }
        lines.append("Coaching brief for this goal: \(profile.goal.coachingBrief)")
        return lines.joined(separator: "\n")
    }

    private func weeklyPlanSummary() throws -> String {
        guard let plan = workout.activeWeeklyPlan() else { throw ToolFailure.noWeeklyPlan }
        let days = plan.orderedDays
        guard !days.isEmpty else { return "\"\(plan.name)\" has no training days — every day is a rest day." }

        let lines = days.map { day -> String in
            let movements = day.routine?.exerciseCount ?? 0
            let title = day.routine?.name ?? "no workout assigned"
            return "- \(Self.weekdayName(day.weekday)): \(day.focus.label) — \(title) (\(movements) movements)"
        }
        let resting = (1...7).filter { weekday in !days.contains { $0.weekday == weekday } }
            .map(Self.weekdayName)
        let restLine = resting.isEmpty ? "" : "\nRest days: \(resting.joined(separator: ", "))."
        return "Training week \"\(plan.name)\":\n" + lines.joined(separator: "\n") + restLine
    }

    private func activeSessionSummary() throws -> String {
        guard let session = workout.activeSession else { throw ToolFailure.noActiveSession }
        let logged = session.setsByExercise
        var lines = ["Live workout: \"\(session.name)\", started \(Self.timeFormatter.string(from: session.startDate))."]
        for exercise in workout.sessionExercises {
            let done = logged.first { $0.exercise.id == exercise.id }?.sets.filter { !$0.isWarmup }.count ?? 0
            let target = workout.targetSets(for: exercise)
            lines.append("- \(exercise.name): \(done) of \(target) working sets logged")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Writes

    private func createRoutine(_ arguments: [String: JSONValue]) async throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "create_routine")
        }
        let drafts = try resolveDraftItems(from: arguments.objectArray("exercises"))
        let notes = arguments.string("notes")

        return await staged(PendingChange(
            toolName: "create_routine",
            title: "Create routine “\(name)”",
            detail: drafts.map(Self.describe(draft:)),
            apply: { [workout] in
                workout.createRoutine(name: name, notes: notes, items: drafts)
                return "Created the routine \"\(name)\" with \(drafts.count) movements."
            }
        ))
    }

    private func updateRoutine(_ arguments: [String: JSONValue]) async throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "update_routine")
        }
        let routine = try resolveRoutine(named: name)
        let newName = arguments.string("new_name") ?? routine.name
        let notes = arguments.string("notes") ?? routine.notes

        // An omitted list means "leave the movements alone", which is not the
        // same as an empty one — `updateRoutine` replaces wholesale, so the
        // current items have to be carried forward explicitly.
        let replacing = arguments.array("exercises") != nil
        let drafts: [WorkoutManager.RoutineDraftItem] = replacing
            ? try resolveDraftItems(from: arguments.objectArray("exercises"))
            : routine.orderedItems.compactMap { item in
                item.exercise.map { (
                    exercise: $0,
                    targetSets: item.targetSets,
                    targetReps: item.targetReps,
                    targetWeight: item.targetWeight,
                    supersetGroup: item.supersetGroup
                ) }
            }

        var detail: [String] = []
        if newName != routine.name { detail.append("Rename to “\(newName)”") }
        if replacing {
            detail.append("Replace the movements with:")
            detail.append(contentsOf: drafts.map(Self.describe(draft:)))
        }
        if notes != routine.notes, let notes { detail.append("Note: \(notes)") }
        if detail.isEmpty { detail = ["No visible change."] }

        return await staged(PendingChange(
            toolName: "update_routine",
            title: "Update routine “\(routine.name)”",
            detail: detail,
            apply: { [workout] in
                workout.updateRoutine(routine, name: newName, notes: notes, items: drafts)
                return "Updated the routine \"\(newName)\"; it now has \(drafts.count) movements."
            }
        ))
    }

    private func deleteRoutine(_ arguments: [String: JSONValue]) async throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "delete_routine")
        }
        let routine = try resolveRoutine(named: name)
        let label = routine.name
        let count = routine.exerciseCount

        return await staged(PendingChange(
            toolName: "delete_routine",
            title: "Delete routine “\(label)”",
            detail: ["Removes \(count) movement\(count == 1 ? "" : "s"). Workouts already logged from it are kept."],
            isDestructive: true,
            apply: { [workout] in
                workout.deleteRoutine(routine)
                return "Deleted the routine \"\(label)\"."
            }
        ))
    }

    private func addExerciseToRoutine(_ arguments: [String: JSONValue]) async throws -> String {
        guard let routineName = arguments.string("routine") else {
            throw ToolFailure.missingArgument("routine", tool: "add_exercise_to_routine")
        }
        guard let exerciseName = arguments.string("exercise") else {
            throw ToolFailure.missingArgument("exercise", tool: "add_exercise_to_routine")
        }
        let routine = try resolveRoutine(named: routineName)
        let exercise = try resolveExercise(named: exerciseName)

        guard !routine.items.contains(where: { $0.exercise?.id == exercise.id }) else {
            return "\"\(exercise.name)\" is already in \"\(routine.name)\". Nothing to add."
        }

        let sets = min(max(arguments.int("sets") ?? 3, 1), 8)
        let reps = arguments.int("reps")
        let weight = arguments.double("weight")
        let draft: WorkoutManager.RoutineDraftItem = (exercise, sets, reps, (weight ?? 0) > 0 ? weight : nil, nil)

        return await staged(PendingChange(
            toolName: "add_exercise_to_routine",
            title: "Add “\(exercise.name)” to “\(routine.name)”",
            detail: [Self.describe(draft: draft)],
            apply: { [workout] in
                // Appends the slot, then writes the coached targets the plain
                // `addExercise` path doesn't carry.
                workout.addExercise(exercise, to: routine, targetSets: sets)
                if let item = routine.items.first(where: { $0.exercise?.id == exercise.id }) {
                    workout.updateRoutineItem(
                        item, targetSets: sets, targetReps: reps, targetWeight: weight
                    )
                }
                return "Added \"\(exercise.name)\" to \"\(routine.name)\"."
            }
        ))
    }

    private func removeExerciseFromRoutine(_ arguments: [String: JSONValue]) async throws -> String {
        guard let routineName = arguments.string("routine") else {
            throw ToolFailure.missingArgument("routine", tool: "remove_exercise_from_routine")
        }
        guard let exerciseName = arguments.string("exercise") else {
            throw ToolFailure.missingArgument("exercise", tool: "remove_exercise_from_routine")
        }
        let routine = try resolveRoutine(named: routineName)
        let exercise = try resolveExercise(named: exerciseName)

        guard let item = routine.items.first(where: { $0.exercise?.id == exercise.id }) else {
            return "\"\(exercise.name)\" isn't in \"\(routine.name)\". "
                + "Call get_routine to see what it actually contains."
        }

        return await staged(PendingChange(
            toolName: "remove_exercise_from_routine",
            title: "Remove “\(exercise.name)” from “\(routine.name)”",
            detail: ["The routine's other \(max(0, routine.exerciseCount - 1)) movements are untouched."],
            isDestructive: true,
            apply: { [workout] in
                workout.removeRoutineItem(item)
                return "Removed \"\(exercise.name)\" from \"\(routine.name)\"."
            }
        ))
    }

    private func generateWorkout(_ arguments: [String: JSONValue]) async throws -> String {
        guard let focusName = arguments.string("focus") else {
            throw ToolFailure.missingArgument("focus", tool: "generate_workout")
        }
        guard let focus = Self.focus(from: focusName) else {
            throw ToolFailure.invalidValue(focusName, argument: "focus")
        }
        let count = min(max(arguments.int("exercise_count") ?? 5, 1), 12)
        let withPartner = arguments.bool("with_partner") ?? false
        let allowSupersets = arguments.bool("allow_supersets") ?? true
        let duration = arguments.int("duration_minutes")

        let exercises = allExercises()
        let profile = TrainingProfile.current(in: context)
        let catalog = exercises.map {
            ExerciseBrief(
                name: $0.name,
                muscleGroups: $0.allMuscleGroups.map(\.rawValue),
                equipment: $0.equipmentType, isPerHand: $0.isPerHand
            )
        }
        // The same gate the Train tab uses: without the lifter's opt-in the
        // generator never reaches the network and stays on-device.
        let trainingContext: TrainingContext? = profile.cloudAIEnabled
            ? TrainingContext.build(
                profile: profile,
                sessions: allSessions(),
                exercises: exercises,
                withPartner: withPartner
            )
            : nil

        let plan = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: count,
            durationMinutes: duration,
            withPartner: withPartner,
            allowSupersets: allowSupersets,
            context: trainingContext,
            catalog: catalog
        )

        // Weights always come from the progression engine, never from a model —
        // identical to the Train tab, so a chat-built workout can't prescribe
        // strength the lifter hasn't shown.
        let grounded = WorkoutAI.groundInHistory(
            plan.exercises,
            catalog: exercises,
            goal: profile.goal,
            experience: profile.experience,
            withPartner: withPartner,
            bodyWeightLbs: HealthKitManager.shared.currentBodyWeightLbs
        )
        let drafts = draftItems(from: grounded, catalog: exercises)
        guard !drafts.isEmpty else { throw ToolFailure.emptyExerciseList }

        let name = arguments.string("save_as") ?? plan.title
        let rationale = plan.rationale.map { [$0] } ?? []

        return await staged(PendingChange(
            toolName: "generate_workout",
            title: "Save workout “\(name)”",
            detail: rationale + drafts.map(Self.describe(draft:)),
            apply: { [workout] in
                workout.createRoutine(
                    name: name,
                    notes: plan.rationale,
                    isAIGenerated: true,
                    focusLabel: focus.label,
                    items: drafts
                )
                return "Saved \"\(name)\" (\(plan.source.label)) with \(drafts.count) movements. "
                    + "Use start_workout to begin it."
            }
        ))
    }

    private func startWorkout(_ arguments: [String: JSONValue]) async throws -> String {
        let withPartner = arguments.bool("with_partner") ?? false

        if let routineName = arguments.string("routine") {
            let routine = try resolveRoutine(named: routineName)
            return await staged(PendingChange(
                toolName: "start_workout",
                title: "Start “\(routine.name)”",
                detail: routine.orderedItems.compactMap { item in
                    item.exercise.map { "\($0.name) — \(item.targetSets) sets" }
                },
                apply: { [workout] in
                    workout.startSession(from: routine, withPartner: withPartner)
                    return "Started \"\(routine.name)\". The logging screen is open."
                }
            ))
        }

        let names = (arguments.array("exercises") ?? []).compactMap(\.stringValue)
        guard !names.isEmpty else {
            throw ToolFailure.missingArgument("routine or exercises", tool: "start_workout")
        }
        let exercises = try names.map { try resolveExercise(named: $0) }
        let name = arguments.string("name") ?? "Training Session"

        return await staged(PendingChange(
            toolName: "start_workout",
            title: "Start “\(name)”",
            detail: exercises.map(\.name),
            apply: { [workout] in
                workout.startSession(named: name, exercises: exercises, withPartner: withPartner)
                return "Started \"\(name)\" with \(exercises.count) movements. The logging screen is open."
            }
        ))
    }

    private func setPlanDay(_ arguments: [String: JSONValue]) async throws -> String {
        guard let weekdayName = arguments.string("weekday") else {
            throw ToolFailure.missingArgument("weekday", tool: "set_plan_day")
        }
        guard let weekday = Self.weekday(from: weekdayName) else {
            throw ToolFailure.invalidValue(weekdayName, argument: "weekday")
        }
        guard let focusName = arguments.string("focus") else {
            throw ToolFailure.missingArgument("focus", tool: "set_plan_day")
        }
        guard let focus = Self.focus(from: focusName) else {
            throw ToolFailure.invalidValue(focusName, argument: "focus")
        }

        // Either run a routine the lifter already has, or let the coaching
        // engine build the day — the same generator the Plan tab uses.
        let title: String
        let drafts: [WorkoutManager.RoutineDraftItem]
        if let routineName = arguments.string("routine") {
            let routine = try resolveRoutine(named: routineName)
            title = routine.name
            drafts = routine.orderedItems.compactMap { item in
                item.exercise.map { (
                    exercise: $0,
                    targetSets: item.targetSets,
                    targetReps: item.targetReps,
                    targetWeight: item.targetWeight,
                    supersetGroup: item.supersetGroup
                ) }
            }
        } else {
            let generated = try await generatedDay(focus: focus)
            title = generated.title
            drafts = generated.items
        }
        guard !drafts.isEmpty else { throw ToolFailure.emptyExerciseList }

        let dayName = Self.weekdayName(weekday)
        return await staged(PendingChange(
            toolName: "set_plan_day",
            title: "Set \(dayName) to \(focus.label)",
            detail: ["Workout: “\(title)”"] + drafts.map(Self.describe(draft:)),
            apply: { [workout, context] in
                if let plan = workout.activeWeeklyPlan() {
                    let day: PlannedDay
                    if let existing = plan.days.first(where: { $0.weekday == weekday }) {
                        day = existing
                    } else {
                        day = PlannedDay(weekday: weekday, focus: focus)
                        day.plan = plan
                        context.insert(day)
                    }
                    day.focus = focus
                    workout.replacePlanDayRoutine(day, title: title, items: drafts)
                } else {
                    // No week yet — build one containing just this day. The
                    // lifter can fill in the rest from the Plan tab or by
                    // asking for more days here.
                    workout.buildWeeklyPlan(
                        name: "My Week",
                        exercisesPerDay: drafts.count,
                        duration: .any,
                        withPartner: false,
                        allowSupersets: true,
                        days: [(weekday: weekday, focus: focus, title: title, items: drafts)]
                    )
                }
                return "\(dayName) is now a \(focus.label) day running \"\(title)\"."
            }
        ))
    }

    private func clearPlanDay(_ arguments: [String: JSONValue]) async throws -> String {
        guard let weekdayName = arguments.string("weekday") else {
            throw ToolFailure.missingArgument("weekday", tool: "clear_plan_day")
        }
        guard let weekday = Self.weekday(from: weekdayName) else {
            throw ToolFailure.invalidValue(weekdayName, argument: "weekday")
        }
        guard let plan = workout.activeWeeklyPlan() else { throw ToolFailure.noWeeklyPlan }
        guard let day = plan.days.first(where: { $0.weekday == weekday }) else {
            return "\(Self.weekdayName(weekday)) is already a rest day."
        }

        let dayName = Self.weekdayName(weekday)
        let title = day.routine?.name ?? "its workout"
        return await staged(PendingChange(
            toolName: "clear_plan_day",
            title: "Make \(dayName) a rest day",
            detail: ["Deletes the plan workout “\(title)”. Saved routines in the Library are unaffected."],
            isDestructive: true,
            apply: { [context] in
                context.delete(day)
                plan.updatedAt = Date()
                try? context.save()
                return "\(dayName) is now a rest day."
            }
        ))
    }

    private func updateProfile(_ arguments: [String: JSONValue]) async throws -> String {
        let profile = TrainingProfile.current(in: context)

        var goal: TrainingGoal?
        if let raw = arguments.string("goal") {
            guard let parsed = TrainingGoal.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame })
            else { throw ToolFailure.invalidValue(raw, argument: "goal") }
            goal = parsed
        }
        var experience: ExperienceLevel?
        if let raw = arguments.string("experience") {
            guard let parsed = ExperienceLevel.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame })
            else { throw ToolFailure.invalidValue(raw, argument: "experience") }
            experience = parsed
        }
        let days = arguments.int("days_per_week").map { min(max($0, 1), 7) }

        var detail: [String] = []
        if let goal, goal != profile.goal { detail.append("Goal → \(goal.rawValue)") }
        if let experience, experience != profile.experience { detail.append("Experience → \(experience.rawValue)") }
        if let days, days != profile.daysPerWeek { detail.append("Training days per week → \(days)") }
        guard !detail.isEmpty else {
            return "The profile already matches those values. Nothing to change."
        }

        return await staged(PendingChange(
            toolName: "update_profile",
            title: "Update training profile",
            detail: detail + ["This reshapes every workout the app generates from now on."],
            apply: { [context] in
                if let goal { profile.goal = goal }
                if let experience { profile.experience = experience }
                if let days { profile.daysPerWeek = days }
                profile.updatedAt = Date()
                try? context.save()
                return "Updated the profile: \(detail.joined(separator: "; "))."
            }
        ))
    }

    private func createExercise(_ arguments: [String: JSONValue]) async throws -> String {
        guard let name = arguments.string("name") else {
            throw ToolFailure.missingArgument("name", tool: "create_exercise")
        }
        if let existing = allExercises().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "\"\(existing.name)\" is already in the library — use that name as-is."
        }
        guard let muscleRaw = arguments.string("muscle"), let muscle = Self.muscleGroup(from: muscleRaw) else {
            throw ToolFailure.invalidValue(arguments.string("muscle") ?? "(none)", argument: "muscle")
        }
        guard let equipmentRaw = arguments.string("equipment"),
              let equipment = EquipmentType.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(equipmentRaw) == .orderedSame })
        else {
            throw ToolFailure.invalidValue(arguments.string("equipment") ?? "(none)", argument: "equipment")
        }
        let tracking = arguments.string("tracking").flatMap { raw in
            TrackingType.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
        } ?? .weightAndReps
        let secondary = (arguments.array("secondary_muscles") ?? [])
            .compactMap(\.stringValue)
            .compactMap(Self.muscleGroup(from:))
            .filter { $0 != muscle }

        var detail = ["Primary muscle: \(muscle.displayName)", "Equipment: \(equipment.rawValue)"]
        if !secondary.isEmpty {
            detail.append("Also trains: \(secondary.map(\.displayName).joined(separator: ", "))")
        }
        detail.append("Tracked as: \(tracking.rawValue)")

        return await staged(PendingChange(
            toolName: "create_exercise",
            title: "Add “\(name)” to the library",
            detail: detail,
            apply: { [context] in
                let exercise = Exercise(
                    name: name,
                    muscleGroup: muscle.rawValue,
                    secondaryMuscles: secondary.map(\.rawValue),
                    trackingType: tracking,
                    equipmentType: equipment.rawValue,
                    isCustom: true
                )
                context.insert(exercise)
                try? context.save()
                return "Added \"\(name)\" to the movement library."
            }
        ))
    }

    private func logActivity(_ arguments: [String: JSONValue]) async throws -> String {
        guard let sportRaw = arguments.string("sport") else {
            throw ToolFailure.missingArgument("sport", tool: "log_activity")
        }
        guard let sport = SportType.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(sportRaw) == .orderedSame
        }) else {
            throw ToolFailure.invalidValue(sportRaw, argument: "sport")
        }

        // A zero-length activity earns nothing and logs nothing useful; the app
        // disables its own save button on the same condition.
        guard let requested = arguments.int("duration_minutes"), requested > 0 else {
            throw ToolFailure.missingArgument("duration_minutes", tool: "log_activity")
        }
        // Clamp to a single day — a runaway "480 hours" is a parse slip, not a
        // real session, and it would wildly distort XP.
        let minutes = min(requested, 24 * 60)

        // No date means now, which is what the lifter almost always means by
        // "log a workout". A given date is read leniently, since a model builds
        // it by hand from the conversation's date line.
        let date = arguments.string("date").flatMap(Self.parseDate) ?? Date()

        let xp = XPEngine.xpForActivity(minutes: minutes)
        let when = Self.activityDateFormatter.string(from: date)

        return await staged(PendingChange(
            toolName: "log_activity",
            title: "Log \(sport.rawValue)",
            detail: [
                "\(Self.durationLabel(minutes)) — \(when)",
                "Earns \(xp) XP",
            ],
            apply: { [context] in
                context.insert(Activity(sport: sport, date: date, durationMinutes: minutes))
                try? context.save()
                // The same side effects the Activity logging screen fires, so a
                // coach-logged session updates widgets and the streak reminder
                // exactly as a hand-logged one does.
                WidgetSnapshotter.shared.refresh()
                StepGoalMonitor.shared.refreshStreakReminder()
                return "Logged \(Self.durationLabel(minutes)) of \(sport.rawValue) on \(when), worth \(xp) XP."
            }
        ))
    }

    // MARK: - Generation helper

    /// Builds one plan day with the app's coaching engine, grounded in history.
    private func generatedDay(
        focus: WorkoutFocus
    ) async throws -> (title: String, items: [WorkoutManager.RoutineDraftItem]) {
        let exercises = allExercises()
        let profile = TrainingProfile.current(in: context)
        let catalog = exercises.map {
            ExerciseBrief(
                name: $0.name,
                muscleGroups: $0.allMuscleGroups.map(\.rawValue),
                equipment: $0.equipmentType, isPerHand: $0.isPerHand
            )
        }
        let trainingContext: TrainingContext? = profile.cloudAIEnabled
            ? TrainingContext.build(
                profile: profile, sessions: allSessions(), exercises: exercises, withPartner: false
            )
            : nil

        let plan = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: max(3, profile.daysPerWeek >= 5 ? 4 : 5),
            durationMinutes: nil,
            withPartner: false,
            allowSupersets: true,
            context: trainingContext,
            catalog: catalog
        )
        let grounded = WorkoutAI.groundInHistory(
            plan.exercises,
            catalog: exercises,
            goal: profile.goal,
            experience: profile.experience,
            withPartner: false,
            bodyWeightLbs: HealthKitManager.shared.currentBodyWeightLbs
        )
        return (plan.title, draftItems(from: grounded, catalog: exercises))
    }

    /// Maps generated movements back onto real library entries, dropping any
    /// that no longer resolve.
    private func draftItems(
        from planned: [PlannedExercise],
        catalog: [Exercise]
    ) -> [WorkoutManager.RoutineDraftItem] {
        let byName = Dictionary(catalog.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        return planned.compactMap { entry in
            guard let exercise = byName[entry.name.lowercased()] else { return nil }
            let weight = entry.prescription?.targetLoadPounds ?? 0
            return (
                exercise: exercise,
                targetSets: entry.sets,
                targetReps: entry.targetReps,
                targetWeight: weight > 0 ? weight : nil,
                supersetGroup: entry.supersetGroup
            )
        }
    }

    // MARK: - Resolution

    /// Turns the model's `exercises` argument into validated draft slots.
    /// Every name must resolve before any of them is used, so a routine is
    /// never half-built from a partially hallucinated list.
    private func resolveDraftItems(
        from entries: [[String: JSONValue]]
    ) throws -> [WorkoutManager.RoutineDraftItem] {
        guard !entries.isEmpty else { throw ToolFailure.emptyExerciseList }
        return try entries.map { entry in
            guard let name = entry.string("name") else {
                throw ToolFailure.missingArgument("name", tool: "the exercises list")
            }
            let exercise = try resolveExercise(named: name)
            let weight = entry.double("weight") ?? 0
            let group = entry.int("superset_group")
            return (
                exercise: exercise,
                targetSets: min(max(entry.int("sets") ?? 3, 1), 8),
                targetReps: entry.int("reps").map { max(1, $0) },
                targetWeight: weight > 0 ? weight : nil,
                supersetGroup: (group ?? 0) == 0 ? nil : group
            )
        }
    }

    /// Finds a library movement by name: exact first, then a containment match,
    /// so "bench press" resolves to "Barbell Bench Press". A miss carries the
    /// nearest names so the model's retry is informed rather than another guess.
    private func resolveExercise(named name: String) throws -> Exercise {
        let exercises = allExercises()
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let exact = exercises.first(where: { $0.name.lowercased() == target }) { return exact }

        let contained = exercises.filter {
            $0.name.lowercased().contains(target) || target.contains($0.name.lowercased())
        }
        // Only auto-accept an unambiguous partial match; two candidates mean
        // the model has to choose, and it needs the names to do that.
        if contained.count == 1, let only = contained.first { return only }

        let suggestions = contained.isEmpty
            ? exercises.filter { $0.name.lowercased().sharesWord(with: target) }.prefix(6).map(\.name)
            : contained.prefix(6).map(\.name)
        throw ToolFailure.noSuchExercise(name, suggestions: Array(suggestions))
    }

    private func resolveRoutine(named name: String) throws -> Routine {
        let routines = allRoutines()
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let exact = routines.first(where: { $0.name.lowercased() == target }) { return exact }
        let contained = routines.filter { $0.name.lowercased().contains(target) }
        if contained.count == 1, let only = contained.first { return only }

        throw ToolFailure.noSuchRoutine(name, available: routines.map(\.name))
    }

    // MARK: - Fetching

    private func allExercises() -> [Exercise] {
        (try? context.fetch(FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    /// Library routines only — plan-owned days are edited through the plan
    /// tools, and surfacing them here would let the coach delete a training day
    /// while thinking it was tidying the Library.
    private func allRoutines() -> [Routine] {
        let all = (try? context.fetch(FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return all.filter { !$0.isPlanDay }
    }

    private func allSessions() -> [WorkoutSession] {
        (try? context.fetch(
            FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        )) ?? []
    }

    // MARK: - Formatting

    private func describe(_ routine: Routine) -> String {
        let items = routine.orderedItems
        guard !items.isEmpty else { return "\"\(routine.name)\" has no movements yet." }

        let runs = supersetRuns(Array(items.indices)) { items[$0].supersetGroup }
        var lines: [String] = []
        for run in runs {
            let paired = run.count > 1
            for index in run {
                let item = items[index]
                guard let exercise = item.exercise else { continue }
                var parts = ["\(item.targetSets) sets"]
                if let reps = item.targetReps { parts.append("\(reps) reps") }
                if let weight = item.targetWeight, weight > 0 {
                    parts.append("\(Int(weight.rounded())) lb")
                }
                let tag = paired ? " [superset]" : ""
                lines.append("- \(exercise.name)\(tag) — \(parts.joined(separator: ", "))")
            }
        }
        let notes = routine.notes.map { "\nNote: \($0)" } ?? ""
        return "Routine \"\(routine.name)\":\n" + lines.joined(separator: "\n") + notes
    }

    private static func describe(draft: WorkoutManager.RoutineDraftItem) -> String {
        var parts = ["\(draft.targetSets) sets"]
        if let reps = draft.targetReps { parts.append("\(reps) reps") }
        if let weight = draft.targetWeight, weight > 0 { parts.append("\(Int(weight.rounded())) lb") }
        let tag = (draft.supersetGroup ?? 0) != 0 ? " · superset \(draft.supersetGroup!)" : ""
        return "\(draft.exercise.name) — \(parts.joined(separator: ", "))\(tag)"
    }

    // MARK: - Parsing

    /// Accepts a muscle by its UI name ("Back") or its stored raw value
    /// ("Lats"), since the model sees the former and the data uses the latter.
    private static func muscleGroup(from text: String) -> MuscleGroup? {
        MuscleGroup.allCases.first {
            $0.displayName.caseInsensitiveCompare(text) == .orderedSame
                || $0.rawValue.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    private static func focus(from text: String) -> WorkoutFocus? {
        WorkoutFocus.allCases.first {
            $0.label.caseInsensitiveCompare(text) == .orderedSame
                || $0.rawValue.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    /// `Calendar` weekday numbering: 1 = Sunday … 7 = Saturday.
    private static func weekday(from text: String) -> Int? {
        let target = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let number = Int(target), (1...7).contains(number) { return number }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = names.firstIndex(where: { $0 == target || $0.hasPrefix(target) && target.count >= 3 }) {
            return index + 1
        }
        return nil
    }

    private static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : "Day \(weekday)"
    }

    /// Reads the date a model wrote for an activity. It's asked for ISO 8601,
    /// but small models drop the seconds or the timezone, so several near-forms
    /// are tried before giving up — a `nil` here just means "log it now", which
    /// is a fine default rather than a failure.
    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) { return date }
        }
        // Timezone-less local forms, newest-drift first.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// A minute count as the lifter would say it: "45 min", "2 hr", "1 hr 30 min".
    private static func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _): return "\(remainder) min"
        case (_, 0): return "\(hours) hr"
        default:     return "\(hours) hr \(remainder) min"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// An activity's date and time together, e.g. "Aug 9 at 6:00 PM" — what the
    /// approval card and confirmation read back to the lifter.
    private static let activityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter
    }()
}

private extension String {
    /// Whether the two strings share any word of three or more characters —
    /// a cheap last resort for suggesting names after a failed lookup.
    func sharesWord(with other: String) -> Bool {
        let words = Set(split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let otherWords = other.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        return otherWords.contains { words.contains($0) }
    }
}

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A lightweight, model-friendly description of one catalog exercise.
struct ExerciseBrief {
    let name: String
    let muscleGroups: [String]
    let equipment: String
}

/// The full prescription for one movement — only the cloud coach produces
/// these; on-device and catalog plans leave it nil and fall back to showing
/// the lifter's own history.
struct Prescription {
    let repRangeLow: Int
    let repRangeHigh: Int
    /// Suggested working weight in canonical pounds. Zero = bodyweight.
    let targetLoadPounds: Double
    let restSeconds: Int
    let note: String

    var repRangeText: String {
        repRangeLow == repRangeHigh ? "\(repRangeLow)" : "\(repRangeLow)-\(repRangeHigh)"
    }
}

/// One exercise the AI (or fallback) chose for a generated workout.
struct PlannedExercise: Identifiable {
    let id: UUID
    let name: String
    let sets: Int
    let prescription: Prescription?
    /// The single rep target resolved from the prescription's range — the lifter
    /// can slide it anywhere in `repRangeLow...repRangeHigh`; defaults to the top
    /// of the range. Nil when there is no coached prescription to resolve.
    var targetReps: Int?

    init(id: UUID = UUID(), name: String, sets: Int, prescription: Prescription? = nil) {
        self.id = id
        self.name = name
        self.sets = sets
        self.prescription = prescription
        self.targetReps = prescription?.repRangeHigh
    }
}

/// Which tier actually produced a plan. Surfaced in the UI so the lifter is
/// never told a plan is fatigue-aware when it came from the offline fallback.
enum PlanSource {
    case cloud
    /// A self-hosted model on the lifter's own machine, via Odysseus.
    case selfHosted
    case onDevice
    case catalog

    var label: String {
        switch self {
        case .cloud:      return "Coached by Claude"
        case .selfHosted: return "Coached by your server"
        case .onDevice:   return "Generated on device"
        case .catalog:    return "Picked from your library"
        }
    }
}

/// A generated workout: a fun title plus an ordered list of exercises to run.
struct WorkoutPlan {
    let title: String
    var exercises: [PlannedExercise]
    /// The coach's explanation of the session — cloud tier only.
    var rationale: String? = nil
    var source: PlanSource = .onDevice
    /// Why the cloud tier was skipped or failed, when it was attempted.
    var cloudError: String? = nil
}

/// On-device workout intelligence — session names and full workout plans.
/// Uses Apple's FoundationModels when available; otherwise falls back to
/// deterministic local generation. Zero cloud, zero API keys.
enum WorkoutAI {

    // MARK: - Session names

    /// Generates a short, fun, video-game-themed session name.
    static func generateSessionName(focus: String? = nil) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                return try await generateNameWithModel(focus: focus)
            } catch {
                return fallbackName()
            }
        }
        #endif
        return fallbackName()
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateNameWithModel(focus: String?) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You name workout sessions for LimitBreak, an RPG-styled fitness app. \
            Reply with ONE short, punchy, video-game-themed session name — 2 to 4 words. \
            Think raid bosses, level-ups, dungeon runs, power surges, combo breakers. \
            No quotes, no emojis, no trailing punctuation, no explanation. Just the name.
            """)
        let prompt = focus.map { "Theme the name around a \($0) focus." }
            ?? "Give me today's session name."
        let response = try await session.respond(to: prompt)
        return sanitizeName(response.content)
    }
    #endif

    private static func sanitizeName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Take only the first line in case the model rambled.
        if let firstLine = name.split(separator: "\n").first {
            name = String(firstLine)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”‘’ "))
        return name.isEmpty ? fallbackName() : name
    }

    private static func fallbackName() -> String {
        let names = [
            "Boss Rush", "Level Up Grind", "XP Farm Run", "Raid Prep",
            "Dungeon Crawl", "Power Surge", "Combo Breaker", "Overclock Session",
            "Berserk Mode", "New Game Plus", "Critical Strike", "Loot Run",
            "Skill Tree Unlock", "Final Boss Prep", "Stamina Overload", "Adrenaline Rush"
        ]
        return names.randomElement() ?? "Training Session"
    }

    // MARK: - Workout plans

    /// Generates a full workout plan for the given focus and length, choosing
    /// exercises only from the provided catalog.
    static func generatePlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool = false,
        context: TrainingContext? = nil,
        catalog: [ExerciseBrief]
    ) async -> WorkoutPlan {
        let count = max(1, min(exerciseCount, catalog.count))

        // Tier 1: the coached plan — the only tier that sees muscle fatigue, the
        // lifter's goal, and their recorded ceilings. Which backend answers is
        // the lifter's choice; both are handed identical prompts, and both
        // degrade to the tiers below rather than failing the request.
        var cloudError: String?
        if let context, let backend = configuredBackend(for: context.provider) {
            do {
                let coached: CoachedPlan
                switch backend {
                case .claude:
                    coached = try await CloudWorkoutAI.generatePlan(
                        focusLabel: focusLabel,
                        targetMuscleGroups: targetMuscleGroups,
                        exerciseCount: count,
                        durationMinutes: durationMinutes,
                        context: context,
                        catalog: catalog
                    )
                case .odysseus:
                    coached = try await OdysseusWorkoutAI.generatePlan(
                        focusLabel: focusLabel,
                        targetMuscleGroups: targetMuscleGroups,
                        exerciseCount: count,
                        durationMinutes: durationMinutes,
                        context: context,
                        catalog: catalog
                    )
                }

                let source: PlanSource = backend == .claude ? .cloud : .selfHosted
                if let plan = matchToCatalog(coached, catalog: catalog, limit: count, source: source) {
                    return plan
                }
                cloudError = "The coach returned movements that aren't in your library."
            } catch {
                // Every tier below still works offline, so a coaching failure
                // degrades the plan rather than failing the request.
                cloudError = coachingErrorMessage(error)
            }
        }

        var plan = await onDevicePlan(
            focusLabel: focusLabel,
            targetMuscleGroups: targetMuscleGroups,
            exerciseCount: count,
            durationMinutes: durationMinutes,
            withPartner: withPartner,
            catalog: catalog
        )
        plan.cloudError = cloudError
        return plan
    }

    /// `provider` if it is fully set up, otherwise nil.
    ///
    /// Returning nil is the normal path for a lifter who has turned coaching on
    /// but not yet finished configuring it — generation quietly falls through to
    /// the on-device tiers instead of erroring.
    private static func configuredBackend(for provider: AIProvider) -> AIProvider? {
        switch provider {
        case .claude:   return CloudWorkoutAI.isConfigured ? .claude : nil
        case .odysseus: return OdysseusWorkoutAI.isConfigured ? .odysseus : nil
        }
    }

    /// The lifter-facing reason a coached plan couldn't be produced. Both
    /// clients define their own error enum, and each writes better copy than
    /// `localizedDescription` — particularly for a rejected credential, which
    /// has to read as "your token is wrong", not "the request failed".
    private static func coachingErrorMessage(_ error: Error) -> String {
        if let error = error as? ClaudeClient.ClientError {
            return error.errorDescription ?? error.localizedDescription
        }
        if let error = error as? OdysseusClient.OdysseusError {
            return error.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }

    /// Maps the coach's picks back onto real catalog entries, dropping anything
    /// hallucinated or duplicated. Returns nil when nothing survives.
    /// Internal rather than private so the clamping rules can be tested.
    static func matchToCatalog(
        _ coached: CoachedPlan,
        catalog: [ExerciseBrief],
        limit: Int,
        source: PlanSource = .cloud
    ) -> WorkoutPlan? {
        let byName = Dictionary(catalog.map { ($0.name.lowercased(), $0.name) }) { first, _ in first }
        var seen = Set<String>()
        var matched: [PlannedExercise] = []

        for entry in coached.exercises {
            let key = entry.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard let realName = byName[key], !seen.contains(realName) else { continue }
            seen.insert(realName)

            let low = max(1, min(entry.repRangeLow, entry.repRangeHigh))
            let high = max(low, max(entry.repRangeLow, entry.repRangeHigh))
            matched.append(PlannedExercise(
                name: realName,
                sets: min(max(entry.sets, 1), 8),
                prescription: Prescription(
                    repRangeLow: low,
                    repRangeHigh: high,
                    targetLoadPounds: max(0, entry.targetLoadPounds),
                    restSeconds: min(max(entry.restSeconds, 15), 600),
                    note: entry.note
                )
            ))
            if matched.count == limit { break }
        }

        guard !matched.isEmpty else { return nil }
        return WorkoutPlan(
            title: sanitizeName(coached.title),
            exercises: matched,
            rationale: coached.rationale,
            source: source
        )
    }

    /// Tiers 2 and 3: Apple's on-device model, then deterministic selection.
    private static func onDevicePlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool,
        catalog: [ExerciseBrief]
    ) async -> WorkoutPlan {
        let count = exerciseCount

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                return try await generatePlanWithModel(
                    focusLabel: focusLabel,
                    exerciseCount: count,
                    durationMinutes: durationMinutes,
                    withPartner: withPartner,
                    catalog: focusedCatalog(catalog, targetMuscleGroups: targetMuscleGroups)
                )
            } catch {
                return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: targetMuscleGroups, exerciseCount: count, catalog: catalog)
            }
        }
        #endif
        return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: targetMuscleGroups, exerciseCount: count, catalog: catalog)
    }

    // MARK: - Single-exercise replacement

    /// Picks one replacement movement for a single slot in an existing plan.
    /// Prefers something that trains muscles similar to the outgoing exercise
    /// while avoiding anything already in the plan. Returns the catalog name to
    /// swap in, or `nil` if nothing suitable is available.
    static func replaceExercise(
        focusLabel: String,
        targetMuscleGroups: [String],
        replacing currentName: String,
        excluding: Set<String>,
        catalog: [ExerciseBrief]
    ) async -> String? {
        // Everything already in the plan (including the outgoing name) is off-limits.
        let available = catalog.filter { !excluding.contains($0.name.lowercased()) }
        guard !available.isEmpty else { return nil }

        // Muscles the outgoing movement trained — the swap should stay in that lane.
        let currentMuscles = Set(
            (catalog.first { $0.name.lowercased() == currentName.lowercased() }?.muscleGroups ?? [])
                .map { $0.lowercased() }
        )

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                let picked = try await replaceExerciseWithModel(
                    focusLabel: focusLabel,
                    replacing: currentName,
                    catalog: focusedCatalog(available, targetMuscleGroups: Array(currentMuscles.isEmpty ? Set(targetMuscleGroups.map { $0.lowercased() }) : currentMuscles))
                )
                return picked ?? fallbackReplacement(currentMuscles: currentMuscles, targetMuscleGroups: targetMuscleGroups, available: available)
            } catch {
                return fallbackReplacement(currentMuscles: currentMuscles, targetMuscleGroups: targetMuscleGroups, available: available)
            }
        }
        #endif
        return fallbackReplacement(currentMuscles: currentMuscles, targetMuscleGroups: targetMuscleGroups, available: available)
    }

    /// Deterministic single swap: favor a movement sharing the outgoing exercise's
    /// muscles (or the focus muscles when unknown), else anything still available.
    private static func fallbackReplacement(
        currentMuscles: Set<String>,
        targetMuscleGroups: [String],
        available: [ExerciseBrief]
    ) -> String? {
        let targets = currentMuscles.isEmpty
            ? Set(targetMuscleGroups.map { $0.lowercased() })
            : currentMuscles
        let matches = available.filter { brief in
            brief.muscleGroups.contains { targets.contains($0.lowercased()) }
        }
        let pool = matches.isEmpty ? available : matches
        return pool.shuffled().first?.name
    }

    #if canImport(FoundationModels)
    /// Guided-generation shape for a single replacement pick. The returned name is
    /// matched back to the real catalog, so a hallucinated name yields `nil`.
    @available(iOS 26.0, *)
    @Generable
    struct GeneratedReplacement {
        @Guide(description: "The exact exercise name, copied verbatim from the provided catalog list")
        var name: String
    }

    @available(iOS 26.0, *)
    private static func replaceExerciseWithModel(
        focusLabel: String,
        replacing currentName: String,
        catalog: [ExerciseBrief]
    ) async throws -> String? {
        guard !catalog.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You are a strength coach for LimitBreak, an RPG-styled workout tracker. \
            Pick ONE replacement exercise from a fixed catalog to swap in for another movement. \
            Only ever use an exercise name that appears verbatim in the catalog — never invent names. \
            Prefer a movement that trains similar muscles to the one being replaced, but is a different exercise.
            """)

        let catalogList = catalog
            .map { "- \($0.name) (\($0.muscleGroups.joined(separator: ", ")); \($0.equipment))" }
            .joined(separator: "\n")

        let prompt = """
            Focus: \(focusLabel)
            Replace this exercise: \(currentName)
            Pick a single different exercise from the catalog that trains similar muscles.

            Catalog:
            \(catalogList)
            """

        let response = try await session.respond(to: prompt, generating: GeneratedReplacement.self)
        let byName = Dictionary(catalog.map { ($0.name.lowercased(), $0.name) }) { first, _ in first }
        let key = response.content.name.lowercased().trimmingCharacters(in: .whitespaces)
        return byName[key]
    }
    #endif

    /// Trims the library to what the on-device model actually needs: movements
    /// hitting the focus muscles first, a shuffled handful of accessories after,
    /// capped so a ~175-exercise catalog can't overflow the model's context.
    static func focusedCatalog(
        _ catalog: [ExerciseBrief],
        targetMuscleGroups: [String],
        cap: Int = 70
    ) -> [ExerciseBrief] {
        guard catalog.count > cap else { return catalog }
        guard !targetMuscleGroups.isEmpty else { return Array(catalog.shuffled().prefix(cap)) }

        let targets = Set(targetMuscleGroups)
        var focused: [ExerciseBrief] = []
        var accessories: [ExerciseBrief] = []
        for brief in catalog {
            if brief.muscleGroups.contains(where: targets.contains) {
                focused.append(brief)
            } else {
                accessories.append(brief)
            }
        }

        var result = Array(focused.shuffled().prefix(cap))
        if result.count < cap {
            result += accessories.shuffled().prefix(cap - result.count)
        }
        return result
    }

    #if canImport(FoundationModels)
    /// Guided-generation shape the model fills in. Names are matched back to the
    /// real catalog afterward, so hallucinated names are simply dropped.
    @available(iOS 26.0, *)
    @Generable
    struct GeneratedPlan {
        @Guide(description: "A short, fun, video-game-themed name for this workout, 2 to 4 words")
        var title: String
        @Guide(description: "The exercises to perform, in a sensible order (compound lifts first)")
        var exercises: [GeneratedExercise]
    }

    @available(iOS 26.0, *)
    @Generable
    struct GeneratedExercise {
        @Guide(description: "The exact exercise name, copied verbatim from the provided catalog list")
        var name: String
        @Guide(description: "Number of working sets, between 2 and 5")
        var sets: Int
    }

    @available(iOS 26.0, *)
    private static func generatePlanWithModel(
        focusLabel: String,
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool,
        catalog: [ExerciseBrief]
    ) async throws -> WorkoutPlan {
        var instructions = """
            You are a strength coach for LimitBreak, an RPG-styled workout tracker. \
            Design a focused workout by selecting exercises from a fixed catalog. \
            Only ever use exercise names that appear verbatim in the catalog — never invent names. \
            Order the exercises sensibly, leading with the biggest compound movements. \
            Give the workout a short, fun, video-game-themed title.
            """
        if withPartner {
            instructions += """
                \nThe lifter is training with a partner who can spot them, so heavy \
                free-weight work is safe to program. Favor barbell and dumbbell \
                pressing and squatting movements — the lifts where a spotter lets \
                someone push closer to failure — over machine and cable versions.
                """
        }
        let session = LanguageModelSession(instructions: instructions)

        let catalogList = catalog
            .map { "- \($0.name) (\($0.muscleGroups.joined(separator: ", ")); \($0.equipment))" }
            .joined(separator: "\n")

        var prompt = """
            Focus: \(focusLabel)
            Select exactly \(exerciseCount) exercises.
            """
        if let durationMinutes {
            prompt += "\nTarget workout length: about \(durationMinutes) minutes."
        }
        if withPartner {
            prompt += "\nA spotter is available — lean into spottable free-weight lifts."
        }
        prompt += "\n\nCatalog:\n\(catalogList)"

        let response = try await session.respond(to: prompt, generating: GeneratedPlan.self)
        let plan = response.content

        let byName = Dictionary(catalog.map { ($0.name.lowercased(), $0.name) }) { first, _ in first }
        var seen = Set<String>()
        var matched: [PlannedExercise] = []
        for exercise in plan.exercises {
            let key = exercise.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard let realName = byName[key], !seen.contains(realName) else { continue }
            seen.insert(realName)
            matched.append(PlannedExercise(name: realName, sets: min(max(exercise.sets, 2), 5)))
            if matched.count == exerciseCount { break }
        }

        guard !matched.isEmpty else {
            return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: [], exerciseCount: exerciseCount, catalog: catalog)
        }

        let title = sanitizeName(plan.title)
        return WorkoutPlan(title: title, exercises: matched, source: .onDevice)
    }
    #endif

    /// Deterministic selection: matches catalog entries against the focus's
    /// target muscle groups, favoring primary hits, and picks a spread.
    private static func fallbackPlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        catalog: [ExerciseBrief]
    ) -> WorkoutPlan {
        let targets = Set(targetMuscleGroups.map { $0.lowercased() })

        let pool: [ExerciseBrief]
        if targets.isEmpty {
            pool = catalog
        } else {
            let matches = catalog.filter { brief in
                brief.muscleGroups.contains { targets.contains($0.lowercased()) }
            }
            pool = matches.isEmpty ? catalog : matches
        }

        // Prefer exercises whose PRIMARY muscle is a target, then fill from the rest.
        let primaryFirst = pool.sorted { lhs, rhs in
            let lPrimary = lhs.muscleGroups.first.map { targets.contains($0.lowercased()) } ?? false
            let rPrimary = rhs.muscleGroups.first.map { targets.contains($0.lowercased()) } ?? false
            return lPrimary && !rPrimary
        }

        let chosen = Array(primaryFirst.shuffled().prefix(exerciseCount))
        let exercises = chosen.map { PlannedExercise(name: $0.name, sets: 3) }
        return WorkoutPlan(title: fallbackName(), exercises: exercises, source: .catalog)
    }
}

// MARK: - Shared generation config

/// A training focus the AI generator can target. Shared by the AI workout sheet
/// and the routine editor.
enum WorkoutFocus: String, CaseIterable, Identifiable {
    case fullBody, push, pull, legs, upper, back, shoulders, chest, core, arms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullBody:  return "Full Body"
        case .push:      return "Push"
        case .pull:      return "Pull"
        case .legs:      return "Legs"
        case .upper:     return "Upper Body"
        case .back:      return "Back"
        case .shoulders: return "Shoulders"
        case .chest:     return "Chest"
        case .core:      return "Core"
        case .arms:      return "Arms"
        }
    }

    var icon: String {
        switch self {
        case .fullBody:  return "figure.mixed.cardio"
        case .push:      return "figure.strengthtraining.traditional"
        case .pull:      return "figure.rower"
        case .legs:      return "figure.run"
        case .upper:     return "figure.arms.open"
        case .back:      return "figure.rower"
        case .shoulders: return "figure.arms.open"
        case .chest:     return "figure.strengthtraining.traditional"
        case .core:      return "figure.core.training"
        case .arms:      return "dumbbell.fill"
        }
    }

    /// Muscle group raw values this focus targets — these are stored raw values,
    /// not display names (see `MuscleGroup.displayName`). Empty means
    /// "everything".
    var targetMuscleGroups: [String] {
        switch self {
        case .fullBody:  return []
        case .push:      return ["Chest", "Deltoids", "Triceps"]
        case .pull:      return ["Lats", "Traps", "Biceps", "Forearms"]
        case .legs:      return ["Quads", "Hamstrings", "Glutes", "Calves"]
        case .upper:     return ["Chest", "Lats", "Traps", "Deltoids", "Biceps", "Triceps"]
        case .back:      return ["Lats", "Traps"]
        case .shoulders: return ["Deltoids"]
        case .chest:     return ["Chest"]
        case .core:      return ["Core"]
        case .arms:      return ["Biceps", "Triceps", "Forearms"]
        }
    }
}

/// A rough target length for a generated workout.
enum WorkoutLength: String, CaseIterable, Identifiable {
    case any, quick, standard, long

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any:      return "Any"
        case .quick:    return "20 min"
        case .standard: return "40 min"
        case .long:     return "60 min"
        }
    }

    var minutes: Int? {
        switch self {
        case .any:      return nil
        case .quick:    return 20
        case .standard: return 40
        case .long:     return 60
        }
    }
}

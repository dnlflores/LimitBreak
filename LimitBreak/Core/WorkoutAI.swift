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
    /// Superset grouping tag. Exercises sharing a non-nil value are meant to run
    /// back-to-back as one superset. Nil means standalone. Normalized to clean
    /// 1…N runs by `matchToCatalog` after catalog matching.
    var supersetGroup: Int?

    init(
        id: UUID = UUID(),
        name: String,
        sets: Int,
        prescription: Prescription? = nil,
        supersetGroup: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.sets = sets
        self.prescription = prescription
        self.targetReps = prescription?.repRangeHigh
        self.supersetGroup = supersetGroup
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
        allowSupersets: Bool = false,
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
                        allowSupersets: allowSupersets,
                        catalog: catalog
                    )
                case .odysseus:
                    coached = try await OdysseusWorkoutAI.generatePlan(
                        focusLabel: focusLabel,
                        targetMuscleGroups: targetMuscleGroups,
                        exerciseCount: count,
                        durationMinutes: durationMinutes,
                        context: context,
                        allowSupersets: allowSupersets,
                        catalog: catalog
                    )
                }

                let source: PlanSource = backend == .claude ? .cloud : .selfHosted
                if let plan = matchToCatalog(coached, catalog: catalog, slots: count, allowSupersets: allowSupersets, source: source) {
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
            allowSupersets: allowSupersets,
            context: context,
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
    /// hallucinated or duplicated, then trims the result to `slots` session
    /// slots. Returns nil when nothing survives.
    ///
    /// A "slot" is one entry in the session as the lifter reads it: a standalone
    /// movement is one slot, and a whole superset is *also* one slot even though
    /// it holds two or three movements. So a 5-slot request with one superset
    /// yields six movements, with two supersets yields seven, and with none
    /// yields exactly five — the movement count only grows by what a superset
    /// genuinely needs, never by a flat headroom the model fills for no reason.
    ///
    /// Internal rather than private so the slot and clamping rules can be tested.
    static func matchToCatalog(
        _ coached: CoachedPlan,
        catalog: [ExerciseBrief],
        slots: Int,
        allowSupersets: Bool = false,
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
            // Superset tags only carry through when the session asked for them;
            // otherwise every movement is standalone regardless of what the
            // model emitted.
            let rawGroup = allowSupersets
                ? entry.supersetGroup.flatMap { $0 == 0 ? nil : $0 }
                : nil
            matched.append(PlannedExercise(
                name: realName,
                sets: min(max(entry.sets, 1), 8),
                prescription: Prescription(
                    repRangeLow: low,
                    repRangeHigh: high,
                    targetLoadPounds: max(0, entry.targetLoadPounds),
                    restSeconds: min(max(entry.restSeconds, 15), 600),
                    note: entry.note
                ),
                supersetGroup: rawGroup
            ))
        }

        let selected = allowSupersets
            ? selectSlots(matched, slots: slots)
            : Array(matched.prefix(slots))

        guard !selected.isEmpty else { return nil }
        return WorkoutPlan(
            title: sanitizeName(coached.title),
            exercises: normalizeSupersets(selected),
            rationale: coached.rationale,
            source: source
        )
    }

    /// Trims matched movements to `slots` session slots, keeping supersets whole.
    ///
    /// Two limits work together so the session can never collapse into all
    /// supersets. Supersets are *pairs*: an oversized group the model emitted is
    /// trimmed to its first two movements, and the extras fall back to standalone
    /// slots. And at most half the slots may be supersets (`slots / 2`), so at
    /// least half the session stays standalone straight sets. Anything past
    /// either limit fills standalone slots one movement at a time, in order,
    /// until the slot budget runs out.
    static func selectSlots(_ exercises: [PlannedExercise], slots: Int) -> [PlannedExercise] {
        let maxSupersets = slots / 2
        let runs = supersetRuns(Array(exercises.indices)) { exercises[$0].supersetGroup }

        var result: [PlannedExercise] = []
        var usedSlots = 0
        var keptSupersets = 0

        func addStandalone(_ index: Int) {
            var exercise = exercises[index]
            exercise.supersetGroup = nil
            result.append(exercise)
            usedSlots += 1
        }

        for run in runs {
            if usedSlots >= slots { break }
            if run.count > 1 && keptSupersets < maxSupersets {
                // Keep the first two movements as one superset slot; a group of
                // three or more is trimmed to a pair, its extras demoted below.
                for index in run.prefix(2) { result.append(exercises[index]) }
                keptSupersets += 1
                usedSlots += 1
                for index in run.dropFirst(2) where usedSlots < slots { addStandalone(index) }
            } else {
                // Standalone, or a superset past the cap — its movements each take
                // a standalone slot until the budget runs out.
                for index in run where usedSlots < slots { addStandalone(index) }
            }
        }
        return result
    }

    /// Rewrites coached superset tags into clean, contiguous 1…N groups after
    /// catalog matching. Dropping hallucinated movements can leave a group with a
    /// single survivor, or scatter a tag across non-adjacent slots — both collapse
    /// to standalone here so only real, back-to-back supersets reach the UI.
    static func normalizeSupersets(_ exercises: [PlannedExercise]) -> [PlannedExercise] {
        var result = exercises
        let runs = supersetRuns(Array(result.indices)) { result[$0].supersetGroup }
        var tag = 0
        for run in runs {
            if run.count > 1 {
                tag += 1
                for i in run { result[i].supersetGroup = tag }
            } else {
                result[run[0]].supersetGroup = nil
            }
        }
        return result
    }

    /// Tiers 2 and 3: Apple's on-device model, then deterministic selection.
    private static func onDevicePlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool,
        allowSupersets: Bool = false,
        context: TrainingContext? = nil,
        catalog: [ExerciseBrief]
    ) async -> WorkoutPlan {
        let count = exerciseCount

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                return try await generatePlanWithModel(
                    focusLabel: focusLabel,
                    targetMuscleGroups: targetMuscleGroups,
                    exerciseCount: count,
                    durationMinutes: durationMinutes,
                    withPartner: withPartner,
                    allowSupersets: allowSupersets,
                    context: context,
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
    /// Guided-generation shape the model fills in. Mirrors `CoachedPlan` /
    /// `CoachedExercise` field-for-field so the on-device tier returns the exact
    /// same structure as the cloud and self-hosted coaches — every plan reaches
    /// the UI through one `matchToCatalog` path and renders identically,
    /// whichever model answered. `@Guide` descriptions are kept in sync with
    /// `CloudWorkoutAI.planSchema` and `PromptBuilder.jsonOutputContract`.
    @available(iOS 26.0, *)
    @Generable
    struct GeneratedPlan {
        @Guide(description: "Short video-game-themed session name, 2 to 4 words.")
        var title: String
        @Guide(description: "At most two sentences to the lifter on what this session targets and which muscles were avoided.")
        var rationale: String
        @Guide(description: "The movements to perform, in the order they should be done — heaviest compounds first.")
        var exercises: [GeneratedExercise]

        /// The canonical DTO the whole app renders from. Bounds aren't enforced
        /// here — `matchToCatalog` clamps every field, exactly as it does for the
        /// cloud and self-hosted plans.
        var coachedPlan: CoachedPlan {
            CoachedPlan(
                title: title,
                rationale: rationale,
                exercises: exercises.map(\.coachedExercise)
            )
        }
    }

    @available(iOS 26.0, *)
    @Generable
    struct GeneratedExercise {
        @Guide(description: "Exact movement name, copied verbatim from the catalog.")
        var name: String
        @Guide(description: "Number of working sets, between 2 and 5.")
        var sets: Int
        @Guide(description: "Low end of the target rep range.")
        var repRangeLow: Int
        @Guide(description: "High end of the target rep range.")
        var repRangeHigh: Int
        @Guide(description: "Suggested working weight in pounds; 0 for unloaded bodyweight movements.")
        var targetLoadPounds: Double
        @Guide(description: "Rest between sets in seconds.")
        var restSeconds: Int
        @Guide(description: "One short sentence on why this movement is in the session.")
        var note: String
        @Guide(description: "Superset grouping index. Use 0 for a standalone movement, or 1, 2, … to pair exactly two adjacent complementary movements into a back-to-back superset (same number = same pair; never three or more).")
        var supersetGroup: Int

        var coachedExercise: CoachedExercise {
            CoachedExercise(
                name: name,
                sets: sets,
                repRangeLow: repRangeLow,
                repRangeHigh: repRangeHigh,
                targetLoadPounds: targetLoadPounds,
                restSeconds: restSeconds,
                note: note,
                supersetGroup: supersetGroup
            )
        }
    }

    @available(iOS 26.0, *)
    private static func generatePlanWithModel(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool,
        allowSupersets: Bool,
        context: TrainingContext?,
        catalog: [ExerciseBrief]
    ) async throws -> WorkoutPlan {
        // The same coaching instructions the cloud and self-hosted tiers use, so
        // all three models are held to one contract — full prescriptions, a
        // rationale, and catalog-only picks.
        let session = LanguageModelSession(instructions: PromptBuilder.coachInstructions)

        // With a training context the on-device model reads the identical request
        // block Claude and the self-hosted coach get — fatigue report, recorded
        // ceilings, and per-lift progression targets — so its loads are informed
        // rather than guessed. The compact budget keeps the prompt inside the
        // on-device window. Without a context (watch quick-generate, routine
        // editor) it gets an equivalent context-free request.
        let request: String
        if let context {
            request = PromptBuilder.requestBlock(
                focusLabel: focusLabel,
                targetMuscleGroups: targetMuscleGroups,
                exerciseCount: exerciseCount,
                durationMinutes: durationMinutes,
                context: context,
                allowSupersets: allowSupersets,
                budget: .compact
            )
        } else {
            request = onDeviceRequestBlock(
                focusLabel: focusLabel,
                exerciseCount: exerciseCount,
                durationMinutes: durationMinutes,
                withPartner: withPartner,
                allowSupersets: allowSupersets
            )
        }

        let prompt = "\(PromptBuilder.catalogBlock(catalog))\n\n\(request)"

        let response = try await session.respond(to: prompt, generating: GeneratedPlan.self)

        // Identical to the cloud/self-hosted path: map picks back to real catalog
        // entries, clamp every field, and trim to the requested slots.
        if let plan = matchToCatalog(response.content.coachedPlan, catalog: catalog, slots: exerciseCount, allowSupersets: allowSupersets, source: .onDevice) {
            return plan
        }
        return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: targetMuscleGroups, exerciseCount: exerciseCount, catalog: catalog)
    }

    /// The per-request block for the on-device tier when no `TrainingContext` is
    /// available (watch quick-generate, routine editor). Mirrors the tail of
    /// `PromptBuilder.requestBlock` so the model reads the same session
    /// instructions, minus the fatigue report and ceilings there's no data for.
    private static func onDeviceRequestBlock(
        focusLabel: String,
        exerciseCount: Int,
        durationMinutes: Int?,
        withPartner: Bool,
        allowSupersets: Bool
    ) -> String {
        var lines = ["THIS SESSION:", "- Focus: \(focusLabel)"]
        if allowSupersets {
            lines.append("- Select \(exerciseCount) movements as the core of the session. You may add "
                         + "one or two extra movements beyond that only when it completes a strong superset.")
            lines.append("- SUPERSETS ARE WANTED this session. Pair complementary movements — antagonists "
                         + "(a press with a row), or a compound with a non-competing accessory. A superset is "
                         + "exactly two movements; never put three or more in one. Use at most half as many "
                         + "supersets as movements requested so most of the session stays standalone. Give "
                         + "each pair the same supersetGroup index (1, 2, …), keep the two adjacent, and "
                         + "leave standalone movements at 0.")
        } else {
            lines.append("- Select exactly \(exerciseCount) movements.")
            lines.append("- Do not use supersets this session. Set supersetGroup to 0 for every movement.")
        }
        if let durationMinutes {
            lines.append("- Target length: about \(durationMinutes) minutes.")
        }
        lines.append(withPartner
            ? "- A training partner is present to spot, so heavy free-weight work is safe to program."
            : "- Training alone with no spotter — keep free-weight loads to what can be racked solo.")
        return lines.joined(separator: "\n")
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

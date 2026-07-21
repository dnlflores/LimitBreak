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

/// One exercise the AI (or fallback) chose for a generated workout.
struct PlannedExercise: Identifiable {
    let id = UUID()
    let name: String
    let sets: Int
}

/// A generated workout: a fun title plus an ordered list of exercises to run.
struct WorkoutPlan {
    let title: String
    let exercises: [PlannedExercise]
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
        catalog: [ExerciseBrief]
    ) async -> WorkoutPlan {
        let count = max(1, min(exerciseCount, catalog.count))

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                return try await generatePlanWithModel(
                    focusLabel: focusLabel,
                    exerciseCount: count,
                    durationMinutes: durationMinutes,
                    catalog: catalog
                )
            } catch {
                return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: targetMuscleGroups, exerciseCount: count, catalog: catalog)
            }
        }
        #endif
        return fallbackPlan(focusLabel: focusLabel, targetMuscleGroups: targetMuscleGroups, exerciseCount: count, catalog: catalog)
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
        catalog: [ExerciseBrief]
    ) async throws -> WorkoutPlan {
        let session = LanguageModelSession(instructions: """
            You are a strength coach for LimitBreak, an RPG-styled workout tracker. \
            Design a focused workout by selecting exercises from a fixed catalog. \
            Only ever use exercise names that appear verbatim in the catalog — never invent names. \
            Order the exercises sensibly, leading with the biggest compound movements. \
            Give the workout a short, fun, video-game-themed title.
            """)

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
        return WorkoutPlan(title: title, exercises: matched)
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
        return WorkoutPlan(title: fallbackName(), exercises: exercises)
    }
}

// MARK: - Shared generation config

/// A training focus the AI generator can target. Shared by the AI workout sheet
/// and the routine editor.
enum WorkoutFocus: String, CaseIterable, Identifiable {
    case fullBody, push, pull, legs, upper, core, arms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullBody: return "Full Body"
        case .push:     return "Push"
        case .pull:     return "Pull"
        case .legs:     return "Legs"
        case .upper:    return "Upper Body"
        case .core:     return "Core"
        case .arms:     return "Arms"
        }
    }

    var icon: String {
        switch self {
        case .fullBody: return "figure.mixed.cardio"
        case .push:     return "figure.strengthtraining.traditional"
        case .pull:     return "figure.rower"
        case .legs:     return "figure.run"
        case .upper:    return "figure.arms.open"
        case .core:     return "figure.core.training"
        case .arms:     return "dumbbell.fill"
        }
    }

    /// Muscle group raw values this focus targets. Empty means "everything".
    var targetMuscleGroups: [String] {
        switch self {
        case .fullBody: return []
        case .push:     return ["Chest", "Deltoids", "Triceps"]
        case .pull:     return ["Lats", "Biceps", "Forearms"]
        case .legs:     return ["Quads", "Hamstrings", "Glutes", "Calves"]
        case .upper:    return ["Chest", "Lats", "Deltoids", "Biceps", "Triceps"]
        case .core:     return ["Core"]
        case .arms:     return ["Biceps", "Triceps", "Forearms"]
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

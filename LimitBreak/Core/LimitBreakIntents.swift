import AppIntents
import Foundation
import SwiftData

// MARK: - Shared schema

/// The full SwiftData schema, factored out so both the SwiftUI app and a cold
/// Siri/Shortcuts launch (which may run an intent before the app's normal
/// lifecycle) build an identical model container against the same on-disk store.
enum LimitBreakSchema {
    static let all = Schema([
        Exercise.self,
        WorkoutSession.self,
        ExerciseSet.self,
        PRRecord.self,
        Walk.self,
        Activity.self,
        Routine.self,
        RoutineItem.self,
        TrainingProfile.self,
        WeeklyPlan.self,
        PlannedDay.self,
    ])
}

// MARK: - Read-only stats provider

/// Read-only access to the training log for Siri and Shortcuts. The app hands
/// its live container to `injectedContainer` at launch; if an intent runs before
/// that happens (a cold voice invocation), a container is built on demand against
/// the same store. Every result is a plain `Sendable` value so the intents that
/// call in can format dialog off the main actor.
@MainActor
enum LimitBreakStats {
    /// Installed by `LimitBreakApp` at launch so intents reuse the live store.
    static var injectedContainer: ModelContainer?

    private static var resolvedContainer: ModelContainer? {
        if let injectedContainer { return injectedContainer }
        let built = try? ModelContainer(for: LimitBreakSchema.all)
        injectedContainer = built
        return built
    }

    private static var context: ModelContext? { resolvedContainer?.mainContext }

    // MARK: Level

    struct LevelStat: Sendable {
        let level: Int
        let rank: String
        let xpIntoLevel: Int
        let xpForNext: Int
        let totalXP: Int
        let streak: Int
    }

    /// The lifter's current level, rank, XP-into-level and active streak, replayed
    /// from the whole training log — the same numbers the Skill Matrix shows.
    static func level() -> LevelStat? {
        guard let context else { return nil }
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let records = (try? context.fetch(FetchDescriptor<PRRecord>())) ?? []
        let walks = (try? context.fetch(FetchDescriptor<Walk>())) ?? []
        let activities = (try? context.fetch(FetchDescriptor<Activity>())) ?? []
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []

        let progress = XPEngine.progress(
            sessions: sessions, records: records, walks: walks,
            activities: activities, routines: routines,
            stepGoalDays: StepGoalStore.achievedDays()
        )
        let info = XPEngine.levelInfo(totalXP: progress.totalXP)
        return LevelStat(
            level: info.level,
            rank: XPEngine.rankTitle(for: info.level),
            xpIntoLevel: info.xpIntoLevel,
            xpForNext: info.xpForNext,
            totalXP: info.totalXP,
            streak: progress.currentStreak
        )
    }

    // MARK: Last workout

    struct WorkoutStat: Sendable {
        let name: String
        let date: Date
        let durationMinutes: Int
        let exerciseCount: Int
        let setCount: Int
        let volume: Double
        let prCount: Int
    }

    /// The most recently finished workout (an in-progress session is skipped).
    static func lastWorkout() -> WorkoutStat? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        guard let session = sessions.first(where: { $0.endDate != nil }) else { return nil }

        let working = session.sets.filter { !$0.isWarmup }
        return WorkoutStat(
            name: session.name,
            date: session.startDate,
            durationMinutes: max(1, Int((session.duration / 60).rounded())),
            exerciseCount: session.setsByExercise.count,
            setCount: working.count,
            volume: session.totalVolume,
            prCount: session.prCount
        )
    }

    // MARK: Last walk

    struct WalkStat: Sendable {
        let date: Date
        let miles: Double
        let durationMinutes: Int
    }

    /// The most recently logged walk.
    static func lastWalk() -> WalkStat? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Walk>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let walk = (try? context.fetch(descriptor))?.first else { return nil }
        return WalkStat(
            date: walk.date,
            miles: walk.distanceMiles,
            durationMinutes: max(1, Int((walk.effectiveDurationSeconds / 60).rounded()))
        )
    }

    // MARK: Last activity

    struct ActivityStat: Sendable {
        let sport: String
        let date: Date
        let durationMinutes: Int
    }

    /// The most recently logged non-lifting activity (basketball, a swim, …).
    static func lastActivity() -> ActivityStat? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Activity>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let activity = (try? context.fetch(descriptor))?.first else { return nil }
        return ActivityStat(
            sport: activity.sport.rawValue,
            date: activity.date,
            durationMinutes: activity.durationMinutes
        )
    }
}

// MARK: - Spoken-language helpers

/// A short, spoken-friendly day reference: "today", "yesterday", or a date.
private nonisolated func spokenDay(_ date: Date, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return "today" }
    if calendar.isDateInYesterday(date) { return "yesterday" }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return "on \(formatter.string(from: date))"
}

/// Grammatically-correct count phrase, e.g. `2 → "2 exercises"`, `1 → "1 exercise"`.
private nonisolated func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}

// MARK: - Intents

/// "What level am I?" — reports level, rank, XP progress and current streak.
struct CheckLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Check My Level"
    static let description = IntentDescription("Ask how far you've leveled up in LimitBreak.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stat = await LimitBreakStats.level(), stat.totalXP > 0 else {
            return .result(dialog: "You haven't earned any XP yet. Log a workout to start leveling up.")
        }
        var line = "You're Level \(stat.level), \(stat.rank). "
        line += "\(pluralized(stat.xpIntoLevel, "XP", "XP")) of \(stat.xpForNext) toward Level \(stat.level + 1)."
        if stat.streak > 0 {
            line += " You're on a \(pluralized(stat.streak, "day", "day")) streak."
        }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// "How was my last workout?" — duration, exercise count, set count, and PRs.
struct LastWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Workout Summary"
    static let description = IntentDescription("Ask how long your last workout was and how many exercises it had.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stat = await LimitBreakStats.lastWorkout() else {
            return .result(dialog: "You haven't logged a workout yet.")
        }
        let exercises = pluralized(stat.exerciseCount, "exercise", "exercises")
        let sets = pluralized(stat.setCount, "set", "sets")
        let minutes = pluralized(stat.durationMinutes, "minute", "minutes")
        var line = "Your last workout, \(stat.name), was \(minutes) with \(exercises) across \(sets), logged \(spokenDay(stat.date))."
        if stat.prCount > 0 {
            line += " You set \(pluralized(stat.prCount, "LimitBreak", "LimitBreaks"))."
        }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// "How far was my last walk?" — distance and duration.
struct LastWalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Walk Summary"
    static let description = IntentDescription("Ask how far and how long your last walk was.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stat = await LimitBreakStats.lastWalk() else {
            return .result(dialog: "You haven't logged a walk yet.")
        }
        let miles = String(format: "%.1f", stat.miles)
        let minutes = pluralized(stat.durationMinutes, "minute", "minutes")
        let line = "Your last walk covered \(miles) miles in \(minutes), \(spokenDay(stat.date))."
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// "How long was my last activity?" — sport and duration.
struct LastActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Activity Summary"
    static let description = IntentDescription("Ask how long your last logged sport or activity was.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stat = await LimitBreakStats.lastActivity() else {
            return .result(dialog: "You haven't logged an activity yet.")
        }
        let minutes = pluralized(stat.durationMinutes, "minute", "minutes")
        let line = "Your last activity was \(minutes) of \(stat.sport), \(spokenDay(stat.date))."
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

// MARK: - Siri phrases

/// Wires each intent to spoken phrases so "Hey Siri…" works without the user
/// configuring a Shortcut first. Every phrase must include `\(.applicationName)`.
struct LimitBreakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckLevelIntent(),
            phrases: [
                "What level am I in \(.applicationName)",
                "What's my level in \(.applicationName)",
                "Check my \(.applicationName) level",
                "What's my rank in \(.applicationName)",
            ],
            shortTitle: "My Level",
            systemImageName: "star.circle.fill"
        )
        AppShortcut(
            intent: LastWorkoutIntent(),
            phrases: [
                "How was my last workout in \(.applicationName)",
                "Tell me about my last \(.applicationName) workout",
                "How long was my last \(.applicationName) workout",
            ],
            shortTitle: "Last Workout",
            systemImageName: "dumbbell.fill"
        )
        AppShortcut(
            intent: LastWalkIntent(),
            phrases: [
                "How far was my last walk in \(.applicationName)",
                "How long was my last \(.applicationName) walk",
                "Tell me about my last \(.applicationName) walk",
            ],
            shortTitle: "Last Walk",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: LastActivityIntent(),
            phrases: [
                "How long was my last activity in \(.applicationName)",
                "Tell me about my last \(.applicationName) activity",
            ],
            shortTitle: "Last Activity",
            systemImageName: "sportscourt.fill"
        )
    }
}

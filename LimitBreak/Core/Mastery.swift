import Foundation
import SwiftUI

/// Per-workout mastery: the more a specific exercise or routine is trained, the
/// higher its mastery rank climbs, and every rank crossed pays bonus XP. Like
/// the level system, mastery is derived deterministically from the training log
/// — nothing is stored. A "completion" is *showing up*: doing the movement (or
/// the routine) in a session counts once, no matter how many sets.
enum Mastery {

    // MARK: - Icons & tint

    /// Individual movements rank up as a skill.
    static let exerciseIcon = "dumbbell.fill"
    /// A whole saved routine repeated is a bigger feat — trophy energy.
    static let routineIcon = "trophy.fill"

    static func tint(isRoutine: Bool) -> Color { isRoutine ? Theme.gold : Theme.violet }

    // MARK: - The ladder

    /// Completions that buy one mastery level. Every fifth time a movement is
    /// trained in a session, its skill ranks up — a fixed, predictable cadence.
    static let completionsPerLevel = 5

    /// XP paid out each time a mastery level is crossed. A routine pays double a
    /// single movement, since repeating a whole workout is the larger commitment.
    static let levelUpXP = 500

    /// Completions needed to *reach* a given mastery level (1-indexed). Fixed
    /// cadence — 5, 10, 15, 20 … — so LV N lands on the (5·N)th completion.
    /// Level 0 is "unranked".
    static func completions(toReachLevel level: Int) -> Int {
        guard level > 0 else { return 0 }
        return level * completionsPerLevel
    }

    /// The mastery level unlocked by `count` completions.
    static func level(forCompletions count: Int) -> Int {
        guard count > 0 else { return 0 }
        return count / completionsPerLevel
    }

    /// XP paid for reaching a mastery level — a flat bonus per rank so every
    /// fifth session of a movement lands a satisfying, predictable reward. A
    /// routine pays double, since repeating a whole workout is the larger feat.
    static func xp(forLevel level: Int, isRoutine: Bool) -> Int {
        guard level > 0 else { return 0 }
        return isRoutine ? levelUpXP * 2 : levelUpXP
    }

    /// Flavor rank name for a mastery level band.
    static func title(forLevel level: Int) -> String {
        switch level {
        case ..<1: "Unranked"
        case 1...2: "Practiced"
        case 3...4: "Skilled"
        case 5...6: "Seasoned"
        case 7...9: "Expert"
        case 10...13: "Master"
        default: "Grandmaster"
        }
    }

    // MARK: - Ranks (current standing)

    /// One workout's mastery standing — an exercise or a routine — ready to
    /// render as a card with a progress bar toward the next rank.
    struct Rank: Identifiable {
        enum Kind { case exercise, routine }

        let kind: Kind
        let id: UUID
        let name: String
        let completions: Int

        var isRoutine: Bool { kind == .routine }
        var level: Int { Mastery.level(forCompletions: completions) }
        var title: String { Mastery.title(forLevel: level) }
        var icon: String { isRoutine ? Mastery.routineIcon : Mastery.exerciseIcon }
        var tint: Color { Mastery.tint(isRoutine: isRoutine) }

        /// Completions banked toward the *current* level's floor.
        var completionsAtLevel: Int { Mastery.completions(toReachLevel: level) }
        /// Completions required to hit the next level.
        var completionsForNext: Int { Mastery.completions(toReachLevel: level + 1) }
        /// How many more completions until the next rank.
        var completionsRemaining: Int { max(0, completionsForNext - completions) }
        /// Fill of the bar toward the next rank, 0…1.
        var progress: Double {
            let span = completionsForNext - completionsAtLevel
            return span > 0 ? Double(completions - completionsAtLevel) / Double(span) : 0
        }
        /// XP waiting at the next rank.
        var nextLevelXP: Int { Mastery.xp(forLevel: level + 1, isRoutine: isRoutine) }
    }

    /// Mastery standing for every exercise trained at least once, best rank first.
    static func exerciseRanks(in sessions: [WorkoutSession]) -> [Rank] {
        exercisePerformances(in: sessions)
            .map { Rank(kind: .exercise, id: $0.exercise.id, name: $0.exercise.name, completions: $0.dates.count) }
            .sorted { rankOrder($0, $1) }
    }

    /// Mastery standing for every routine that has been run at least once.
    static func routineRanks(in sessions: [WorkoutSession], routines: [Routine]) -> [Rank] {
        let byID = Dictionary(routines.map { ($0.id, $0) }) { first, _ in first }
        return routinePerformances(in: sessions)
            .compactMap { entry -> Rank? in
                guard let routine = byID[entry.routineID] else { return nil }
                return Rank(kind: .routine, id: routine.id, name: routine.name, completions: entry.dates.count)
            }
            .sorted { rankOrder($0, $1) }
    }

    /// Highest rank first, then most completions, then name — a stable order for
    /// the dashboard so the deepest mastery floats to the top.
    private static func rankOrder(_ a: Rank, _ b: Rank) -> Bool {
        if a.level != b.level { return a.level > b.level }
        if a.completions != b.completions { return a.completions > b.completions }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: - Milestone rewards (folded into the XP feed)

    /// Every mastery rank-up in the log as a dated reward, so climbing a skill or
    /// routine feeds the level curve and the reward timeline like anything else.
    static func milestoneRewards(sessions: [WorkoutSession], routines: [Routine]) -> [XPEngine.Reward] {
        var rewards: [XPEngine.Reward] = []

        for perf in exercisePerformances(in: sessions) {
            rewards.append(contentsOf: levelUpRewards(dates: perf.dates, name: perf.exercise.name, isRoutine: false))
        }

        let byID = Dictionary(routines.map { ($0.id, $0) }) { first, _ in first }
        for entry in routinePerformances(in: sessions) {
            guard let routine = byID[entry.routineID] else { continue }
            rewards.append(contentsOf: levelUpRewards(dates: entry.dates, name: routine.name, isRoutine: true))
        }

        return rewards
    }

    /// Walk a workout's completion dates in order and emit a reward on each date
    /// that crossed into a new mastery level.
    private static func levelUpRewards(dates: [Date], name: String, isRoutine: Bool) -> [XPEngine.Reward] {
        let ordered = dates.sorted()
        var out: [XPEngine.Reward] = []
        for (index, date) in ordered.enumerated() {
            let count = index + 1
            let reached = level(forCompletions: count)
            guard reached > level(forCompletions: count - 1) else { continue }
            out.append(XPEngine.Reward(
                date: date,
                icon: isRoutine ? routineIcon : exerciseIcon,
                tint: tint(isRoutine: isRoutine),
                title: "\(title(forLevel: reached)) \(isRoutine ? "Routine" : "Skill")",
                detail: "\(name) mastery \u{2192} LV \(reached)",
                xp: xp(forLevel: reached, isRoutine: isRoutine)
            ))
        }
        return out
    }

    // MARK: - Performance counting

    /// Each exercise trained with real work, paired with the ascending list of
    /// session dates it appeared on. A movement counts once per session, and only
    /// when it carried at least one working (non-warmup) set.
    private static func exercisePerformances(in sessions: [WorkoutSession]) -> [(exercise: Exercise, dates: [Date])] {
        var order: [UUID] = []
        var buckets: [UUID: (exercise: Exercise, dates: [Date])] = [:]
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            var seen = Set<UUID>()
            for set in session.sets where !set.isWarmup {
                guard let exercise = set.exercise, seen.insert(exercise.id).inserted else { continue }
                if buckets[exercise.id] == nil {
                    order.append(exercise.id)
                    buckets[exercise.id] = (exercise, [])
                }
                buckets[exercise.id]?.dates.append(session.startDate)
            }
        }
        return order.compactMap { buckets[$0] }
    }

    /// Each routine that was run, paired with the ascending dates it was trained.
    /// A session counts only if it was started from the routine and logged real
    /// work (at least one set).
    private static func routinePerformances(in sessions: [WorkoutSession]) -> [(routineID: UUID, dates: [Date])] {
        var order: [UUID] = []
        var buckets: [UUID: [Date]] = [:]
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            guard let routineID = session.startedFromRoutineID, !session.sets.isEmpty else { continue }
            if buckets[routineID] == nil { order.append(routineID) }
            buckets[routineID, default: []].append(session.startDate)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

import Foundation
import SwiftUI

/// LimitBreak's leveling system. XP is derived deterministically from the
/// training log — no separate ledger to store or migrate:
///   +25 per session finished, +10 per working set, +3 per warmup,
///   +1 per 100 lbs of effective volume, +50 per LimitBreak, +15 per walk.
enum XPEngine {

    // MARK: - Awards

    static func xp(for session: WorkoutSession) -> Int {
        let working = session.sets.filter { !$0.isWarmup }
        let warmups = session.sets.count - working.count
        let volumeBonus = Int(session.totalVolume / 100)
        let prBonus = session.prCount * 50
        return 25 + working.count * 10 + warmups * 3 + volumeBonus + prBonus
    }

    static let walkXP = 15
    static let limitBreakXP = 50

    /// Activities score on time played: +10 for showing up, +1 per 2 minutes.
    static func xp(for activity: Activity) -> Int {
        xpForActivity(minutes: activity.durationMinutes)
    }

    static func xpForActivity(minutes: Int) -> Int {
        10 + max(0, minutes) / 2
    }

    // MARK: - Levels

    /// XP needed to climb from `level` to the next one — grows linearly, so
    /// total XP to reach high levels grows quadratically.
    static func cost(ofLevel level: Int) -> Int {
        100 + 50 * level
    }

    struct LevelInfo {
        let level: Int
        let xpIntoLevel: Int
        let xpForNext: Int
        let totalXP: Int

        var progress: Double {
            xpForNext > 0 ? Double(xpIntoLevel) / Double(xpForNext) : 0
        }
    }

    static func levelInfo(totalXP: Int) -> LevelInfo {
        var level = 1
        var remaining = totalXP
        while remaining >= cost(ofLevel: level) {
            remaining -= cost(ofLevel: level)
            level += 1
        }
        return LevelInfo(level: level, xpIntoLevel: remaining, xpForNext: cost(ofLevel: level), totalXP: totalXP)
    }

    /// RPG rank for a level — the flavor text of progression.
    static func rankTitle(for level: Int) -> String {
        switch level {
        case ..<3: "Novice"
        case 3..<6: "Squire"
        case 6..<10: "Adventurer"
        case 10..<15: "Warrior"
        case 15..<20: "Berserker"
        case 20..<27: "Champion"
        case 27..<35: "Warlord"
        case 35..<45: "Titan"
        default: "Raid Boss"
        }
    }

    // MARK: - Aggregates

    static func totalXP(sessions: [WorkoutSession], walks: [Walk], activities: [Activity] = []) -> Int {
        sessions.reduce(0) { $0 + xp(for: $1) }
            + walks.count * walkXP
            + activities.reduce(0) { $0 + xp(for: $1) }
    }

    static func weeklyXP(sessions: [WorkoutSession], walks: [Walk], activities: [Activity] = [], now: Date = Date()) -> Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let sessionXP = sessions.filter { $0.startDate >= weekAgo }.reduce(0) { $0 + xp(for: $1) }
        let walkXPTotal = walks.filter { $0.date >= weekAgo }.count * walkXP
        let activityXP = activities.filter { $0.date >= weekAgo }.reduce(0) { $0 + xp(for: $1) }
        return sessionXP + walkXPTotal + activityXP
    }

    // MARK: - Rewards feed

    struct Reward: Identifiable {
        let id = UUID()
        let date: Date
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let xp: Int
    }

    /// Every earning in the log, unsorted: LimitBreaks, finished quests,
    /// walks, and activities.
    static func allRewards(
        sessions: [WorkoutSession],
        records: [PRRecord],
        walks: [Walk],
        activities: [Activity] = []
    ) -> [Reward] {
        var rewards: [Reward] = []

        for record in records {
            rewards.append(Reward(
                date: record.dateAchieved,
                icon: "crown.fill",
                tint: Theme.gold,
                title: "LimitBreak",
                detail: "\(record.exercise?.name ?? "Unknown") \(record.recordType) \(record.numericValue.cleanWeight)",
                xp: limitBreakXP
            ))
        }
        for session in sessions {
            rewards.append(Reward(
                date: session.startDate,
                icon: "flag.checkered",
                tint: Theme.emerald,
                title: "Quest complete",
                detail: session.name,
                xp: xp(for: session) - session.prCount * limitBreakXP
            ))
        }
        for walk in walks {
            rewards.append(Reward(
                date: walk.date,
                icon: "figure.walk",
                tint: Theme.teal,
                title: "Side quest",
                detail: "Walk logged",
                xp: walkXP
            ))
        }
        for activity in activities {
            rewards.append(Reward(
                date: activity.date,
                icon: activity.sport.icon,
                tint: Theme.coral,
                title: activity.sport.rawValue,
                detail: "\(activity.durationMinutes) min played",
                xp: xp(for: activity)
            ))
        }

        return rewards
    }

    /// Recent earnings, newest first.
    static func recentRewards(
        sessions: [WorkoutSession],
        records: [PRRecord],
        walks: [Walk],
        activities: [Activity] = [],
        limit: Int = 6
    ) -> [Reward] {
        Array(
            allRewards(sessions: sessions, records: records, walks: walks, activities: activities)
                .sorted { $0.date > $1.date }
                .prefix(limit)
        )
    }

    // MARK: - Timeline

    struct TimelineEvent: Identifiable {
        let id = UUID()
        let date: Date
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let xp: Int
        let levelReached: Int?

        var isLevelUp: Bool { levelReached != nil }
    }

    struct TimelineDay: Identifiable {
        let day: Date
        let events: [TimelineEvent]

        var id: Date { day }
        var dayXP: Int { events.reduce(0) { $0 + $1.xp } }
    }

    /// The full progression story, newest day first: every reward in
    /// chronological context, with LEVEL UP milestones inserted on the day
    /// the XP total crossed each threshold.
    static func timeline(
        sessions: [WorkoutSession],
        records: [PRRecord],
        walks: [Walk],
        activities: [Activity] = []
    ) -> [TimelineDay] {
        let rewards = allRewards(sessions: sessions, records: records, walks: walks, activities: activities)
            .sorted { $0.date < $1.date }

        var events: [TimelineEvent] = []
        var runningXP = 0
        var level = 1

        for reward in rewards {
            runningXP += reward.xp
            events.append(TimelineEvent(
                date: reward.date,
                icon: reward.icon,
                tint: reward.tint,
                title: reward.title,
                detail: reward.detail,
                xp: reward.xp,
                levelReached: nil
            ))
            let newLevel = levelInfo(totalXP: runningXP).level
            if newLevel > level {
                level = newLevel
                events.append(TimelineEvent(
                    date: reward.date,
                    icon: "star.circle.fill",
                    tint: Theme.violet,
                    title: "LEVEL UP",
                    detail: "Reached LV \(newLevel) \u{2014} \(rankTitle(for: newLevel))",
                    xp: 0,
                    levelReached: newLevel
                ))
            }
        }

        let calendar = Calendar.current
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return byDay
            .map { TimelineDay(day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

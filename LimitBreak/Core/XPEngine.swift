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

    /// Activities score on time played, at parity with a lifting session.
    static func xp(for activity: Activity) -> Int {
        xpForActivity(minutes: activity.durationMinutes)
    }

    /// Tuned so an hour of sport pays like an hour of lifting: a solid gym
    /// session (~20 working sets plus volume) lands around 400-500 XP, so
    /// activities earn the session-completion base plus 7 XP per minute —
    /// 445 for an hour of basketball, 865 for two.
    static func xpForActivity(minutes: Int) -> Int {
        25 + max(0, minutes) * 7
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

    /// The next rank above this level and the level that unlocks it,
    /// or nil at the top of the ladder.
    static func nextRank(after level: Int) -> (title: String, level: Int)? {
        let current = rankTitle(for: level)
        var candidate = level + 1
        while candidate <= 45 {
            let title = rankTitle(for: candidate)
            if title != current { return (title, candidate) }
            candidate += 1
        }
        return nil
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

    // MARK: - Streak multipliers & idle decay

    /// Two rest days are free; every idle day beyond that docks XP (no
    /// multiplier on losses — decay is flat).
    static let idleGraceDays = 2
    static let idleDecayPerDay = 10

    /// Every full week of unbroken daily activity adds +1× to all XP earned:
    /// days 1-6 pay 1×, days 7-13 pay 2×, days 14-20 pay 3×, and so on.
    static func multiplier(forStreakDay streakDay: Int) -> Int {
        1 + max(0, streakDay) / 7
    }

    /// One day in the replayed XP ledger.
    struct LedgerDay {
        let day: Date
        let baseXP: Int
        let multiplier: Int
        let penalty: Int
        let streakLength: Int

        var earnedXP: Int { baseXP * multiplier }
        var delta: Int { earnedXP - penalty }
    }

    /// The fully replayed progression: day-by-day ledger with streak
    /// multipliers applied and idle decay subtracted (floored at zero).
    struct Progress {
        let ledger: [LedgerDay]
        let totalXP: Int
        let weeklyXP: Int
        let currentStreak: Int
        let currentMultiplier: Int
        /// Multiplier in force on each active day — for scaling displayed rewards.
        let multipliers: [Date: Int]

        static let empty = Progress(
            ledger: [], totalXP: 0, weeklyXP: 0,
            currentStreak: 0, currentMultiplier: 1, multipliers: [:]
        )
    }

    // MARK: - Aggregates

    static func progress(
        sessions: [WorkoutSession],
        records: [PRRecord] = [],
        walks: [Walk],
        activities: [Activity] = [],
        now: Date = Date()
    ) -> Progress {
        let rewards = allRewards(sessions: sessions, records: records, walks: walks, activities: activities)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: rewards) { calendar.startOfDay(for: $0.date) }
        guard let firstDay = byDay.keys.min(), firstDay <= today else { return .empty }

        var ledger: [LedgerDay] = []
        var multipliers: [Date: Int] = [:]
        var total = 0
        var streak = 0
        var lastActiveStreak = 0
        var idleRun = 0

        var day = firstDay
        while day <= today {
            let base = (byDay[day] ?? []).reduce(0) { $0 + $1.xp }
            if base > 0 {
                streak += 1
                lastActiveStreak = streak
                idleRun = 0
                let mult = multiplier(forStreakDay: streak)
                multipliers[day] = mult
                total += base * mult
                ledger.append(LedgerDay(day: day, baseXP: base, multiplier: mult, penalty: 0, streakLength: streak))
            } else {
                idleRun += 1
                streak = 0
                if idleRun > idleGraceDays {
                    let penalty = min(idleDecayPerDay, total) // never below zero
                    total -= penalty
                    if penalty > 0 {
                        ledger.append(LedgerDay(day: day, baseXP: 0, multiplier: 1, penalty: penalty, streakLength: 0))
                    }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        // A streak survives one quiet day: today untrained still shows
        // yesterday's run (matching the streak tile's semantics).
        let currentStreak = idleRun <= 1 ? lastActiveStreak : 0
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let weekly = ledger.filter { $0.day >= weekStart }.reduce(0) { $0 + $1.delta }

        return Progress(
            ledger: ledger,
            totalXP: total,
            weeklyXP: weekly,
            currentStreak: currentStreak,
            currentMultiplier: multiplier(forStreakDay: currentStreak),
            multipliers: multipliers
        )
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

    /// Recent earnings, newest first. Pass the progress multipliers so each
    /// reward shows what it actually paid under its day's streak bonus.
    static func recentRewards(
        sessions: [WorkoutSession],
        records: [PRRecord],
        walks: [Walk],
        activities: [Activity] = [],
        multipliers: [Date: Int] = [:],
        limit: Int = 6
    ) -> [Reward] {
        let calendar = Calendar.current
        return Array(
            allRewards(sessions: sessions, records: records, walks: walks, activities: activities)
                .sorted { $0.date > $1.date }
                .prefix(limit)
                .map { reward in
                    let mult = multipliers[calendar.startOfDay(for: reward.date)] ?? 1
                    guard mult > 1 else { return reward }
                    return Reward(
                        date: reward.date, icon: reward.icon, tint: reward.tint,
                        title: reward.title, detail: reward.detail, xp: reward.xp * mult
                    )
                }
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
        var isLevelDown = false

        var isLevelUp: Bool { levelReached != nil }
    }

    struct TimelineDay: Identifiable {
        let day: Date
        let events: [TimelineEvent]

        var id: Date { day }
        var dayXP: Int { events.reduce(0) { $0 + $1.xp } }
    }

    /// The full progression story, newest day first: rewards scaled by their
    /// day's streak multiplier, idle-decay entries on penalized days, and
    /// LEVEL UP / LEVEL LOST milestones where the running total crossed a
    /// threshold in either direction.
    static func timeline(
        sessions: [WorkoutSession],
        records: [PRRecord],
        walks: [Walk],
        activities: [Activity] = [],
        now: Date = Date()
    ) -> [TimelineDay] {
        let prog = progress(sessions: sessions, records: records, walks: walks, activities: activities, now: now)
        let calendar = Calendar.current
        let rewardsByDay = Dictionary(
            grouping: allRewards(sessions: sessions, records: records, walks: walks, activities: activities)
        ) { calendar.startOfDay(for: $0.date) }

        var events: [TimelineEvent] = []
        var runningXP = 0
        var level = 1

        func checkLevel(at date: Date) {
            let newLevel = levelInfo(totalXP: max(0, runningXP)).level
            guard newLevel != level else { return }
            let climbed = newLevel > level
            level = newLevel
            events.append(TimelineEvent(
                date: date,
                icon: climbed ? "star.circle.fill" : "arrowtriangle.down.circle.fill",
                tint: climbed ? Theme.violet : Theme.crimson,
                title: climbed ? "LEVEL UP" : "LEVEL LOST",
                detail: climbed
                    ? "Reached LV \(newLevel) \u{2014} \(rankTitle(for: newLevel))"
                    : "Dropped to LV \(newLevel) \u{2014} \(rankTitle(for: newLevel))",
                xp: 0,
                levelReached: newLevel,
                isLevelDown: !climbed
            ))
        }

        for ledgerDay in prog.ledger {
            if ledgerDay.penalty > 0 {
                runningXP -= ledgerDay.penalty
                events.append(TimelineEvent(
                    date: ledgerDay.day,
                    icon: "moon.zzz.fill",
                    tint: Theme.crimson,
                    title: "Inactivity",
                    detail: "Idle decay",
                    xp: -ledgerDay.penalty,
                    levelReached: nil
                ))
                checkLevel(at: ledgerDay.day)
            } else {
                let dayRewards = (rewardsByDay[ledgerDay.day] ?? []).sorted { $0.date < $1.date }
                for reward in dayRewards {
                    let scaled = reward.xp * ledgerDay.multiplier
                    runningXP += scaled
                    events.append(TimelineEvent(
                        date: reward.date,
                        icon: reward.icon,
                        tint: reward.tint,
                        title: ledgerDay.multiplier > 1
                            ? "\(reward.title) \u{00D7}\(ledgerDay.multiplier)"
                            : reward.title,
                        detail: reward.detail,
                        xp: scaled,
                        levelReached: nil
                    ))
                    checkLevel(at: reward.date)
                }
            }
        }

        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return byDay
            .map { TimelineDay(day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

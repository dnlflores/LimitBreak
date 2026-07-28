import Foundation
import SwiftData
import WidgetKit

/// Publishes ambient training stats to the app group for home-screen widgets,
/// and asks WidgetKit to redraw whenever the numbers move.
@MainActor
final class WidgetSnapshotter {
    static let shared = WidgetSnapshotter()

    private var context: ModelContext?

    private init() {}

    func configure(context: ModelContext) {
        self.context = context
    }

    /// Days of history published for the matrix grids (16 weeks).
    private let historyDays = 112

    func refresh() {
        guard let context else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let records = (try? context.fetch(FetchDescriptor<PRRecord>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let walks = (try? context.fetch(FetchDescriptor<Walk>())) ?? []
        let activities = (try? context.fetch(FetchDescriptor<Activity>())) ?? []

        // Per-day activity level, oldest first, ending today. Any qualifying
        // activity — session, sport, or a walk over a mile — lights a day.
        var levels: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            let level = session.prCount > 0 ? 2 : 1
            levels[day] = max(levels[day] ?? 0, level)
        }
        for activity in activities {
            let day = calendar.startOfDay(for: activity.date)
            levels[day] = max(levels[day] ?? 0, 1)
        }
        for walk in walks where walk.distanceMiles >= XPEngine.streakWalkMinimumMiles {
            let day = calendar.startOfDay(for: walk.date)
            levels[day] = max(levels[day] ?? 0, 1)
        }
        let dayActivity: [Int] = (0..<historyDays).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return levels[day] ?? 0
        }

        let topRecords = exercises
            .compactMap { exercise -> WidgetSnapshot.TopRecord? in
                let ceiling = exercise.ceiling(for: "1RM")
                guard ceiling > 0 else { return nil }
                return WidgetSnapshot.TopRecord(name: exercise.name, value: ceiling, unit: "lbs")
            }
            .sorted { $0.value > $1.value }
            .prefix(3)

        // Full XP progression — the single source of truth for level and the
        // XP earned over the trailing week.
        let progress = XPEngine.progress(
            sessions: sessions, records: records, walks: walks, activities: activities
        )
        let level = XPEngine.levelInfo(totalXP: progress.totalXP).level

        let snapshot = WidgetSnapshot(
            dayActivity: dayActivity,
            streakDays: XPEngine.currentStreak(sessions: sessions, walks: walks, activities: activities),
            weeklyVolume: sessions.filter { $0.startDate >= weekAgo }.reduce(0) { $0 + $1.totalVolume },
            weeklyPRs: records.filter { $0.dateAchieved >= weekAgo }.count,
            totalLimitBreaks: records.count,
            topRecords: Array(topRecords),
            generatedAt: Date(),
            level: level,
            rankTitle: XPEngine.rankTitle(for: level),
            weeklyXP: progress.weeklyXP
        )

        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

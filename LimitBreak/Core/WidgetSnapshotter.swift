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

        // Per-day activity level, oldest first, ending today.
        var levels: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            let level = session.prCount > 0 ? 2 : 1
            levels[day] = max(levels[day] ?? 0, level)
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

        let snapshot = WidgetSnapshot(
            dayActivity: dayActivity,
            streakDays: NarrativeEngine.currentStreak(context: context),
            weeklyVolume: sessions.filter { $0.startDate >= weekAgo }.reduce(0) { $0 + $1.totalVolume },
            weeklyPRs: records.filter { $0.dateAchieved >= weekAgo }.count,
            totalLimitBreaks: records.count,
            topRecords: Array(topRecords),
            generatedAt: Date()
        )

        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

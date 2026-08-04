import Foundation

/// The daily-steps goal mechanic. Steps are device-local health data, so goal
/// progress and achievement history live in app-group UserDefaults (shared with
/// the widget, and mirrored to the watch via the state snapshot) rather than the
/// CloudKit-backed SwiftData store.
enum StepGoals {
    /// Steps that count as reaching the goal for the day.
    static let dailyGoal = 10_000
    /// Bonus XP awarded the first time the goal is reached each day — parity with
    /// a LimitBreak, so a full day on your feet pays like shattering a ceiling.
    static let bonusXP = 50
    /// Hour of day (24h) for the "you haven't hit your goal yet" nudge.
    static let reminderHour = 19
}

/// App-group backed record of today's step count and the days the goal was met.
enum StepGoalStore {
    private static let appGroupID = "group.testing.app.LimitBreak"
    private static let stepsKey = "stepGoal.todaySteps"
    private static let stepsDayKey = "stepGoal.todayStepsDay"
    private static let achievedKey = "stepGoal.achievedDays"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    // MARK: - Today's steps

    /// Records the latest step count read from Health, stamped with today's date
    /// so a stale value from yesterday never leaks into today's surfaces.
    static func setToday(steps: Double) {
        guard let defaults else { return }
        defaults.set(steps, forKey: stepsKey)
        defaults.set(dayStamp(for: Date()), forKey: stepsDayKey)
    }

    /// Today's recorded steps, or nil if nothing has been recorded for today yet.
    static func todaySteps() -> Double? {
        guard let defaults, defaults.object(forKey: stepsKey) != nil,
              defaults.double(forKey: stepsDayKey) == dayStamp(for: Date()) else { return nil }
        return defaults.double(forKey: stepsKey)
    }

    // MARK: - Goal achievements

    /// The set of start-of-day dates on which the step goal was reached.
    static func achievedDays() -> Set<Date> {
        guard let defaults,
              let stamps = defaults.array(forKey: achievedKey) as? [Double] else { return [] }
        return Set(stamps.map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    static func hasAchieved(_ day: Date = Date()) -> Bool {
        achievedDays().contains(Calendar.current.startOfDay(for: day))
    }

    /// Marks the goal reached for the given day. Idempotent — a day is only ever
    /// recorded once, so callers can safely check-and-mark on every step update.
    /// Returns true only on the first mark for that day (the moment to celebrate).
    @discardableResult
    static func markAchieved(_ day: Date = Date()) -> Bool {
        guard let defaults else { return false }
        let start = Calendar.current.startOfDay(for: day)
        var days = achievedDays()
        guard days.insert(start).inserted else { return false }
        // Keep the list bounded — a year-plus of history is plenty for the feed.
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: start) ?? start
        defaults.set(days.filter { $0 >= cutoff }.map(\.timeIntervalSinceReferenceDate), forKey: achievedKey)
        return true
    }

    private static func dayStamp(for date: Date) -> Double {
        Calendar.current.startOfDay(for: date).timeIntervalSinceReferenceDate
    }
}

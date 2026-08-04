import Foundation
import SwiftData
import UserNotifications

/// Watches the daily step count and drives the 10k goal loop: awards the bonus
/// XP and a congrats notification the first time the goal falls each day, and
/// schedules a 7pm "you're not there yet" nudge while it's still short.
///
/// Detection rides on HealthKit background delivery (registered in
/// `HealthKitManager`), which wakes the app roughly hourly — so the reward lands
/// within the hour of crossing 10k, or the instant the app is next opened.
@MainActor
final class StepGoalMonitor: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StepGoalMonitor()

    private let center = UNUserNotificationCenter.current()
    private static let congratsID = "stepgoal.congrats"
    private static let reminderID = "stepgoal.reminder"
    private static let streakReminderID = "streak.reminder"

    /// Read access to the training log, for the streak check. Set at launch.
    private var context: ModelContext?

    private override init() { super.init() }

    // MARK: - Setup

    /// Asks for permission to post the goal notifications. Safe to call at launch.
    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Hands the monitor the model context it uses to evaluate the day streak.
    func configure(context: ModelContext) {
        self.context = context
    }

    /// Arms background step monitoring and does an immediate check. Idempotent —
    /// call at launch, on foreground, and after Health is connected.
    func start() {
        HealthKitManager.shared.startStepMonitoring { [weak self] in
            await self?.evaluate()
        }
        Task { await evaluate() }
    }

    // MARK: - The goal loop

    /// Refreshes today's steps, awards the goal the first time it's reached, and
    /// keeps the 7pm reminder in sync. Cheap enough to run on every wake.
    func evaluate() async {
        await HealthKitManager.shared.refreshTodayStats()
        let steps = StepGoalStore.todaySteps() ?? 0

        if steps >= Double(StepGoals.dailyGoal) {
            let firstTimeToday = StepGoalStore.markAchieved()
            cancelReminder()
            if firstTimeToday { postGoalReached() }
        } else {
            scheduleReminderIfNeeded()
        }

        // Keep the day-streak nudge in sync with the training log.
        refreshStreakReminder()

        // Keep the widget and watch snapshot in step with the latest count.
        WidgetSnapshotter.shared.refresh()
        if let manager = WorkoutManager.shared {
            PhoneWatchBridge.shared.push(state: SessionSync.shared.snapshot(from: manager))
        }
    }

    // MARK: - Day-streak reminder

    /// Arms a 7pm "don't break the chain" nudge when a running streak hasn't been
    /// secured today, and clears it the moment today qualifies. Call after any
    /// event that could keep the streak alive (session, walk, sport) so a
    /// still-open app cancels the reminder promptly.
    func refreshStreakReminder() {
        guard let context else { return }
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let walks = (try? context.fetch(FetchDescriptor<Walk>())) ?? []
        let activities = (try? context.fetch(FetchDescriptor<Activity>())) ?? []

        let today = Calendar.current.startOfDay(for: Date())
        let securedToday = XPEngine
            .qualifyingStreakDays(sessions: sessions, walks: walks, activities: activities)
            .contains(today)
        let streak = XPEngine.currentStreak(sessions: sessions, walks: walks, activities: activities)

        // Only nudge when there's a streak to lose and today isn't locked in yet.
        guard streak > 0, !securedToday else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.streakReminderID])
            return
        }
        scheduleStreakReminder(streak: streak)
    }

    private func scheduleStreakReminder(streak: Int) {
        let calendar = Calendar.current
        guard let fireDate = calendar.date(
                bySettingHour: StepGoals.reminderHour, minute: 0, second: 0, of: Date()),
              fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Don't Break the Chain 🔥"
        content.body = "Your \(streak)-day streak is on the line. A session, a sport, or a mile-plus walk keeps it alive."
        content.sound = .default

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.streakReminderID, content: content, trigger: trigger))
    }

    // MARK: - Notifications

    private func postGoalReached() {
        let content = UNMutableNotificationContent()
        content.title = "Goal Smashed! 🎉"
        content.body = "You hit \(StepGoals.dailyGoal.formatted()) steps today — +\(StepGoals.bonusXP) XP banked."
        content.sound = .default
        // A nil trigger delivers immediately.
        center.add(UNNotificationRequest(identifier: Self.congratsID, content: content, trigger: nil))
    }

    /// Arms (or replaces) a one-shot reminder for today's 7pm, but only while the
    /// goal is still unmet and 7pm hasn't passed. Adding with the same identifier
    /// replaces any pending copy, so re-arming on every wake is harmless.
    private func scheduleReminderIfNeeded() {
        guard !StepGoalStore.hasAchieved() else { cancelReminder(); return }
        let calendar = Calendar.current
        guard let fireDate = calendar.date(
                bySettingHour: StepGoals.reminderHour, minute: 0, second: 0, of: Date()),
              fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Finish Strong 🥾"
        content.body = "You're not at \(StepGoals.dailyGoal.formatted()) steps yet. A short walk gets you there — and +\(StepGoals.bonusXP) XP."
        content.sound = .default

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger))
    }

    private func cancelReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when the app is in the foreground (e.g. the goal was
    /// crossed while the lifter had the app open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

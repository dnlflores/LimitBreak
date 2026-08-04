import Foundation

// Shared between the iOS app (writer) and the widget extension (reader).

/// Compact step formatting, shared by the phone tile and the widgets so they
/// read identically. Thousands are truncated (never rounded up) to a single
/// decimal — 10,690 → "10.6K", 11,000 → "11K" — while sub-1000 counts stay whole.
enum StepFormat {
    static func compact(_ steps: Double) -> String {
        guard steps >= 1000 else { return Int(steps).formatted() }
        // Truncate toward zero at the tenths place so .5+ never rounds up.
        let thousands = (steps / 100).rounded(.down) / 10
        return "\(thousands.formatted(.number.precision(.fractionLength(0...1))))K"
    }
}

/// Ambient training stats the app publishes for home-screen widgets.
struct WidgetSnapshot: Codable {
    /// Activity level per day, most recent LAST, covering `dayActivity.count`
    /// consecutive days ending today. 0 = dormant, 1 = trained, 2 = LimitBreak.
    var dayActivity: [Int]
    var streakDays: Int
    var weeklyVolume: Double
    var weeklyPRs: Int
    var totalLimitBreaks: Int
    var topRecords: [TopRecord]
    var generatedAt: Date
    /// Current level, its RPG rank title, and XP earned in the last 7 days.
    var level: Int
    var rankTitle: String
    var weeklyXP: Int
    /// Today's step count against the daily goal.
    var todaySteps: Double
    var stepGoal: Int

    struct TopRecord: Codable, Identifiable, Hashable {
        var name: String
        var value: Double
        var unit: String
        var id: String { name }
    }

    static let placeholder = WidgetSnapshot(
        dayActivity: (0..<112).map { index in
            switch index % 7 {
            case 1, 3: return 1
            case 5: return index % 3 == 0 ? 2 : 1
            default: return 0
            }
        },
        streakDays: 5,
        weeklyVolume: 18_200,
        weeklyPRs: 3,
        totalLimitBreaks: 24,
        topRecords: [
            TopRecord(name: "Deadlift", value: 405, unit: "lbs"),
            TopRecord(name: "Barbell Back Squat", value: 315, unit: "lbs"),
            TopRecord(name: "Barbell Bench Press", value: 245, unit: "lbs"),
        ],
        generatedAt: Date(),
        level: 8,
        rankTitle: "Adventurer",
        weeklyXP: 2_450,
        todaySteps: 7_240,
        stepGoal: 10_000
    )
}

/// App-group backed storage for the snapshot.
enum WidgetSnapshotStore {
    static let appGroupID = "group.testing.app.LimitBreak"
    private static let key = "widgetSnapshot"

    static func save(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

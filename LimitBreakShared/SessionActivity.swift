#if canImport(ActivityKit)
import ActivityKit
import AppIntents
import Foundation

// Compiled into the iOS app AND the widget extension (not watchOS).

nonisolated struct SessionActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var exerciseName: String
        var exerciseDone: Int
        var exerciseTarget: Int
        var totalDone: Int
        var totalTarget: Int
        var totalVolume: Double
        var restEndsAt: Date?
        var isComplete: Bool
    }

    var sessionName: String
}

/// Bridges intents (compiled into both app and widget) to the app's
/// WorkoutManager. Only the app process installs handlers; LiveActivityIntent
/// always performs in the app process, so the hooks are present when needed.
enum SessionCommandHub {
    static var logNextSet: (() async -> Void)?
}

/// The Live Activity's LOG SET button: checks off the next planned set,
/// in exercise order — same semantics as the watch app.
struct LogNextSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log Next Set"
    static let description = IntentDescription("Logs the next planned set of the active LimitBreak session.")

    func perform() async throws -> some IntentResult {
        await SessionCommandHub.logNextSet?()
        return .result()
    }
}
#endif

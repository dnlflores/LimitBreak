import SwiftUI

// Shared between the iPhone app, the watch app, and the widget extension.
// All encode/decode happens on the main actor on both ends.

// MARK: - Commands (watch → phone)

enum WatchCommandKind: String, Codable {
    case requestState
    case startRoutine
    case startAIWorkout
    case logNextSet
    case nextExercise
    case endSession
}

struct WatchCommand: Codable {
    var kind: WatchCommandKind
    var routineID: UUID?

    init(kind: WatchCommandKind, routineID: UUID? = nil) {
        self.kind = kind
        self.routineID = routineID
    }
}

// MARK: - State (phone → watch)

struct WatchExerciseSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var muscle: String
    var done: Int
    var target: Int
    /// Human summary of what LOG SET will record next, e.g. "185 lbs × 8".
    var nextLabel: String
    var isSkipped: Bool
}

struct WatchStateSnapshot: Codable {
    var isActive: Bool
    var sessionName: String
    var exercises: [WatchExerciseSnapshot]
    var currentExerciseID: UUID?
    var restEndsAt: Date?
    var totalVolume: Double
    var prCount: Int

    static let idle = WatchStateSnapshot(
        isActive: false, sessionName: "", exercises: [],
        currentExerciseID: nil, restEndsAt: nil, totalVolume: 0, prCount: 0
    )
}

struct WatchRoutineSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var exerciseCount: Int
    var isAIGenerated: Bool
}

// MARK: - Wire helpers

enum WatchLink {
    static let stateKey = "state"
    static let routinesKey = "routines"
    static let commandKey = "command"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Shared palette (widget + watch can't see the app's Theme)

enum LBColor {
    static let background = Color(red: 0.043, green: 0.055, blue: 0.078)
    static let emerald = Color(red: 0.20, green: 0.84, blue: 0.50)
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let violet = Color(red: 0.58, green: 0.40, blue: 1.0)
    static let teal = Color(red: 0.16, green: 0.86, blue: 0.82)
    static let dim = Color.white.opacity(0.55)

    static let limitBreakGradient = LinearGradient(
        colors: [gold, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

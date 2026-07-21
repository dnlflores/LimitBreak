import Foundation
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Weekly telemetry snapshot fed to the narrative generator.
struct WeeklyTelemetry {
    var sessionCount: Int = 0
    var setCount: Int = 0
    var totalVolume: Double = 0
    var prCount: Int = 0
    var streakDays: Int = 0
    var topRecords: [(exercise: String, type: String, value: Double, delta: Double?)] = []

    var isEmpty: Bool { sessionCount == 0 }
}

/// Synthesizes weekly telemetry into RPG-flavored patch notes — fully on-device.
/// Uses Apple's FoundationModels when available; otherwise falls back to a
/// deterministic local template composer. Zero cloud, zero API keys.
enum NarrativeEngine {

    static func weeklyTelemetry(context: ModelContext) -> WeeklyTelemetry {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!

        var telemetry = WeeklyTelemetry()

        let sessionDescriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.startDate >= weekAgo }
        )
        let sessions = (try? context.fetch(sessionDescriptor)) ?? []
        telemetry.sessionCount = sessions.count
        for session in sessions {
            let working = session.sets.filter { !$0.isWarmup }
            telemetry.setCount += working.count
            telemetry.totalVolume += session.totalVolume
        }

        let prDescriptor = FetchDescriptor<PRRecord>(
            predicate: #Predicate { $0.dateAchieved >= weekAgo },
            sortBy: [SortDescriptor(\.dateAchieved, order: .reverse)]
        )
        let records = (try? context.fetch(prDescriptor)) ?? []
        telemetry.prCount = records.count
        telemetry.topRecords = records.prefix(4).map { record in
            let previous = record.exercise?.prRecords
                .filter { $0.recordType == record.recordType && $0.dateAchieved < record.dateAchieved }
                .map(\.numericValue).max()
            let delta: Double? = previous.flatMap { $0 > 0 ? record.numericValue - $0 : nil }
            return (record.exercise?.name ?? "Unknown", record.recordType, record.numericValue, delta)
        }

        telemetry.streakDays = currentStreak(context: context)
        return telemetry
    }

    static func currentStreak(context: ModelContext) -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let calendar = Calendar.current
        let trainedDays = Set(sessions.map { calendar.startOfDay(for: $0.startDate) })
        guard !trainedDays.isEmpty else { return 0 }

        var streak = 0
        var day = calendar.startOfDay(for: Date())
        // A streak survives if today hasn't been trained yet but yesterday was.
        if !trainedDays.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        while trainedDays.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    // MARK: - Generation

    static func generatePatchNotes(from telemetry: WeeklyTelemetry) async -> String {
        guard !telemetry.isEmpty else {
            return "No quest data logged this week. The arena awaits — start a session to generate your first patch notes."
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.availability == .available {
                do {
                    return try await generateWithFoundationModel(telemetry)
                } catch {
                    return templatePatchNotes(telemetry)
                }
            }
        }
        #endif
        return templatePatchNotes(telemetry)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateWithFoundationModel(_ telemetry: WeeklyTelemetry) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You are the narrative engine for LimitBreak, an RPG-styled workout tracker. \
            Write short, punchy weekly "patch notes" in the voice of a video game changelog \
            describing the user's real training week as character upgrades. Use RPG flavor \
            (raid bosses, ceilings expanded, damage dealt) but keep every number accurate to \
            the telemetry provided. 4-6 lines, no markdown headers.
            """)

        var prompt = """
            Weekly telemetry:
            - Sessions completed: \(telemetry.sessionCount)
            - Working sets: \(telemetry.setCount)
            - Total volume moved: \(Int(telemetry.totalVolume)) lbs
            - Records broken (LimitBreaks): \(telemetry.prCount)
            - Active streak: \(telemetry.streakDays) days
            """
        for record in telemetry.topRecords {
            let deltaText = record.delta.map { String(format: " (+%.1f)", $0) } ?? " (first record)"
            prompt += "\n- New \(record.type) on \(record.exercise): \(record.value.cleanWeight)\(deltaText)"
        }

        let response = try await session.respond(to: prompt)
        return response.content
    }
    #endif

    /// Deterministic fallback: composes patch notes locally with no model dependency.
    private static func templatePatchNotes(_ telemetry: WeeklyTelemetry) -> String {
        var lines: [String] = []
        lines.append("LIMITBREAK CHARACTER UPGRADE — WEEKLY PATCH NOTES")

        for record in telemetry.topRecords {
            let delta = record.delta.map { " (+\($0.cleanWeight))" } ?? " — first record set"
            lines.append("• \(record.exercise) \(record.type) ceiling expanded to \(record.value.cleanWeight)\(delta).")
        }

        let bosses = max(1, Int(telemetry.totalVolume / 4500))
        lines.append("• Physical volume: \(Int(telemetry.totalVolume).formatted()) lbs shifted across \(telemetry.setCount) working sets — damage dealt equivalent to defeating \(bosses) raid boss\(bosses == 1 ? "" : "es").")

        if telemetry.streakDays >= 2 {
            lines.append("• \(telemetry.streakDays)-day active streak maintained. Momentum buff active.")
        }
        if telemetry.prCount > 0 {
            lines.append("• \(telemetry.prCount) LimitBreak\(telemetry.prCount == 1 ? "" : "s") triggered this week. Ceilings are meant to be shattered.")
        } else {
            lines.append("• No ceilings broken this week. The grind continues — every set charges the next LimitBreak.")
        }

        return lines.joined(separator: "\n")
    }
}

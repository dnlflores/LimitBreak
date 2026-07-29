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

/// Synthesizes weekly telemetry into RPG-flavored patch notes. The tier used
/// tracks the lifter's AI choice: the cloud/self-hosted coach when they've
/// opted into it, otherwise Apple's on-device FoundationModels, otherwise a
/// deterministic local template. Whichever path is taken, a failure falls
/// through to the next so the Saga always renders something readable.
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

    /// The active streak, counting any activity — sessions, sports, and walks
    /// over a mile — via the shared XP-engine definition, so the narrative,
    /// the Skill Matrix tile and the widget all agree.
    static func currentStreak(context: ModelContext) -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let walks = (try? context.fetch(FetchDescriptor<Walk>())) ?? []
        let activities = (try? context.fetch(FetchDescriptor<Activity>())) ?? []
        return XPEngine.currentStreak(sessions: sessions, walks: walks, activities: activities)
    }

    // MARK: - Generation

    /// Generates the week's patch notes using whichever intelligence tier the
    /// lifter has chosen. `provider` is non-nil only when cloud AI is enabled;
    /// it names the backend to route through. Any failure falls through to the
    /// on-device path, so the Saga always produces something readable offline.
    static func generatePatchNotes(
        from telemetry: WeeklyTelemetry,
        provider: AIProvider? = nil
    ) async -> String {
        guard !telemetry.isEmpty else {
            return "No quest data logged this week. The arena awaits — start a session to generate your first patch notes."
        }

        if let provider {
            do {
                switch provider {
                case .claude:
                    if CloudWorkoutAI.isConfigured {
                        return try await generateWithClaude(telemetry)
                    }
                case .odysseus:
                    if OdysseusConfig.isConfigured {
                        return try await generateWithOdysseus(telemetry)
                    }
                }
            } catch {
                // A network blip, a declined request, or an unparseable reply
                // should never leave the Saga blank — fall through to on-device.
            }
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

    // MARK: - Prompt

    /// The voice, rules, and output format shared by every model tier, so the
    /// Saga reads and renders the same whether it was composed by Claude, a
    /// self-hosted model, or Apple's on-device model.
    ///
    /// The format is a deterministic Markdown contract — one `## ` title then a
    /// handful of `- ` bullets — so `PatchNotesFormatter` can parse and render
    /// headers and bullets identically regardless of which model answered.
    static let patchNotesInstructions = """
        You are the narrative engine for LimitBreak, an RPG-styled workout tracker. \
        Write the user's real training week as short, punchy "patch notes" in the voice of \
        a video-game changelog — character upgrades, raid bosses, ceilings expanded, damage \
        dealt. Keep every number accurate to the telemetry provided; never invent stats.

        Format the reply as GitHub-flavored Markdown using ONLY this structure:
        - Exactly one level-2 header on the first line — "## " followed by a short, punchy \
        title for the week (2 to 5 words).
        - Then 4 to 6 bullet points, each on its own line starting with "- ", one patch note \
        per bullet.
        - You may wrap a key term or number in **double asterisks** to bold it. No other \
        Markdown: no extra headers, no nested bullets, no tables, no code fences, no links, \
        no images.

        Output only the Markdown. No preamble, no explanation, nothing before the "## " title \
        or after the last bullet.
        """

    /// The week's numbers, rendered as the model's input.
    static func patchNotesPrompt(_ telemetry: WeeklyTelemetry) -> String {
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
        return prompt
    }

    // MARK: - Cloud tiers

    /// Claude composes the notes as a single constrained string, reusing the
    /// same hardened request path as workout coaching.
    private static func generateWithClaude(_ telemetry: WeeklyTelemetry) async throws -> String {
        let result: CloudPatchNotes = try await ClaudeClient.structuredRequest(
            system: [ClaudeClient.SystemBlock(text: patchNotesInstructions)],
            userMessage: patchNotesPrompt(telemetry),
            schema: patchNotesSchema,
            as: CloudPatchNotes.self,
            maxTokens: 1_000
        )
        let notes = result.patchNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { throw ClaudeClient.ClientError.malformedResponse }
        return notes
    }

    private struct CloudPatchNotes: Decodable {
        let patchNotes: String
    }

    private static let patchNotesSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "patchNotes": [
                "type": "string",
                "description": "The weekly patch notes as GitHub-flavored Markdown: one '## ' title line followed by 4 to 6 '- ' bullet lines. Bold key terms with **double asterisks**. No other Markdown.",
            ],
        ],
        "required": ["patchNotes"],
        "additionalProperties": false,
    ]

    /// A self-hosted model returns free text — often the notes wrapped in a
    /// JSON envelope with tool-call scaffolding. `narrativeText` recovers the
    /// readable part; the raw envelope is never shown to the lifter.
    private static func generateWithOdysseus(_ telemetry: WeeklyTelemetry) async throws -> String {
        guard let token = KeychainStore.odysseusToken,
              let endpointID = OdysseusConfig.endpointID,
              let model = OdysseusConfig.model
        else { throw OdysseusClient.OdysseusError.notConfigured }

        let baseURL = OdysseusConfig.baseURL
        guard !baseURL.isEmpty else { throw OdysseusClient.OdysseusError.notConfigured }

        let message = patchNotesInstructions + "\n\n" + patchNotesPrompt(telemetry)
            + "\n\nReply with only the Markdown patch notes — no JSON, no tool calls, no preamble, no code fences."

        let session = try await OdysseusClient.createSession(
            baseURL: baseURL, token: token, endpointID: endpointID, model: model, name: "LimitBreak Saga"
        )
        let reply = try await OdysseusClient.chat(
            baseURL: baseURL, token: token, sessionID: session.id, message: message
        )

        guard let notes = narrativeText(from: reply) else {
            throw OdysseusClient.OdysseusError.emptyReply
        }
        return notes
    }

    // MARK: - Reply parsing

    /// Pulls the human-readable narrative out of a model reply that may be
    /// plain prose, fenced JSON, or a tool-calling envelope. Local models
    /// frequently return the actual patch notes inside a JSON field such as
    /// `eventual_response`, alongside tool-call scaffolding that is unreadable
    /// if shown raw — the Saga bug this was written for.
    static func narrativeText(from reply: String) -> String? {
        let cleaned = JSONExtractor.strippingReasoning(reply)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Prefer a narrative field from any JSON object the reply contains.
        if case .found(let objects) = JSONExtractor.scan(cleaned) {
            for object in objects {
                guard let data = object.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let text = narrativeField(in: json) { return unwrapFence(text) }
            }
        }

        // No JSON envelope, or none with a usable field. The notes are Markdown,
        // so unwrap any code fence the model wrapped them in and hand back the
        // prose — but still reject a bare JSON object we couldn't pull a field
        // from, since that's never readable narrative.
        let unwrapped = unwrapFence(cleaned)
        let looksLikeJSON = unwrapped.hasPrefix("{") || unwrapped.hasPrefix("[")
        return looksLikeJSON ? nil : unwrapped
    }

    /// Strips a surrounding Markdown/code fence (```` ``` ```` or ```` ```markdown ````)
    /// so a model that wrapped its answer in a fenced block still renders as
    /// clean Markdown rather than showing the backticks.
    private static func unwrapFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()   // drop the opening ``` (with or without a language tag)
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keys a model is likely to put the finished narrative under, most
    /// specific first. `eventual_response` is what the self-hosted tool-calling
    /// template emits.
    private static let narrativeKeys = [
        "eventual_response", "patch_notes", "patchNotes", "narrative",
        "response", "message", "content", "text", "notes", "summary",
        "answer", "output",
    ]

    /// The first non-empty narrative string in `object`, searching known keys
    /// at this level before descending into nested objects and arrays.
    private static func narrativeField(in object: [String: Any]) -> String? {
        for key in narrativeKeys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let found = narrativeField(in: nested) {
                return found
            }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = narrativeField(in: item) { return found }
                }
            }
        }
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateWithFoundationModel(_ telemetry: WeeklyTelemetry) async throws -> String {
        let session = LanguageModelSession(instructions: patchNotesInstructions)
        let response = try await session.respond(to: patchNotesPrompt(telemetry))
        return response.content
    }
    #endif

    /// Deterministic fallback: composes patch notes locally with no model
    /// dependency, in the same Markdown contract the model tiers follow so the
    /// Saga renders it identically.
    private static func templatePatchNotes(_ telemetry: WeeklyTelemetry) -> String {
        var lines: [String] = []
        lines.append("## Weekly Character Upgrade")

        for record in telemetry.topRecords {
            let delta = record.delta.map { " (+\($0.cleanWeight))" } ?? " — first record set"
            lines.append("- **\(record.exercise)** \(record.type) ceiling expanded to **\(record.value.cleanWeight)**\(delta).")
        }

        let bosses = max(1, Int(telemetry.totalVolume / 4500))
        lines.append("- Physical volume: **\(Int(telemetry.totalVolume).formatted()) lbs** shifted across **\(telemetry.setCount)** working sets — damage dealt equal to felling **\(bosses)** raid boss\(bosses == 1 ? "" : "es").")

        if telemetry.streakDays >= 2 {
            lines.append("- **\(telemetry.streakDays)-day** active streak maintained. Momentum buff active.")
        }
        if telemetry.prCount > 0 {
            lines.append("- **\(telemetry.prCount)** LimitBreak\(telemetry.prCount == 1 ? "" : "s") triggered this week. Ceilings are meant to be shattered.")
        } else {
            lines.append("- No ceilings broken this week. The grind continues — every set charges the next LimitBreak.")
        }

        return lines.joined(separator: "\n")
    }
}

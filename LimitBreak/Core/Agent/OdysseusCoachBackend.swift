import Foundation

/// The self-hosted coaching tier: the same brief and the same tools, sent to a
/// local model on the lifter's own machine.
///
/// `/api/chat` has no tool API and no system-prompt channel — it takes one
/// message and returns free text. So the tool contract is stated in words
/// (`CoachPrompt.textToolContract`) and the reply is parsed defensively here.
/// That parsing is the whole difference from the Anthropic tier, and it lives
/// only in this file.
///
/// Unlike plan generation, a conversation is *not* stateless: the server keeps
/// per-session history, so the opening message carries the brief, the contract,
/// and the situation, and every turn after it sends only what is new. A chat
/// that re-sent its whole history each turn would re-read the tool contract on
/// every tool result — the most expensive thing in the prompt, repeated for no
/// gain. If the server prunes the session out from under us, `.sessionNotFound`
/// triggers one silent rebuild-and-replay.
@MainActor
final class OdysseusCoachBackend: CoachBackend {

    var displayName: String { OdysseusConfig.modelDisplayName ?? "your server" }

    static var isConfigured: Bool { OdysseusConfig.isConfigured }

    /// The server-side conversation, created lazily on the first turn.
    private var sessionID: String?
    /// How many transcript entries the live session has already been told
    /// about, so each turn sends only the new tail.
    private var deliveredCount = 0

    func nextTurn(
        system: String,
        transcript: [CoachMessage],
        tools: [CoachTool]
    ) async throws -> CoachTurn {
        guard let token = KeychainStore.odysseusToken,
              let endpointID = OdysseusConfig.endpointID,
              let model = OdysseusConfig.model
        else { throw OdysseusClient.OdysseusError.notConfigured }

        let baseURL = OdysseusConfig.baseURL
        guard !baseURL.isEmpty else { throw OdysseusClient.OdysseusError.notConfigured }

        let reply: String
        do {
            reply = try await send(
                system: system, transcript: transcript, tools: tools,
                baseURL: baseURL, token: token, endpointID: endpointID, model: model
            )
        } catch OdysseusClient.OdysseusError.sessionNotFound {
            // The session was pruned server-side. Start a new one and replay
            // the whole conversation into it; the lifter never sees this.
            sessionID = nil
            deliveredCount = 0
            reply = try await send(
                system: system, transcript: transcript, tools: tools,
                baseURL: baseURL, token: token, endpointID: endpointID, model: model
            )
        }

        return Self.parse(reply)
    }

    // MARK: - Sending

    private func send(
        system: String,
        transcript: [CoachMessage],
        tools: [CoachTool],
        baseURL: String,
        token: String,
        endpointID: String,
        model: String
    ) async throws -> String {
        let isNewSession = sessionID == nil
        if isNewSession {
            let session = try await OdysseusClient.createSession(
                baseURL: baseURL, token: token,
                endpointID: endpointID, model: model, name: "LimitBreak Coach"
            )
            sessionID = session.id
        }
        guard let sessionID else { throw OdysseusClient.OdysseusError.notConfigured }

        // A fresh session needs the full brief and the whole history; an
        // established one needs only what it hasn't seen — and of that, only
        // the *user* side. The server already holds the model's own replies, so
        // echoing them back would have the coach reading its last turn as if
        // the lifter had said it.
        let pending: [CoachMessage] = isNewSession
            ? transcript
            : transcript.dropFirst(deliveredCount).filter { $0.role == .user }
        let body = Self.render(pending)
        // Nothing new to say. `/api/chat` rejects an empty message, and its
        // "couldn't read the response" error would point at the server for what
        // is really a caller mistake.
        guard isNewSession || !body.isEmpty else { throw OdysseusClient.OdysseusError.emptyReply }

        let message = isNewSession
            ? [system, CoachPrompt.textToolContract(tools: tools), CoachPrompt.answerContract, body]
                .joined(separator: "\n\n")
            : body

        let reply = try await OdysseusClient.chat(
            baseURL: baseURL, token: token, sessionID: sessionID, message: message
        )
        // Only advance after a successful round trip, so a failure re-sends
        // rather than silently skipping turns the model never received.
        deliveredCount = transcript.count
        return reply
    }

    /// The transcript as plain text, in the shape the contract describes.
    private static func render(_ transcript: [CoachMessage]) -> String {
        transcript.compactMap { message -> String? in
            switch message.role {
            case .user:
                var parts: [String] = []
                if !message.text.isEmpty { parts.append("LIFTER: \(message.text)") }
                for result in message.toolResults {
                    let label = result.isError ? "TOOL ERROR" : "TOOL RESULT"
                    parts.append("\(label): \(result.text)")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            case .assistant:
                var parts: [String] = []
                if !message.text.isEmpty { parts.append("YOU: \(message.text)") }
                for call in message.toolCalls {
                    let arguments = JSONValue.object(call.arguments).jsonText
                    parts.append("YOU CALLED: {\"tool\": \"\(call.name)\", \"arguments\": \(arguments)}")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - Reply parsing

    /// Turns free text into a turn: either a tool call or a spoken reply.
    ///
    /// Every balanced object in the reply is considered, not just the first: a
    /// thinking model often emits a draft object before the real one, and the
    /// call is whichever candidate actually names a tool. If none does, the
    /// reply is an answer — and per the answer contract that answer is itself a
    /// `{"message": …, "suggestions": […]}` object, which `CoachReply.parse`
    /// reads (falling back to plain prose when the model ignored the shape). So
    /// the two outcomes are one JSON grammar, which is the point: the tier
    /// emits one thing, and this reads it one way.
    ///
    /// Pure, so it stays off the main actor and is testable on its own.
    nonisolated static func parse(_ reply: String) -> CoachTurn {
        if case .found(let candidates) = JSONExtractor.scan(reply) {
            for candidate in candidates {
                let object = JSONValue.objectFrom(jsonText: candidate)

                // Accept the aliases small models drift toward when naming the
                // key, and require the value to be a tool that exists — that's
                // what separates a real call from a draft object, or from the
                // answer object, that happens to have a "name" field.
                let nameKeys = ["tool", "tool_name", "name"]
                guard let nameKey = nameKeys.first(where: { key in
                    object.string(key).flatMap(CoachTool.named) != nil
                }), let name = object.string(nameKey) else { continue }

                // Which key carried the tool name matters: `{"tool":
                // "get_routine", "name": "Legs"}` inlines its arguments, and
                // "name" is one of them.
                let arguments = object["arguments"]?.objectValue
                    ?? object["parameters"]?.objectValue
                    ?? object["input"]?.objectValue
                    ?? object.filter { $0.key.caseInsensitiveCompare(nameKey) != .orderedSame }

                return CoachTurn(toolCalls: [CoachToolCall(
                    id: UUID().uuidString,
                    name: name,
                    arguments: arguments
                )])
            }
        }

        // No object named a known tool — the coach is answering. Read the
        // reply object out of the text, or fall back to the whole reply as the
        // message. Either way the turn ends with something the lifter can read.
        return CoachTurn(reply: CoachReply.parse(fromText: reply))
    }
}

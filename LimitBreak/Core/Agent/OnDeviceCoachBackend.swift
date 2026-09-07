import Foundation
import FoundationModels

/// The on-device coaching tier: Apple's system language model, running locally.
///
/// Free, private, and works with no network at all — and correspondingly
/// constrained. One accommodation follows from the small context window, and it
/// is deliberate rather than incidental:
///
/// - **A single structured reply rather than native tool calling.** Guided
///   generation gives one reliably-shaped answer per turn: either prose or one
///   call. Multi-call turns aren't worth the context they'd cost here.
///
/// The tool set, by contrast, is the *whole* catalog. This tier once withheld
/// four tools on the theory that their closed value lists were the costliest
/// block in the prompt; measured against the compact contract that turned out
/// to be false — the four together run ~930 characters, less than the two
/// largest tools the tier already offered. Withholding them bought roughly two
/// hundred tokens and cost the lifter the ability to change their profile or
/// program their week without a network, which is precisely when they are most
/// likely to be standing in a gym with no signal. Parity is the default now:
/// a tool added to `CoachTool.catalog` reaches every tier.
///
/// The session keeps its own transcript, so each turn sends only what is new.
@MainActor
final class OnDeviceCoachBackend: CoachBackend {

    var displayName: String { "on-device" }

    /// Whether the system model is actually usable right now. It can be
    /// unavailable on unsupported hardware, with Apple Intelligence off, or
    /// while the weights are still downloading.
    static var isConfigured: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// One turn's output. `tool` and `reply` are mutually exclusive; the guide
    /// text says so, and `parse` enforces it whichever way the model answers.
    ///
    /// This is the on-device spelling of the same answer the hosted tiers emit
    /// as a `{message, suggestions}` object: `reply` is the message and
    /// `suggestions` are the follow-ups, delivered here through guided
    /// generation rather than a text contract, so the shape is enforced by the
    /// runtime instead of parsed back out.
    @Generable
    struct Reply {
        @Guide(description: "The name of the one tool to call, or an empty string when you are answering the lifter directly instead of calling a tool.")
        var tool: String

        @Guide(description: "The tool's arguments as a JSON object, for example {\"name\": \"Push Day\"}. Use {} when the tool takes no arguments or when you are not calling one.")
        var arguments: String

        @Guide(description: "Your reply to the lifter, in plain prose. Leave this empty when you are calling a tool.")
        var reply: String

        @Guide(description: "Up to three short follow-ups the lifter might tap to say next, phrased in their voice like \"Make it harder\". Leave empty when you are calling a tool or nothing natural fits.", .maximumCount(CoachReply.maxSuggestions))
        var suggestions: [String]
    }

    private var session: LanguageModelSession?
    /// How many transcript entries the live session has already been given.
    private var deliveredCount = 0

    /// The tools offered on-device: all of them. Kept as a named function
    /// rather than inlined so the parity is stated in one place, and so a
    /// future window-driven narrowing has an obvious home — with a measurement
    /// attached, this time.
    nonisolated static func availableTools(from catalog: [CoachTool]) -> [CoachTool] {
        catalog
    }

    /// - Note: `system` is deliberately unused — this tier substitutes the
    ///   condensed brief, for the window reasons documented on the type.
    func nextTurn(
        system: String,
        transcript: [CoachMessage],
        tools: [CoachTool]
    ) async throws -> CoachTurn {
        let offered = Self.availableTools(from: tools)

        do {
            return try await respond(transcript: transcript, tools: offered)
        } catch let error as LanguageModelSession.GenerationError {
            // A long conversation eventually outgrows the on-device window.
            // Rebuild the session and replay — the transcript is the source of
            // truth, so nothing is lost but the server-side history.
            guard case .exceededContextWindowSize = error else { throw error }
            session = nil
            deliveredCount = 0
            return try await respond(transcript: transcript, tools: offered)
        }
    }

    private func respond(
        transcript: [CoachMessage],
        tools: [CoachTool]
    ) async throws -> CoachTurn {
        let isNewSession = session == nil
        if isNewSession {
            // The condensed brief and one-line-per-tool contract, not the full
            // ones the hosted tiers get: at full size the instructions alone
            // run ~2,600 tokens, which leaves too little of the on-device
            // window for the conversation they're supposed to serve.
            session = LanguageModelSession(instructions: [
                CoachPrompt.compactInstructions,
                CoachPrompt.textToolContract(tools: tools, compact: true),
            ].joined(separator: "\n\n"))
        }
        guard let session else { throw CoachAgentError.onDeviceUnavailable }

        // A fresh session replays everything; an established one gets only the
        // new *user* side. `LanguageModelSession` already holds its own replies,
        // so echoing them back would have the model reading its last turn as if
        // the lifter had said it.
        let pending: [CoachMessage] = isNewSession
            ? transcript
            : transcript.dropFirst(deliveredCount).filter { $0.role == .user }
        let prompt = Self.render(pending)
        guard !prompt.isEmpty else { return CoachTurn() }

        let response = try await session.respond(to: prompt, generating: Reply.self)
        // Only advance once the turn landed, so a thrown error re-sends rather
        // than silently dropping what the model never saw.
        deliveredCount = transcript.count
        return Self.parse(response.content, tools: tools)
    }

    // MARK: - Rendering and parsing

    private static func render(_ transcript: [CoachMessage]) -> String {
        transcript.compactMap { message -> String? in
            switch message.role {
            case .user:
                var parts: [String] = []
                if !message.text.isEmpty { parts.append("Lifter: \(message.text)") }
                for result in message.toolResults {
                    let label = result.isError ? "Tool error" : "Tool result"
                    parts.append("\(label): \(result.text)")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            case .assistant:
                var parts: [String] = []
                if !message.text.isEmpty { parts.append("You: \(message.text)") }
                for call in message.toolCalls {
                    parts.append("You called \(call.name) with \(JSONValue.object(call.arguments).jsonText)")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    nonisolated static func parse(_ reply: Reply, tools: [CoachTool]) -> CoachTurn {
        let name = reply.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let prose = reply.reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // An unrecognised name is treated as "no call" rather than an error:
        // the prose is usually still a serviceable answer, and surfacing a
        // hallucinated tool name to the lifter helps nobody. Suggestions ride
        // along with the answer; on a tool call they're dropped, since a tool
        // turn isn't the coach speaking.
        guard !name.isEmpty, tools.contains(where: { $0.name == name }) else {
            return CoachTurn(reply: CoachReply(message: prose, suggestions: reply.suggestions))
        }
        return CoachTurn(toolCalls: [CoachToolCall(
            id: UUID().uuidString,
            name: name,
            arguments: JSONValue.objectFrom(jsonText: reply.arguments)
        )])
    }
}

import Foundation

/// The hosted coaching tier: Anthropic's Messages API with native tool use.
///
/// This is the only tier where the tool contract is enforced server-side — the
/// model can't invent a tool name or omit a required argument, because the
/// schema is validated before the call reaches us. That's why the other two
/// backends carry parsing and repair logic and this one doesn't.
///
/// Two details of the wire format are load-bearing and easy to get wrong:
///
/// 1. **Assistant turns must be echoed back whole.** Every `tool_use` block has
///    to reappear in the next request, paired with a `tool_result` carrying the
///    same id. Dropping the block — or answering only some of several calls —
///    is rejected rather than degraded.
/// 2. **All results for one turn go in a single user message.** Splitting them
///    across messages is accepted, but it quietly teaches the model to stop
///    making parallel calls.
@MainActor
final class ClaudeCoachBackend: CoachBackend {

    var displayName: String { "Claude" }

    static var isConfigured: Bool { KeychainStore.hasKey }

    func nextTurn(
        system: String,
        transcript: [CoachMessage],
        tools: [CoachTool]
    ) async throws -> CoachTurn {
        let body: [String: Any] = [
            "model": ClaudeClient.model,
            "max_tokens": 16_000,
            "system": [
                // One cacheable block: the instructions, the answer contract,
                // and the tool list are the stable prefix of every turn in the
                // conversation, and the volatile situation block deliberately
                // lives in the first user turn instead so it can't invalidate
                // this. The answer contract rides here too — the tools are
                // enforced by the API, but the *shape of a spoken reply* is
                // ours to specify, and it must match what the other tiers emit.
                [
                    "type": "text",
                    "text": system + "\n\n" + CoachPrompt.answerContract,
                    "cache_control": ["type": "ephemeral"],
                ] as [String: Any],
            ],
            "tools": tools.map(\.anthropicDefinition),
            "messages": Self.wireMessages(from: transcript),
            "output_config": ["effort": ClaudeClient.effort],
            "fallbacks": "default",
        ]

        let json = try await ClaudeClient.send(body: body)
        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeClient.ClientError.malformedResponse
        }

        // Kept whole so the next request can echo this turn back byte-for-byte,
        // thinking blocks included.
        var turn = CoachTurn(rawContent: content.map { JSONValue(any: $0) })
        var paragraphs: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { paragraphs.append(text) }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = (block["input"] as? [String: Any]) ?? [:]
                turn.toolCalls.append(CoachToolCall(
                    id: id,
                    name: name,
                    arguments: input.mapValues(JSONValue.init(any:))
                ))
            default:
                // Thinking blocks and anything newer land here. Their text is
                // omitted by default on this model, and nothing downstream
                // reads them, so they're skipped rather than surfaced.
                continue
            }
        }

        // A turn that called tools is intermediate — its text, if any, is the
        // model thinking out loud on the way to the answer, not the answer.
        // Only a turn with no tool calls is a spoken reply, and per the answer
        // contract its text is the `{message, suggestions}` object. `parse`
        // falls back to plain prose if the model didn't obey the contract, so a
        // stray answer still reaches the lifter.
        if turn.toolCalls.isEmpty {
            turn.reply = CoachReply.parse(fromText: paragraphs.joined(separator: "\n\n"))
        }
        return turn
    }

    // MARK: - Wire format

    /// Renders the transcript as Anthropic `messages`.
    ///
    /// Turns that carry neither text nor tool traffic are dropped: the API
    /// rejects an empty content array, and an assistant turn that produced
    /// nothing has nothing to preserve.
    static func wireMessages(from transcript: [CoachMessage]) -> [[String: Any]] {
        transcript.compactMap { message in
            var blocks: [[String: Any]] = []

            switch message.role {
            case .user:
                if !message.text.isEmpty {
                    blocks.append(["type": "text", "text": message.text])
                }
                for result in message.toolResults {
                    var block: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": result.callID,
                        "content": result.text,
                    ]
                    if result.isError { block["is_error"] = true }
                    blocks.append(block)
                }
            case .assistant:
                // Echo the turn exactly as it arrived when we have it. The
                // reconstruction below is only for turns this backend didn't
                // produce — a conversation that started on another tier.
                if !message.rawContent.isEmpty {
                    blocks = message.rawContent.compactMap { $0.anyValue as? [String: Any] }
                    break
                }
                if !message.text.isEmpty {
                    blocks.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments.mapValues(\.anyValue),
                    ])
                }
            }

            guard !blocks.isEmpty else { return nil }
            return ["role": message.role == .user ? "user" : "assistant", "content": blocks]
        }
    }
}

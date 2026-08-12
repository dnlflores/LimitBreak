//
//  CoachAgentTests.swift
//  LimitBreakTests
//
//  The conversational coach's parsing layer. Everything here guards a failure
//  that would otherwise be silent: a tool call that quietly reads as prose, an
//  argument coerced to nil, a schema the model can't satisfy. The tool runner
//  itself is exercised through the app — these cover the pure logic that sits
//  between a model's reply and a real mutation.
//

import Foundation
import Testing
@testable import LimitBreak

struct JSONValueTests {

    @Test func readsPlainValues() {
        let arguments = JSONValue.objectFrom(jsonText: """
            {"name": "Push Day", "sets": 4, "weight": 137.5, "superset": true}
            """)
        #expect(arguments.string("name") == "Push Day")
        #expect(arguments.int("sets") == 4)
        #expect(arguments.double("weight") == 137.5)
        #expect(arguments.bool("superset") == true)
    }

    /// Local models routinely send numbers as strings, floats where integers
    /// were asked for, and units glued onto weights. Each of these rescues a
    /// call that would otherwise be discarded.
    @Test func coercesSloppyNumbers() {
        let arguments = JSONValue.objectFrom(jsonText: """
            {"sets": "4", "reps": 8.0, "weight": "135 lb", "partner": "yes"}
            """)
        #expect(arguments.int("sets") == 4)
        #expect(arguments.int("reps") == 8)
        #expect(arguments.double("weight") == 135)
        #expect(arguments.bool("partner") == true)
    }

    @Test func keyLookupIgnoresCasingAndSeparators() {
        let arguments = JSONValue.objectFrom(jsonText: """
            {"targetSets": 3, "SUPERSET_GROUP": 1}
            """)
        #expect(arguments.int("target_sets") == 3)
        #expect(arguments.int("supersetGroup") == 1)
    }

    /// A lone value where a list was asked for is the single most common shape
    /// error from a small model, and promoting it costs nothing.
    @Test func promotesScalarsToLists() {
        let arguments = JSONValue.objectFrom(jsonText: #"{"exercises": "Bench Press"}"#)
        #expect(arguments.array("exercises")?.count == 1)

        let objects = arguments.objectArray("exercises")
        #expect(objects.count == 1)
        #expect(objects.first?.string("name") == "Bench Press")
    }

    @Test func blankStringsReadAsAbsent() {
        let arguments = JSONValue.objectFrom(jsonText: #"{"notes": "   "}"#)
        #expect(arguments.string("notes") == nil)
    }

    @Test func unparseableTextYieldsNoArguments() {
        #expect(JSONValue.objectFrom(jsonText: "not json at all").isEmpty)
        // A bare array isn't an argument object either.
        #expect(JSONValue.objectFrom(jsonText: "[1, 2, 3]").isEmpty)
    }

    @Test func roundTripsThroughFoundation() {
        let original = JSONValue.object([
            "name": .string("Legs"),
            "sets": .number(3),
            "paired": .bool(false),
        ])
        let restored = JSONValue(any: original.anyValue)
        #expect(restored == original)
    }
}

struct CoachTranscriptTests {

    /// The opening situation block is written by the app for the model. It has
    /// to reach the request and must never reach the screen, where it read as
    /// the lifter reciting their own profile back at themselves.
    @Test func plumbingNeverRenders() {
        let situation = CoachMessage(role: .user, text: "Context for this conversation…", isPlumbing: true)
        #expect(!situation.isVisible)
    }

    /// A user turn carrying only tool results is plumbing too — it belongs in
    /// the request, not the transcript on screen.
    @Test func toolResultTurnsNeverRender() {
        let results = CoachMessage(
            role: .user,
            toolResults: [CoachToolResult(callID: "1", text: "Saved routines: …")]
        )
        #expect(!results.isVisible)
    }

    @Test func realTurnsRender() {
        #expect(CoachMessage(role: .user, text: "Build me a push day").isVisible)
        #expect(CoachMessage(role: .assistant, text: "Here's what I'd run.").isVisible)
    }

    /// An assistant turn that only called tools still renders — that row is how
    /// the lifter sees what the coach actually did.
    @Test func toolCallsRenderWithoutProse() {
        let call = CoachToolCall(id: "1", name: "list_routines", arguments: [:])
        #expect(CoachMessage(role: .assistant, toolCalls: [call]).isVisible)
        #expect(call.activityLabel == "Reading your routines")
    }

    /// The activity labels are a hand-written map, so they drift from the
    /// catalog silently — a new tool would show the lifter `set_plan_day`
    /// instead of "Setting a training day". The fallback keeps it readable,
    /// this keeps it deliberate.
    @Test func everyToolHasAWrittenActivityLabel() {
        for tool in CoachTool.catalog {
            let label = CoachToolCall(id: "1", name: tool.name, arguments: [:]).activityLabel
            #expect(
                label != tool.name.replacingOccurrences(of: "_", with: " ").capitalized,
                "\(tool.name) has no written activity label"
            )
        }
    }
}

struct CoachToolCatalogTests {

    @Test func everyToolHasAUsableSchema() {
        for tool in CoachTool.catalog {
            #expect(!tool.name.isEmpty)
            // Descriptions are the strongest signal for correct tool choice;
            // a one-liner here is a real defect, not a style nit.
            #expect(tool.description.count > 40, "\(tool.name) needs a fuller description")

            let schema = tool.inputSchema
            #expect(schema["type"] as? String == "object")
            let properties = schema["properties"] as? [String: Any] ?? [:]
            #expect(properties.count == tool.parameters.count)

            let required = schema["required"] as? [String] ?? []
            for name in required {
                #expect(properties[name] != nil, "\(tool.name) requires an undeclared \(name)")
            }
        }
    }

    @Test func toolNamesAreUnique() {
        let names = CoachTool.catalog.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func lookupFindsCatalogEntries() {
        #expect(CoachTool.named("create_routine") != nil)
        #expect(CoachTool.named("definitely_not_a_tool") == nil)
    }

    /// The runner's dispatch and the catalog have to agree: a tool the model
    /// can see but the runner can't execute is a dead end it will keep
    /// retrying, and one the runner handles but never advertises is unreachable.
    @Test func writeToolsAreMarkedAsMutating() {
        let mutating = Set(CoachTool.catalog.filter(\.mutates).map(\.name))
        let expected: Set = [
            "create_routine", "update_routine", "delete_routine",
            "add_exercise_to_routine", "remove_exercise_from_routine",
            "generate_workout", "start_workout",
            "set_plan_day", "clear_plan_day",
            "update_profile", "create_exercise", "log_activity",
        ]
        #expect(mutating == expected)
    }

    @Test func readToolsNeverMutate() {
        for tool in CoachTool.catalog where tool.name.hasPrefix("get_") || tool.name.hasPrefix("list_") || tool.name.hasPrefix("search_") {
            #expect(!tool.mutates, "\(tool.name) reads but is marked mutating")
        }
    }

    @Test func textContractNamesEveryTool() {
        let contract = CoachTool.textContract
        for tool in CoachTool.catalog {
            #expect(contract.contains(tool.name))
        }
    }

    /// Closed value sets are stated in prose as well as in the schema, because
    /// the two schema-less tiers only ever see the prose.
    @Test func enumeratedValuesSurviveIntoTheTextContract() {
        let focusTool = CoachTool.named("generate_workout")
        #expect(focusTool?.textContract.contains("Full Body") == true)
    }

    /// The on-device window is small enough that the full contract crowds out
    /// the conversation. The compact form drops argument *descriptions* but
    /// must keep every argument *name* — a wrong name fails the call outright,
    /// where a missing description only costs some accuracy.
    @Test func compactContractKeepsArgumentNames() {
        for tool in CoachTool.catalog {
            let line = tool.compactTextContract
            #expect(line.contains(tool.name))
            for parameter in tool.parameters {
                #expect(line.contains(parameter.name), "\(tool.name) dropped \(parameter.name)")
            }
        }
    }

    @Test func compactContractMarksRequiredArguments() {
        let line = CoachTool.named("get_routine")?.compactTextContract ?? ""
        #expect(line.contains("name*"))
    }

    /// A required argument's closed value set survives compaction. Guessing
    /// `focus` is a rejected call and a wasted turn — far more expensive than
    /// the characters the list costs.
    @Test func compactContractKeepsRequiredEnumValues() {
        let line = CoachTool.named("generate_workout")?.compactTextContract ?? ""
        #expect(line.contains("focus*="))
        #expect(line.contains("Full Body"))
        #expect(line.contains("Push"))
    }

    /// Optional enums are left out — the tool's own error message names the
    /// valid values, and that correction is cheaper than the context.
    @Test func compactContractOmitsOptionalEnumValues() {
        let line = CoachTool.named("search_exercises")?.compactTextContract ?? ""
        #expect(line.contains("muscle"))
        #expect(!line.contains("Hamstrings"))
    }

    /// The reason the compact form exists. If this ratio ever collapses, the
    /// on-device tier is back to spending its window on instructions.
    @Test func compactContractIsSubstantiallySmaller() {
        let tools = OnDeviceCoachBackend.availableTools(from: CoachTool.catalog)
        let full = CoachPrompt.textToolContract(tools: tools).count
        let compact = CoachPrompt.textToolContract(tools: tools, compact: true).count
        #expect(compact * 2 < full, "compact contract is \(compact) vs full \(full)")
    }
}

struct ClaudeCoachWireFormatTests {

    /// Anthropic requires an assistant turn to be echoed back unchanged. With
    /// thinking on by default, rebuilding it from text and tool calls would
    /// silently drop the thinking blocks riding alongside them — which the API
    /// rejects rather than degrades, and only on the *second* tool round trip,
    /// where it's hardest to trace.
    @MainActor
    @Test func assistantTurnsEchoBackVerbatim() throws {
        let thinking = JSONValue.object([
            "type": .string("thinking"),
            "thinking": .string(""),
            "signature": .string("abc123"),
        ])
        let toolUse = JSONValue.object([
            "type": .string("tool_use"),
            "id": .string("toolu_1"),
            "name": .string("list_routines"),
            "input": .object([:]),
        ])
        let transcript = [
            CoachMessage(role: .user, text: "What have I got saved?"),
            CoachMessage(
                role: .assistant,
                toolCalls: [CoachToolCall(id: "toolu_1", name: "list_routines", arguments: [:])],
                rawContent: [thinking, toolUse]
            ),
            CoachMessage(
                role: .user,
                toolResults: [CoachToolResult(callID: "toolu_1", text: "Saved routines: Push Day")]
            ),
        ]

        let wire = ClaudeCoachBackend.wireMessages(from: transcript)
        #expect(wire.count == 3)

        let assistant = try #require(wire[1]["content"] as? [[String: Any]])
        #expect(assistant.count == 2)
        // The signature is what the API validates; a rebuilt block loses it.
        #expect(assistant[0]["type"] as? String == "thinking")
        #expect(assistant[0]["signature"] as? String == "abc123")
        #expect(assistant[1]["type"] as? String == "tool_use")
        #expect(assistant[1]["id"] as? String == "toolu_1")
    }

    /// Every `tool_use` must be answered by a `tool_result` carrying the same
    /// id, in a single following user turn.
    @MainActor
    @Test func toolResultsPairByIDInOneUserTurn() throws {
        let transcript = [
            CoachMessage(role: .user, text: "Do two things"),
            CoachMessage(role: .assistant, toolCalls: [
                CoachToolCall(id: "toolu_1", name: "list_routines", arguments: [:]),
                CoachToolCall(id: "toolu_2", name: "get_profile", arguments: [:]),
            ]),
            CoachMessage(role: .user, toolResults: [
                CoachToolResult(callID: "toolu_1", text: "…"),
                CoachToolResult(callID: "toolu_2", text: "…"),
            ]),
        ]

        let wire = ClaudeCoachBackend.wireMessages(from: transcript)
        let results = try #require(wire[2]["content"] as? [[String: Any]])
        #expect(wire[2]["role"] as? String == "user")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0["type"] as? String == "tool_result" })
        #expect(results.compactMap { $0["tool_use_id"] as? String } == ["toolu_1", "toolu_2"])
    }

    /// A failed tool is still answered — dropping it would leave a `tool_use`
    /// unpaired and the request rejected.
    @MainActor
    @Test func failedToolsAreStillAnswered() throws {
        let transcript = [
            CoachMessage(role: .user, text: "Open a routine"),
            CoachMessage(role: .assistant, toolCalls: [
                CoachToolCall(id: "toolu_1", name: "get_routine", arguments: [:]),
            ]),
            CoachMessage(role: .user, toolResults: [
                CoachToolResult(callID: "toolu_1", text: "No such routine.", isError: true),
            ]),
        ]

        let results = try #require(
            ClaudeCoachBackend.wireMessages(from: transcript)[2]["content"] as? [[String: Any]]
        )
        #expect(results[0]["is_error"] as? Bool == true)
    }

    /// A turn with nothing in it is dropped rather than sent — the API rejects
    /// an empty content array.
    @MainActor
    @Test func emptyTurnsAreDropped() {
        let wire = ClaudeCoachBackend.wireMessages(from: [
            CoachMessage(role: .user, text: "Hello"),
            CoachMessage(role: .assistant),
        ])
        #expect(wire.count == 1)
    }

    /// The situation block is plumbing on screen but must still reach the API —
    /// it's where the coach learns the date, the goal, and the live session.
    @MainActor
    @Test func plumbingStillReachesTheRequest() {
        let wire = ClaudeCoachBackend.wireMessages(from: [
            CoachMessage(role: .user, text: "Context for this conversation…", isPlumbing: true),
            CoachMessage(role: .user, text: "Build me a push day"),
        ])
        #expect(wire.count == 2)
    }
}

struct OdysseusCoachParsingTests {

    @Test func readsAToolCall() {
        let turn = OdysseusCoachBackend.parse("""
            {"tool": "get_routine", "arguments": {"name": "Push Day"}}
            """)
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls.first?.name == "get_routine")
        #expect(turn.toolCalls.first?.arguments.string("name") == "Push Day")
    }

    /// A thinking model often emits a draft object before the real one, so the
    /// call is whichever candidate actually names a known tool.
    @Test func skipsPreambleObjects() {
        let turn = OdysseusCoachBackend.parse("""
            Let me think. {"plan": "look up their routines first"}
            {"tool": "list_routines", "arguments": {}}
            """)
        #expect(turn.toolCalls.first?.name == "list_routines")
    }

    @Test func acceptsAliasedKeys() {
        let turn = OdysseusCoachBackend.parse("""
            {"tool_name": "get_routine", "parameters": {"name": "Legs"}}
            """)
        #expect(turn.toolCalls.first?.name == "get_routine")
        #expect(turn.toolCalls.first?.arguments.string("name") == "Legs")
    }

    /// Some replies inline the arguments alongside the tool name instead of
    /// nesting them under a key.
    @Test func acceptsInlineArguments() {
        let turn = OdysseusCoachBackend.parse(#"{"tool": "get_routine", "name": "Legs"}"#)
        #expect(turn.toolCalls.first?.arguments.string("name") == "Legs")
    }

    @Test func prosePassesThroughAsAnAnswer() {
        let turn = OdysseusCoachBackend.parse("You've trained chest twice this week already.")
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.reply?.message == "You've trained chest twice this week already.")
        #expect(turn.reply?.suggestions.isEmpty == true)
    }

    /// The answer contract asks for a `{message, suggestions}` object, and that
    /// object must read as a reply — not be mistaken for a tool call — and its
    /// chips must survive into the turn.
    @Test func readsAStructuredAnswer() {
        let turn = OdysseusCoachBackend.parse("""
            {"message": "Your chest is recovered — good to push.", \
            "suggestions": ["Build me a push day", "How's my bench trending?"]}
            """)
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.reply?.message == "Your chest is recovered — good to push.")
        #expect(turn.reply?.suggestions == ["Build me a push day", "How's my bench trending?"])
    }

    /// JSON naming a tool that doesn't exist is treated as an answer rather than
    /// a failure — a model explaining itself in JSON is still an answer, and
    /// surfacing a hallucinated tool name helps nobody. With no `message` key to
    /// read, the whole reply becomes the message.
    @Test func unknownToolFallsBackToProse() {
        let reply = #"{"tool": "delete_everything", "arguments": {}}"#
        let turn = OdysseusCoachBackend.parse(reply)
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.reply?.message == reply)
    }

    @Test func fencedJSONStillParses() {
        let turn = OdysseusCoachBackend.parse("""
            ```json
            {"tool": "get_muscle_fatigue", "arguments": {}}
            ```
            """)
        #expect(turn.toolCalls.first?.name == "get_muscle_fatigue")
    }

    /// A reasoning model whose template pre-opens the think block sometimes
    /// emits its tool call *before* a bare </think> with nothing after it. The
    /// reasoning-stripper would treat everything before the tag as scratch work
    /// and discard the call; recovery keeps it. Regression for a real local
    /// model reply that rendered the raw JSON as prose instead of running it.
    @Test func toolCallBeforeOrphanThinkCloseStillParses() {
        let turn = OdysseusCoachBackend.parse("""
            {"tool": "get_muscle_fatigue", "arguments": {}}
            </think>
            """)
        #expect(turn.toolCalls.first?.name == "get_muscle_fatigue")
        #expect(turn.reply == nil)
    }

    /// A draft object genuinely inside a paired think block is still dropped —
    /// recovery only rescues a payload the orphan-close heuristic ate, never one
    /// that real reasoning removal was meant to remove.
    @Test func draftInsidePairedThinkIsStillIgnored() {
        let turn = OdysseusCoachBackend.parse("""
            <think>{"tool": "delete_routine", "arguments": {"name": "x"}}</think>
            {"tool": "list_routines", "arguments": {}}
            """)
        #expect(turn.toolCalls.first?.name == "list_routines")
    }
}

struct OnDeviceCoachParsingTests {

    private let tools = OnDeviceCoachBackend.availableTools(from: CoachTool.catalog)

    @Test func readsAToolCall() {
        let reply = OnDeviceCoachBackend.Reply(
            tool: "get_routine",
            arguments: #"{"name": "Push Day"}"#,
            reply: "",
            suggestions: []
        )
        let turn = OnDeviceCoachBackend.parse(reply, tools: tools)
        #expect(turn.toolCalls.first?.name == "get_routine")
        #expect(turn.toolCalls.first?.arguments.string("name") == "Push Day")
        // A tool turn isn't the coach speaking, so it carries no reply.
        #expect(turn.reply == nil)
    }

    @Test func emptyToolMeansProse() {
        let reply = OnDeviceCoachBackend.Reply(
            tool: "",
            arguments: "{}",
            reply: "Your chest is still recovering.",
            suggestions: ["What can I train instead?"]
        )
        let turn = OnDeviceCoachBackend.parse(reply, tools: tools)
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.reply?.message == "Your chest is still recovering.")
        // The guided-generation suggestions map straight onto the reply's.
        #expect(turn.reply?.suggestions == ["What can I train instead?"])
    }

    /// A name outside the offered set reads as "no call", so the prose still
    /// reaches the lifter instead of the turn dying on a bad name.
    @Test func unofferedToolFallsBackToProse() {
        let reply = OnDeviceCoachBackend.Reply(
            tool: "update_profile", // deliberately withheld on-device
            arguments: "{}",
            reply: "You'd change that in Settings.",
            suggestions: []
        )
        let turn = OnDeviceCoachBackend.parse(reply, tools: tools)
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.reply?.message == "You'd change that in Settings.")
    }

    /// The on-device set is narrowed for context, but everything needed to read
    /// training and build, edit, and start a workout has to survive the cut.
    @Test func narrowedSetKeepsTheEssentials() {
        let names = Set(tools.map(\.name))
        for essential in ["search_exercises", "get_muscle_fatigue", "create_routine",
                          "generate_workout", "start_workout", "add_exercise_to_routine"] {
            #expect(names.contains(essential), "on-device lost \(essential)")
        }
        #expect(names.count < CoachTool.catalog.count)
    }
}

/// The one shape every tier's spoken answer collapses to. The tiers differ in
/// how they emit it — Claude and the self-hosted model as text, on-device as a
/// guided struct — but a text answer is read here, so these guard the seam
/// where an unpredictable model reply becomes a predictable DTO.
struct CoachReplyTests {

    @Test func readsMessageAndSuggestions() {
        let reply = CoachReply.parse(fromText: """
            {"message": "Squat, then accessories.", "suggestions": ["Make it harder", "Add a finisher"]}
            """)
        #expect(reply.message == "Squat, then accessories.")
        #expect(reply.suggestions == ["Make it harder", "Add a finisher"])
    }

    /// A model that ignored the contract and answered in plain prose still gets
    /// through — the whole text becomes the message, with no chips. This is the
    /// fallback that keeps a malformed answer from failing the turn.
    @Test func plainProseBecomesTheMessage() {
        let reply = CoachReply.parse(fromText: "You're recovered — go heavy.")
        #expect(reply.message == "You're recovered — go heavy.")
        #expect(reply.suggestions.isEmpty)
    }

    /// Small models fence and preface their JSON; the reply object is found
    /// regardless, the same way tool calls are.
    @Test func findsObjectInFencedOrTrailingText() {
        let fenced = CoachReply.parse(fromText: """
            Sure — here's my take:
            ```json
            {"message": "Rest today.", "suggestions": []}
            ```
            """)
        #expect(fenced.message == "Rest today.")
        #expect(fenced.suggestions.isEmpty)
    }

    /// Blank, duplicate, and overflowing chips are the shape errors a model
    /// makes; none of them should reach the screen.
    @Test func suggestionsAreTidiedAndCapped() {
        let reply = CoachReply(
            message: "Done.",
            suggestions: ["Push day", "  ", "push day", "Pull day", "Legs day", "Arms day"]
        )
        // Blank dropped, case-insensitive duplicate dropped, capped at the max.
        #expect(reply.suggestions == ["Push day", "Pull day", "Legs day"])
        #expect(reply.suggestions.count <= CoachReply.maxSuggestions)
    }

    /// An object with no `message` key isn't a reply — the whole text falls
    /// through to the message, so a stray object can't blank out the answer.
    @Test func objectWithoutMessageFallsBackToWholeText() {
        let text = #"{"note": "thinking out loud"}"#
        let reply = CoachReply.parse(fromText: text)
        #expect(reply.message == text)
    }
}

/// Persisting recent chats. The transcript has to survive a JSON round trip
/// whole — tool calls, coerced argument types, Claude's raw content blocks —
/// because a reopened chat is *continued*, and a lossy save would break the
/// backends' replay. The title is what the history list shows.
struct CoachHistoryTests {

    /// A transcript with every wrinkle — plumbing, a tool call carrying mixed
    /// argument types, a paired result, a structured reply, and raw content —
    /// decodes back byte-for-byte equal.
    @Test func transcriptSurvivesACodableRoundTrip() throws {
        let transcript = [
            CoachMessage(role: .user, text: "Context…", isPlumbing: true),
            CoachMessage(role: .user, text: "Build me a push day"),
            CoachMessage(
                role: .assistant,
                toolCalls: [CoachToolCall(
                    id: "toolu_1",
                    name: "generate_workout",
                    arguments: [
                        "focus": .string("Push"),
                        "exercise_count": .number(5),
                        "allow_supersets": .bool(true),
                        "note": .null,
                        "muscles": .array([.string("Chest"), .string("Shoulders")]),
                    ]
                )],
                rawContent: [.object(["type": .string("thinking"), "signature": .string("abc")])]
            ),
            CoachMessage(
                role: .user,
                toolResults: [CoachToolResult(callID: "toolu_1", text: "Saved.", isError: false)]
            ),
            CoachMessage(
                role: .assistant,
                text: "Here's your push day.",
                suggestions: ["Make it harder", "Start it now"]
            ),
        ]

        let data = try JSONEncoder().encode(transcript)
        let restored = try JSONDecoder().decode([CoachMessage].self, from: data)
        #expect(restored == transcript)
    }

    @Test func conversationRoundTrips() throws {
        let conversation = CoachConversation(
            id: UUID(),
            title: "Build me a push day",
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            messages: [CoachMessage(role: .user, text: "Build me a push day")]
        )
        let restored = try JSONDecoder().decode(
            CoachConversation.self, from: JSONEncoder().encode(conversation)
        )
        #expect(restored == conversation)
    }

    /// The title comes from the first thing the lifter actually said — not the
    /// plumbing situation block that opens every chat.
    @Test func titleSkipsPlumbingAndUsesFirstQuestion() {
        let title = CoachConversation.title(from: [
            CoachMessage(role: .user, text: "Context for this conversation…", isPlumbing: true),
            CoachMessage(role: .user, text: "What haven't I trained this week?"),
        ])
        #expect(title == "What haven't I trained this week?")
    }

    @Test func titleFallsBackWhenNothingSaid() {
        #expect(CoachConversation.title(from: []) == "New chat")
        // Tool-only and plumbing turns don't count as something said.
        let title = CoachConversation.title(from: [
            CoachMessage(role: .user, text: "Context…", isPlumbing: true),
            CoachMessage(role: .assistant, toolCalls: [
                CoachToolCall(id: "1", name: "list_routines", arguments: [:]),
            ]),
        ])
        #expect(title == "New chat")
    }

    @Test func longTitleIsTruncated() {
        let long = String(repeating: "a", count: 100)
        let title = CoachConversation.title(from: [CoachMessage(role: .user, text: long)])
        #expect(title.count <= 48)
        #expect(title.hasSuffix("…"))
    }
}

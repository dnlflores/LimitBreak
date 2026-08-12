import Foundation

/// One tool invocation the coach asked for.
///
/// `id` is the backend's own correlation handle — Anthropic's `tool_use.id`
/// when there is one, a locally minted identifier when the backend has no tool
/// API. Either way it is what pairs a result back to its call.
struct CoachToolCall: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
    let arguments: [String: JSONValue]

    /// How the call reads in the transcript while it runs — "Reading your
    /// routines", not `list_routines`.
    var activityLabel: String {
        CoachToolCall.labels[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static let labels: [String: String] = [
        "list_routines": "Reading your routines",
        "get_routine": "Opening a routine",
        "search_exercises": "Searching the movement library",
        "get_exercise_history": "Reading your lift history",
        "get_recent_sessions": "Reviewing recent workouts",
        "get_muscle_fatigue": "Checking muscle recovery",
        "get_profile": "Reading your training profile",
        "get_weekly_plan": "Reading your training week",
        "get_active_session": "Checking your live session",
        "create_routine": "Building a routine",
        "update_routine": "Rewriting a routine",
        "delete_routine": "Deleting a routine",
        "add_exercise_to_routine": "Adding a movement",
        "remove_exercise_from_routine": "Removing a movement",
        "generate_workout": "Programming a workout",
        "start_workout": "Starting your workout",
        "set_plan_day": "Setting a training day",
        "clear_plan_day": "Clearing a training day",
        "update_profile": "Updating your profile",
        "create_exercise": "Adding a movement to the library",
        "log_activity": "Logging an activity",
    ]
}

/// What came back from running a `CoachToolCall`.
///
/// `text` is written for the model, not the lifter: on failure it says what
/// went wrong *and* what to do instead, because the model reads it and gets one
/// cheap chance to correct itself before the turn is wasted.
struct CoachToolResult: Sendable, Equatable, Codable {
    let callID: String
    let text: String
    var isError: Bool = false
}

/// One turn in the conversation, in the app's own shape rather than any single
/// backend's wire format.
///
/// Tool traffic lives on the same timeline as the prose so the Anthropic
/// backend can rebuild an exact `messages` array — that path requires every
/// `tool_use` block to be echoed back verbatim alongside its `tool_result`, so
/// dropping tool turns from the transcript would break the conversation rather
/// than just lose detail.
struct CoachMessage: Identifiable, Sendable, Codable, Equatable {
    enum Role: String, Sendable, Codable { case user, assistant }

    let id: UUID
    var role: Role
    var text: String
    /// The tappable follow-ups offered under an assistant turn — the
    /// `suggestions` of the `CoachReply` this turn delivered. Empty for the
    /// lifter's own turns and for turns that only ran tools.
    var suggestions: [String]
    /// Tools this assistant turn asked for.
    var toolCalls: [CoachToolCall]
    /// Results carried by this user turn, answering the previous assistant turn.
    var toolResults: [CoachToolResult]
    /// Text the app wrote for the model rather than something either party
    /// said — the opening situation block. It has to reach the request and must
    /// never reach the screen, where it reads as the lifter reciting their own
    /// profile back at themselves.
    var isPlumbing: Bool
    /// The backend's own content blocks for an assistant turn, kept verbatim.
    ///
    /// Anthropic requires an assistant turn to be echoed back *unchanged* on
    /// the next request. Rebuilding it from `text` and `toolCalls` would look
    /// right and silently drop the thinking blocks that ride alongside them —
    /// which, with thinking on by default, is rejected rather than degraded.
    /// Empty for backends with no wire format of their own to preserve.
    var rawContent: [JSONValue]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        suggestions: [String] = [],
        toolCalls: [CoachToolCall] = [],
        toolResults: [CoachToolResult] = [],
        isPlumbing: Bool = false,
        rawContent: [JSONValue] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.suggestions = suggestions
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.isPlumbing = isPlumbing
        self.rawContent = rawContent
    }

    /// Whether this turn is worth rendering. A user turn carrying nothing but
    /// tool results belongs in the request, not on screen.
    var isVisible: Bool {
        if isPlumbing { return false }
        if role == .user { return !text.isEmpty }
        return !text.isEmpty || !toolCalls.isEmpty
    }
}

/// What one round trip to a backend produced: a spoken reply, tool calls, or —
/// on an intermediate turn — only tool calls.
///
/// `reply` is the structured answer the coach delivered this turn, present on
/// exactly the turns where it spoke to the lifter. A turn that only ran tools
/// leaves it nil and continues the loop; a turn that spoke ends it. The two are
/// mutually exclusive in practice — every tier either calls a tool or answers,
/// never both in one turn — so the loop keys off which one is present.
struct CoachTurn: Sendable {
    var reply: CoachReply?
    var toolCalls: [CoachToolCall] = []
    /// The backend's verbatim content blocks, when it has a wire format that
    /// must be echoed back intact. See `CoachMessage.rawContent`.
    var rawContent: [JSONValue] = []

    var isEmpty: Bool { reply == nil && toolCalls.isEmpty }
}

/// The three coaching tiers behind one interface.
///
/// Each takes the whole transcript and returns the next assistant turn. The
/// transcript is the single source of truth: a backend may cache a server-side
/// session for cheapness, but must be able to rebuild from the transcript
/// alone, so the agent can switch tiers mid-chat — a tailnet drops, a key is
/// added — without the history becoming unusable.
///
/// Main-actor bound because two of the three read SwiftData-adjacent
/// configuration and all three are driven from `CoachAgent`.
@MainActor
protocol CoachBackend: AnyObject {
    /// Which tier answered, for the line under a reply.
    var displayName: String { get }

    func nextTurn(
        system: String,
        transcript: [CoachMessage],
        tools: [CoachTool]
    ) async throws -> CoachTurn
}

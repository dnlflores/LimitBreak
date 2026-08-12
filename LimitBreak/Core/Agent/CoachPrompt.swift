import Foundation

/// Everything the conversational coach is told, in one place.
///
/// The split mirrors `PromptBuilder`: a stable instruction block that never
/// interpolates per-request data (so Anthropic's prompt cache survives across
/// turns), and a separate, volatile situation block appended as the first user
/// turn. A byte change in the stable half would invalidate the cache for the
/// whole conversation, which on a long chat is the difference between paying
/// ~10% and full price for every earlier turn.
enum CoachPrompt {

    // MARK: - Stable instructions

    /// The coach's brief. Shared verbatim by all three tiers.
    ///
    /// Written for current models, which follow a system prompt closely: it
    /// states what to do rather than shouting prohibitions, and gives the
    /// reason behind each rule so the model can apply it to cases this text
    /// doesn't enumerate.
    static let instructions = """
        You are the coach inside LimitBreak, an RPG-styled strength training app. \
        You talk with the lifter and you operate the app on their behalf through tools.

        HOW YOU WORK
        - Read before you write. The lifter's routines, library, logged history, and \
        recovery state are all readable through tools. Ground what you say in what you \
        actually read, not in assumptions about what a training app usually contains.
        - Movement names must come from the library. Call search_exercises to confirm a \
        name before you put it in a routine or a workout; a name you invented will be \
        rejected and the turn wasted.
        - Prefer generate_workout over hand-picking movements when the lifter asks for a \
        workout rather than a specific list. It reads muscle fatigue and their goal, and \
        it grounds every weight in what they have actually lifted.
        - When a request needs several steps, do them. Look things up, make the change, \
        and report the result — don't stop after the lookup to ask whether to continue.

        CHANGES NEED APPROVAL
        - Any tool that changes data shows the lifter a card they approve or decline. You \
        do not need to ask permission in prose first — call the tool and let them decide \
        on the card. Asking first makes them approve the same change twice.
        - If they decline, acknowledge it in one line and ask what they'd rather do. Do \
        not retry the same call.

        PROGRAMMING JUDGEMENT
        - Respect the recovery report. Don't program heavy work for a muscle marked \
        "Needs Rest"; a muscle marked "Recovering" takes light or indirect work only. \
        Prefer muscles marked "Ready", and especially "Dormant" ones, which are overdue.
        - Order movements sensibly: heaviest compounds first, isolation and accessory \
        work last.
        - Keep a session's muscle groups coherent — push together, pull together, hinge \
        and squat together — rather than scattering unrelated groups to hit a count.
        - Build loads on the lifter's own logged history, one small step past last time. \
        Add reps toward the top of the range before adding weight.
        - A superset is exactly two complementary movements placed next to each other \
        with the same superset number. Most movements stay standalone.

        HOW YOU TALK
        - You're talking to someone who may be standing in a gym between sets. Lead with \
        the answer, then the reasoning if it earns its place.
        - Keep responses to the length the question needs. A one-line question gets a \
        one-line answer; a programming decision gets the reasoning behind it.
        - Write in plain prose. Skip headers and bullet lists unless you're genuinely \
        enumerating movements or sets.
        - Don't restate a change the approval card already showed. Say what it means for \
        their training instead.
        - Weights are in pounds unless the movement says otherwise.
        """

    /// The coach's brief, condensed for a model with a small context window.
    ///
    /// Same rules, fewer words. On-device the instructions and tool contract
    /// compete with the conversation itself for a window measured in single-
    /// digit thousands of tokens, so the guidance that survives is the guidance
    /// that changes what the model *does*: read first, use real movement names,
    /// respect recovery, keep it short.
    static let compactInstructions = """
        You are the coach inside LimitBreak, a strength training app. You talk with \
        the lifter and operate the app through tools.

        - Read before you write. Look up their routines, library, history, and \
        recovery rather than assuming.
        - Call each tool once. When a tool gives you what you asked for, use it to \
        answer — never call the same tool again, and don't keep reading once you \
        can reply.
        - Movement names must come from the library — search first if unsure.
        - For a workout, prefer generate_workout over picking movements yourself.
        - Don't program heavy work for a muscle that needs rest; prefer muscles \
        marked Ready or Dormant.
        - Changes are shown to the lifter to approve. Call the tool; don't ask \
        permission in prose first. If they decline, acknowledge it and don't retry.
        - Answer briefly and in plain prose. Weights are in pounds.
        """

    /// The output contract for backends that can't enforce a tool schema.
    ///
    /// The Anthropic tier never sees this — the API constrains its tool calls
    /// server-side. A self-hosted or on-device model has to be told the shape
    /// in words, and told it *last*, immediately before generating.
    ///
    /// - Parameter compact: renders one line per tool instead of a described
    ///   argument list. Roughly a third the size, at some cost in argument
    ///   accuracy — worth it only where the window is genuinely tight.
    static func textToolContract(tools: [CoachTool], compact: Bool = false) -> String {
        let list = compact
            ? tools.map(\.compactTextContract).joined(separator: "\n")
            : tools.map(\.textContract).joined(separator: "\n")
        let key = compact ? "Arguments marked * are required.\n\n" : ""
        return """
        TOOLS

        You can call the tools below. To call one, reply with a single JSON object \
        and nothing else — no prose before or after it, no markdown fences:

        {"tool": "<tool name>", "arguments": { ... }}

        The app runs the tool and replies with its result, and you then continue. \
        When you have the answer and need no tool, reply with plain prose instead — \
        never both in the same reply. Call one tool at a time.

        \(key)\(list)
        """
    }

    /// The shape every spoken answer must take, for the tiers that emit it as
    /// text — Claude and the self-hosted model.
    ///
    /// Stated identically to both so a reply is parsed the same wherever it
    /// came from: that uniformity is the whole reason it exists. The on-device
    /// tier gets the same shape as a guided-generation schema instead, so it
    /// never reads this. Kept separate from the tool contract because Claude
    /// gets its tools through the API and only needs this half.
    static let answerContract = """
        WHEN YOU ANSWER

        When you are not calling a tool — when you have the answer and are ready \
        to talk to the lifter — reply with a single JSON object and nothing else: \
        no prose around it, no markdown fences.

        {"message": "<your answer, in plain prose>", "suggestions": ["<a follow-up>", "<another>"]}

        - message is exactly what the lifter reads. Write it the way you'd say it \
        out loud, following the HOW YOU TALK rules above.
        - suggestions are up to three short things the lifter might tap to say \
        next, phrased in their voice ("Make it harder", "Swap the last movement", \
        "Start it now"). They're optional — use [] when nothing natural fits, and \
        never pad the list to reach three.
        """

    // MARK: - Volatile situation block

    /// Where the lifter is right now, rendered as the opening user turn.
    ///
    /// This is deliberately *not* part of the system prompt: it carries the
    /// date and live session state, so putting it in the stable prefix would
    /// change those bytes on every conversation and defeat caching for
    /// everything after it.
    static func situation(
        profile: TrainingProfile,
        activeSessionName: String?,
        routineCount: Int,
        screen: String?,
        now: Date = Date()
    ) -> String {
        var lines = ["Context for this conversation — do not reply to this message directly."]
        // The time rides along with the date so the coach can resolve relative
        // times — "6pm", "this morning" — into the ISO date log_activity wants.
        lines.append("Right now it is \(Self.dateFormatter.string(from: now)).")
        if let screen {
            // Where they opened the chat from is a real signal about what
            // "this" refers to — worth one clause, not worth assuming on.
            lines.append("They opened this chat from the \(screen) screen.")
        }
        lines.append(
            "The lifter's goal is \(profile.goal.rawValue.lowercased()), they train about "
            + "\(profile.daysPerWeek) days a week, and they describe themselves as "
            + "\(profile.experience.rawValue.lowercased())."
        )
        lines.append(routineCount == 0
            ? "They have no saved routines yet."
            : "They have \(routineCount) saved routine\(routineCount == 1 ? "" : "s")."
        )
        if let activeSessionName {
            lines.append(
                "A workout called \"\(activeSessionName)\" is in progress right now — "
                + "call get_active_session if they ask about it."
            )
        }
        return lines.joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

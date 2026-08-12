import Foundation

/// One capability the coach can invoke, described once and rendered three ways:
/// as an Anthropic `tools` entry, as a line in the text contract a self-hosted
/// model reads, and as a dynamic schema for Apple's on-device tool calling.
///
/// Keeping a single catalog is what makes the three backends genuinely
/// comparable — a tool added here reaches every tier, and the lifter's
/// confirmation rules can't drift apart between them.
struct CoachTool: Sendable {

    /// One argument. `type` is a JSON Schema primitive (`string`, `integer`,
    /// `number`, `boolean`, `array`, `object`).
    struct Parameter: Sendable {
        let name: String
        let type: String
        let description: String
        var required: Bool = false
        /// Allowed values, when the argument is a closed set. Stated in the
        /// schema *and* in the description so schema-less backends see it too.
        var options: [String] = []
        /// Element schema for `array` parameters, as a JSON Schema fragment.
        var items: [String: Any]? = nil
    }

    let name: String
    /// What the tool does and when to reach for it. This is the single
    /// strongest signal for whether the model calls it correctly, so each one
    /// states its trigger condition, not just its behavior.
    let description: String
    let parameters: [Parameter]
    /// Whether invoking this tool changes the lifter's data. Mutating tools
    /// never run on their own — `CoachToolRunner` stages them as a
    /// `PendingChange` the lifter has to approve first.
    let mutates: Bool

    // MARK: - Rendering

    /// This tool's JSON Schema, shared by the Anthropic `input_schema` and the
    /// on-device dynamic schema.
    var inputSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            var entry: [String: Any] = [
                "type": parameter.type,
                "description": parameter.schemaDescription,
            ]
            if !parameter.options.isEmpty { entry["enum"] = parameter.options }
            if let items = parameter.items { entry["items"] = items }
            properties[parameter.name] = entry
        }
        return [
            "type": "object",
            "properties": properties,
            "required": parameters.filter(\.required).map(\.name),
        ]
    }

    /// The Anthropic `tools` array entry.
    var anthropicDefinition: [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }

    /// One tool, rendered for a model that has no tool API and reads the
    /// contract as prose — the full form, with every argument described.
    var textContract: String {
        let arguments = parameters.map { parameter -> String in
            let flag = parameter.required ? "required" : "optional"
            return "    - \(parameter.name) (\(parameter.type), \(flag)): \(parameter.schemaDescription)"
        }
        let header = "- \(name)\(mutates ? " [changes data]" : ""): \(description)"
        return arguments.isEmpty
            ? header + "\n    (no arguments)"
            : ([header] + arguments).joined(separator: "\n")
    }

    /// One tool in a single line, for a model with a small context window.
    ///
    /// What survives the cut is what a call *fails* without. Argument names
    /// stay, because a wrong name fails outright where a missing description
    /// only costs some accuracy. Required arguments are starred, and a required
    /// argument's closed value set is spelled out — a guessed value there is a
    /// rejected call and a wasted turn, which is far more expensive than the
    /// handful of characters the list costs. Optional enums are left to the
    /// tool's own error message to correct.
    ///
    /// The first sentence of the description is kept: it carries the trigger
    /// condition, which is what the model actually chooses on.
    var compactTextContract: String {
        let arguments = parameters
            .map { parameter -> String in
                let star = parameter.required ? "*" : ""
                let values = parameter.required && !parameter.options.isEmpty
                    ? "=\(parameter.options.joined(separator: "|"))"
                    : ""
                return "\(parameter.name)\(star)\(values)"
            }
            .joined(separator: ", ")
        let summary = description.split(separator: ".").first.map(String.init) ?? description
        return "- \(name)(\(arguments))\(mutates ? " [changes data]" : ""): \(summary)."
    }
}

private extension CoachTool.Parameter {
    /// The description with the allowed values appended, so a backend that
    /// can't enforce an `enum` still sees the closed set.
    var schemaDescription: String {
        options.isEmpty
            ? description
            : "\(description) One of: \(options.joined(separator: ", "))."
    }
}

// MARK: - The catalog

extension CoachTool {

    /// Every tool the coach may call, read tools first.
    ///
    /// The set is deliberately bounded. Each entry maps onto a `WorkoutManager`
    /// operation the app already performs itself, so an agent-driven change and
    /// a hand-made one land in exactly the same place — there is no second
    /// write path to keep in sync.
    static let catalog: [CoachTool] = readTools + writeTools

    static func named(_ name: String) -> CoachTool? {
        catalog.first { $0.name == name }
    }

    /// The whole catalog as prose, for backends without a tool API.
    static var textContract: String {
        catalog.map(\.textContract).joined(separator: "\n")
    }

    // MARK: Read tools

    private static let readTools: [CoachTool] = [
        CoachTool(
            name: "list_routines",
            description: "List the lifter's saved routines with their movement counts. Call this before editing, starting, or referring to a routine, so you use its exact saved name.",
            parameters: [],
            mutates: false
        ),
        CoachTool(
            name: "get_routine",
            description: "Read one routine in full: every movement in order with its target sets, reps, working weight, and superset pairing. Call this before changing a routine so you edit from what is actually saved.",
            parameters: [
                Parameter(name: "name", type: "string", description: "The routine's name.", required: true),
            ],
            mutates: false
        ),
        CoachTool(
            name: "search_exercises",
            description: "Search the movement library. Call this before naming any movement in a routine or workout — only movements that exist in the library can be used, and this is how you confirm a name and its exact spelling.",
            parameters: [
                Parameter(name: "query", type: "string", description: "Text to match against movement names."),
                Parameter(name: "muscle", type: "string", description: "Restrict to movements training this muscle.", options: MuscleGroup.allCases.map(\.displayName)),
                Parameter(name: "equipment", type: "string", description: "Restrict to movements using this equipment.", options: EquipmentType.allCases.map(\.rawValue)),
                Parameter(name: "limit", type: "integer", description: "How many results to return. Defaults to 25."),
            ],
            mutates: false
        ),
        CoachTool(
            name: "get_exercise_history",
            description: "Read the lifter's logged history for one movement: recent sessions newest first, and their best recorded set. Call this before prescribing a weight, so the number builds on what they have actually lifted.",
            parameters: [
                Parameter(name: "name", type: "string", description: "The movement's name.", required: true),
                Parameter(name: "limit", type: "integer", description: "How many past sessions to return. Defaults to 8."),
            ],
            mutates: false
        ),
        CoachTool(
            name: "get_recent_sessions",
            description: "List recently completed workouts with the muscles trained, working-set counts, and reported effort. Call this when the lifter asks what they have been doing, or when you need to avoid repeating recent work.",
            parameters: [
                Parameter(name: "limit", type: "integer", description: "How many sessions to return. Defaults to 8."),
            ],
            mutates: false
        ),
        CoachTool(
            name: "get_muscle_fatigue",
            description: "Read the per-muscle recovery report: how each muscle is recovering, when it was last trained, and its weekly set count. Call this before programming any session so you steer around muscles that need rest.",
            parameters: [],
            mutates: false
        ),
        CoachTool(
            name: "get_profile",
            description: "Read the lifter's goal, experience level, weekly training frequency, and body weight. Call this at the start of any programming request — the goal sets the rep ranges and loads you should prescribe.",
            parameters: [],
            mutates: false
        ),
        CoachTool(
            name: "get_weekly_plan",
            description: "Read the lifter's repeating training week: which weekdays are training days, each day's focus, and the workout assigned to it.",
            parameters: [],
            mutates: false
        ),
        CoachTool(
            name: "get_active_session",
            description: "Read the workout currently in progress, if any: its movements, what has been logged so far, and what is left. Call this when the lifter asks about the session they are in right now.",
            parameters: [],
            mutates: false
        ),
    ]

    // MARK: Write tools

    /// Everything here stages a change for the lifter to approve. Write the
    /// arguments as the final intended state — a rejected change is simply not
    /// applied, so there is nothing to roll back.
    private static let writeTools: [CoachTool] = [
        CoachTool(
            name: "create_routine",
            description: "Save a new reusable routine. Every movement name must come from the library — call search_exercises first if you are not certain a name exists.",
            parameters: [
                Parameter(name: "name", type: "string", description: "Name for the routine.", required: true),
                Parameter(name: "exercises", type: "array", description: "The movements in the order they should be performed.", required: true, items: movementItemSchema),
                Parameter(name: "notes", type: "string", description: "An optional note shown with the routine."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "update_routine",
            description: "Rewrite an existing routine. The exercises list replaces the routine's movements entirely, so include every movement it should end up with — call get_routine first and edit from that. To change only one slot, prefer add_exercise_to_routine or remove_exercise_from_routine.",
            parameters: [
                Parameter(name: "name", type: "string", description: "The routine to change, by its current name.", required: true),
                Parameter(name: "exercises", type: "array", description: "The complete new movement list, in order. Omit to leave the movements untouched.", items: movementItemSchema),
                Parameter(name: "new_name", type: "string", description: "A new name for the routine."),
                Parameter(name: "notes", type: "string", description: "Replacement note text."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "delete_routine",
            description: "Delete a saved routine. This does not touch any workout already logged from it.",
            parameters: [
                Parameter(name: "name", type: "string", description: "The routine to delete.", required: true),
            ],
            mutates: true
        ),
        CoachTool(
            name: "add_exercise_to_routine",
            description: "Add one movement to the end of an existing routine, leaving its other movements alone.",
            parameters: [
                Parameter(name: "routine", type: "string", description: "The routine to add to.", required: true),
                Parameter(name: "exercise", type: "string", description: "The movement's name, exactly as it appears in the library.", required: true),
                Parameter(name: "sets", type: "integer", description: "Target working sets. Defaults to 3."),
                Parameter(name: "reps", type: "integer", description: "Target reps per set."),
                Parameter(name: "weight", type: "number", description: "Target working weight in pounds. Use 0 for bodyweight movements."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "remove_exercise_from_routine",
            description: "Remove one movement from a routine, leaving its other movements alone.",
            parameters: [
                Parameter(name: "routine", type: "string", description: "The routine to remove from.", required: true),
                Parameter(name: "exercise", type: "string", description: "The movement to remove.", required: true),
            ],
            mutates: true
        ),
        CoachTool(
            name: "generate_workout",
            description: "Build a fresh workout with the app's own coaching engine, which reads muscle fatigue, the lifter's goal, and their logged history, and grounds every weight in what they have actually lifted. Prefer this over hand-picking movements when the lifter asks for a workout rather than a specific list.",
            parameters: [
                Parameter(name: "focus", type: "string", description: "The session's focus.", required: true, options: WorkoutFocus.allCases.map(\.label)),
                Parameter(name: "exercise_count", type: "integer", description: "How many movements to program. Defaults to 5."),
                Parameter(name: "duration_minutes", type: "integer", description: "Rough target length for the session."),
                Parameter(name: "allow_supersets", type: "boolean", description: "Whether movements may be paired into supersets. Defaults to true."),
                Parameter(name: "with_partner", type: "boolean", description: "Whether a partner is present to spot, which licenses heavier free-weight work. Defaults to false."),
                Parameter(name: "save_as", type: "string", description: "Save the result as a routine under this name. Omit to save it under the generated session title."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "start_workout",
            description: "Begin a live workout right now, which opens the logging screen. Provide either a saved routine or an explicit movement list, not both.",
            parameters: [
                Parameter(name: "routine", type: "string", description: "Start from this saved routine."),
                Parameter(name: "exercises", type: "array", description: "Start an ad-hoc session with these movements, in order.", items: ["type": "string"]),
                Parameter(name: "name", type: "string", description: "Name for an ad-hoc session."),
                Parameter(name: "with_partner", type: "boolean", description: "Whether a partner is training along. Defaults to false."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "set_plan_day",
            description: "Assign a routine and focus to one weekday in the lifter's repeating training week, creating the week if they do not have one yet.",
            parameters: [
                Parameter(name: "weekday", type: "string", description: "The day to set.", required: true, options: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]),
                Parameter(name: "focus", type: "string", description: "The day's training focus.", required: true, options: WorkoutFocus.allCases.map(\.label)),
                Parameter(name: "routine", type: "string", description: "An existing routine to run that day. Omit to have the coaching engine generate the day's workout."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "clear_plan_day",
            description: "Turn one weekday of the training week back into a rest day, deleting the workout assigned to it.",
            parameters: [
                Parameter(name: "weekday", type: "string", description: "The day to clear.", required: true, options: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]),
            ],
            mutates: true
        ),
        CoachTool(
            name: "update_profile",
            description: "Change the lifter's training profile. This reshapes every future workout the app produces, so only call it when they ask for the change.",
            parameters: [
                Parameter(name: "goal", type: "string", description: "What they are training for.", options: TrainingGoal.allCases.map(\.rawValue)),
                Parameter(name: "experience", type: "string", description: "Their experience level.", options: ExperienceLevel.allCases.map(\.rawValue)),
                Parameter(name: "days_per_week", type: "integer", description: "How many days a week they intend to train, from 1 to 7."),
            ],
            mutates: true
        ),
        CoachTool(
            name: "create_exercise",
            description: "Add a movement to the library that is not already in it. Call search_exercises first — the library is large, and a movement the lifter names usually already exists under a slightly different name.",
            parameters: [
                Parameter(name: "name", type: "string", description: "The movement's name.", required: true),
                Parameter(name: "muscle", type: "string", description: "The primary muscle it trains.", required: true, options: MuscleGroup.allCases.map(\.displayName)),
                Parameter(name: "equipment", type: "string", description: "The equipment it uses.", required: true, options: EquipmentType.allCases.map(\.rawValue)),
                Parameter(name: "secondary_muscles", type: "array", description: "Other muscles it trains.", items: ["type": "string"]),
                Parameter(name: "tracking", type: "string", description: "How each set is measured. Defaults to weight and reps.", options: TrackingType.allCases.map(\.rawValue)),
            ],
            mutates: true
        ),
        CoachTool(
            name: "log_activity",
            description: "Log a sport or activity session — basketball, a swim, a hike, yoga, and the like — recording the sport, how long it lasted, and when. This is the app's Activity feature, separate from lifting workouts and routines: reach for it whenever the lifter names a sport with a time, like \"add basketball at 6pm for 2 hours\" or \"log an hour of yoga this morning\". It earns XP and sustains their streak just like a lifting session.",
            parameters: [
                Parameter(name: "sport", type: "string", description: "The kind of activity.", required: true, options: SportType.allCases.map(\.rawValue)),
                Parameter(name: "duration_minutes", type: "integer", description: "How long it lasted, in minutes. Convert hours to minutes — two hours is 120.", required: true),
                Parameter(name: "date", type: "string", description: "When it happened, as ISO 8601 like 2026-08-09T18:00. Build it from the date given at the start of this conversation for relative times like \"6pm\" or \"this morning\". Omit for right now."),
            ],
            mutates: true
        ),
    ]

    /// The shape of one movement inside a routine's `exercises` list. Shared by
    /// `create_routine` and `update_routine` so the two can't drift.
    private static let movementItemSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Movement name, exactly as it appears in the library."],
            "sets": ["type": "integer", "description": "Target working sets. Defaults to 3."],
            "reps": ["type": "integer", "description": "Target reps per set."],
            "weight": ["type": "number", "description": "Target working weight in pounds. Use 0 for bodyweight movements."],
            "superset_group": ["type": "integer", "description": "Give exactly two adjacent movements the same number (1, 2, …) to pair them as a superset. Use 0 for a standalone movement."],
        ],
        "required": ["name"],
    ]
}

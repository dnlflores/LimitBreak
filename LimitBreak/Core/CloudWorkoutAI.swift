import Foundation

// MARK: - Inputs

/// Everything the cloud coach knows about the lifter at generation time.
/// Assembled by the caller from SwiftData so this stays testable and free of
/// persistence concerns.
struct TrainingContext {
    var goal: TrainingGoal
    var experience: ExperienceLevel
    var daysPerWeek: Int
    /// Per-muscle recovery state, straight from `MuscleRecovery.statuses()`.
    var muscleStatuses: [MuscleGroup: MuscleStatus]
    /// Recent sessions, newest first — what the lifter has actually been doing.
    var recentSessions: [SessionSummary]
    /// Estimated 1RM per movement (canonical pounds), so loads can be real
    /// numbers instead of "moderate weight".
    var ceilings: [String: Double]
    var withPartner: Bool
    /// Which backend the lifter has chosen to coach with. Carried here so
    /// `WorkoutAI` can route without reaching back into SwiftData.
    var provider: AIProvider = .claude
    /// The track this session should run — heavy (lower reps, more load) or
    /// volume (higher reps, moderate load) — undulated off the last session so
    /// emphasis alternates over time.
    var sessionEmphasis: TrainingEmphasis = .volume
    /// Per-lift progression targets ("Bench Press: aim 3×5 @ 140 lb (last 3×8 @
    /// 135)"), strongest lifts first, so the coach programs each movement one
    /// step past last session instead of guessing from a summary.
    var progressionLines: [String] = []

    /// A finished session, flattened to what the coach needs.
    struct SessionSummary {
        var name: String
        var daysAgo: Int
        var muscleGroups: [String]
        var workingSets: Int
        /// The lifter's end-of-session estimate of reps left in the tank, if they
        /// answered. Lower = closer to failure; drives load progression next time.
        var repsInReserve: Int?
    }

    /// How many past sessions and recorded ceilings to include. Both are
    /// unbounded in the store and go into every request, so they're capped to
    /// keep the prompt (and the bill) predictable.
    static let recentSessionLimit = 8
    static let ceilingLimit = 40
    /// Per-lift progression targets to compute — bounded like the others so a
    /// full training log can't grow the prompt without limit.
    static let progressionLimit = 16

    /// Assembles the coach's view of the lifter from the store.
    static func build(
        profile: TrainingProfile,
        sessions: [WorkoutSession],
        exercises: [Exercise],
        withPartner: Bool,
        now: Date = Date()
    ) -> TrainingContext {
        let finished = sessions
            .filter { $0.startDate <= now }
            .sorted { $0.startDate > $1.startDate }

        let summaries = finished.prefix(recentSessionLimit).map { session -> SessionSummary in
            let groups = Set(session.sets.compactMap(\.exercise).flatMap(\.allMuscleGroups))
            return SessionSummary(
                name: session.name,
                daysAgo: max(0, Int(now.timeIntervalSince(session.startDate) / 86_400)),
                muscleGroups: groups.map(\.displayName).sorted(),
                workingSets: session.sets.filter { !$0.isWarmup }.count,
                repsInReserve: session.repsInReserve
            )
        }

        let ranked = exercises
            .map { ($0.name, $0.ceiling(for: "1RM")) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(ceilingLimit)

        let goal = profile.goal

        // Undulate the whole session's track off the most recent one: if last
        // time leaned heavy (low average reps), this is a volume day, and vice
        // versa. No history → open on the goal's natural track.
        let emphasis: TrainingEmphasis
        if let recent = finished.first {
            let working = recent.sets.filter { !$0.isWarmup }
            let midpoint = Double(goal.repRange.low + goal.repRange.high) / 2
            let avgReps = working.isEmpty
                ? midpoint
                : Double(working.map(\.reps).reduce(0, +)) / Double(working.count)
            emphasis = (avgReps <= midpoint ? TrainingEmphasis.heavy : .volume).flipped
        } else {
            emphasis = goal.defaultEmphasis
        }

        // A concrete last→next target per lift, strongest first, for the
        // movements the coach is most likely to reach for.
        let progressionLines = exercises
            .filter { ex in ex.sets.contains { !$0.isWarmup } }
            .sorted { $0.ceiling(for: "1RM") > $1.ceiling(for: "1RM") }
            .prefix(progressionLimit)
            .compactMap { ex -> String? in
                ProgressionEngine.nextTarget(
                    for: ex, goal: goal, withPartner: withPartner,
                    emphasis: emphasis, now: now
                )?.promptLine(exerciseName: ex.name)
            }

        return TrainingContext(
            goal: goal,
            experience: profile.experience,
            daysPerWeek: profile.daysPerWeek,
            muscleStatuses: MuscleRecovery.statuses(sessions: finished, now: now),
            recentSessions: Array(summaries),
            ceilings: Dictionary(uniqueKeysWithValues: ranked),
            withPartner: withPartner,
            provider: profile.aiProvider,
            sessionEmphasis: emphasis,
            progressionLines: Array(progressionLines)
        )
    }
}

// MARK: - Output

/// A cloud-generated plan. Richer than the on-device `WorkoutPlan`: every
/// movement carries a prescription and a reason.
struct CoachedPlan: Decodable {
    let title: String
    /// Why this session, given fatigue and goal — shown above the plan.
    let rationale: String
    let exercises: [CoachedExercise]
}

struct CoachedExercise: Decodable {
    let name: String
    let sets: Int
    let repRangeLow: Int
    let repRangeHigh: Int
    /// Suggested working weight in pounds. Zero means bodyweight or unloaded.
    let targetLoadPounds: Double
    let restSeconds: Int
    /// One line on why this movement is here.
    let note: String
    /// Superset grouping index: 0 (or absent) = standalone; 1, 2, … pair movements
    /// meant to run back-to-back. Optional so older/looser responses still decode.
    let supersetGroup: Int?
}

// MARK: - Generator

/// The top intelligence tier: a fatigue- and goal-aware programmer backed by
/// Claude. `WorkoutAI` falls through to the on-device generator whenever this
/// is unavailable, so the app never depends on the network.
enum CloudWorkoutAI {

    /// Whether a cloud generation can be attempted at all.
    static var isConfigured: Bool { KeychainStore.hasKey }

    static func generatePlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        context: TrainingContext,
        allowSupersets: Bool = false,
        catalog: [ExerciseBrief]
    ) async throws -> CoachedPlan {
        let plan: CoachedPlan = try await ClaudeClient.structuredRequest(
            system: [
                ClaudeClient.SystemBlock(text: PromptBuilder.coachInstructions),
                // Last stable block carries the cache breakpoint, so the whole
                // system prefix (instructions + catalog) is cached together.
                ClaudeClient.SystemBlock(text: PromptBuilder.catalogBlock(catalog), cacheable: true),
            ],
            userMessage: PromptBuilder.requestBlock(
                focusLabel: focusLabel,
                targetMuscleGroups: targetMuscleGroups,
                exerciseCount: exerciseCount,
                durationMinutes: durationMinutes,
                context: context,
                allowSupersets: allowSupersets
            ),
            schema: planSchema,
            as: CoachedPlan.self
        )

        // The schema can't express "at least one item", and JSON Schema numeric
        // bounds aren't supported — so clamp here rather than trusting output.
        guard !plan.exercises.isEmpty else { throw ClaudeClient.ClientError.malformedResponse }
        return plan
    }

    // MARK: - Response schema

    /// Note the deliberate omissions: JSON Schema numeric bounds (`minimum`,
    /// `maxItems`) aren't supported by structured outputs, so ranges are stated
    /// in the descriptions and clamped after decoding.
    private static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "Short video-game-themed session name, 2 to 4 words.",
            ],
            "rationale": [
                "type": "string",
                "description": "At most two sentences to the lifter on what this session targets and which muscles were avoided.",
            ],
            "exercises": [
                "type": "array",
                "description": "The movements to perform, in the order they should be done.",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Exact movement name, copied verbatim from the catalog.",
                        ],
                        "sets": [
                            "type": "integer",
                            "description": "Number of working sets, between 2 and 5.",
                        ],
                        "repRangeLow": [
                            "type": "integer",
                            "description": "Low end of the target rep range.",
                        ],
                        "repRangeHigh": [
                            "type": "integer",
                            "description": "High end of the target rep range.",
                        ],
                        "targetLoadPounds": [
                            "type": "number",
                            "description": "Suggested working weight in pounds; 0 for unloaded bodyweight movements.",
                        ],
                        "restSeconds": [
                            "type": "integer",
                            "description": "Rest between sets in seconds.",
                        ],
                        "note": [
                            "type": "string",
                            "description": "One short sentence on why this movement is in the session.",
                        ],
                        "supersetGroup": [
                            "type": "integer",
                            "description": "Superset grouping index. Use 0 for a standalone movement. Give two (occasionally three) complementary movements the same index (1, 2, …) to pair them as a superset run back-to-back; keep grouped movements adjacent in the list.",
                        ],
                    ],
                    "required": [
                        "name", "sets", "repRangeLow", "repRangeHigh",
                        "targetLoadPounds", "restSeconds", "note", "supersetGroup",
                    ],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["title", "rationale", "exercises"],
        "additionalProperties": false,
    ]
}

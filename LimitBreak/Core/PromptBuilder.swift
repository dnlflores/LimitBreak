import Foundation

/// Every prompt LimitBreak sends to a language model, in one place.
///
/// Prompt text is deliberately kept out of the networking layer: `ClaudeClient`
/// and `OdysseusClient` know how to move bytes, and nothing else. That split
/// means a template can be reworded, and the wording tested, without touching a
/// URL request — and it keeps the two backends genuinely comparable, since they
/// send the same words to different models.
///
/// The one asymmetry is response shaping. Anthropic constrains output with a
/// JSON schema server-side, so `planSchema` carries the contract. A self-hosted
/// endpoint behind `/api/chat` returns free text, so the same contract has to be
/// stated in words — that's `jsonOutputContract`.
enum PromptBuilder {

    // MARK: - Prompt budget

    /// How much of the lifter's world to include in one prompt.
    ///
    /// This exists because "the model's context window" and "the context the
    /// server actually loaded the model with" are different numbers. A local
    /// runtime commonly loads a 128k-capable model with a 4k window unless told
    /// otherwise, and the failure is silent: the prompt is truncated, the
    /// output contract never reaches the model, and what comes back isn't JSON.
    ///
    /// Rather than depend on the server being configured generously, the
    /// self-hosted path sends a prompt small enough to survive a modest window.
    struct Budget {
        /// Movements to list. The catalog dominates the prompt — 264 entries is
        /// roughly 3,400 tokens, about two thirds of the total.
        var catalogCap: Int
        /// Recorded 1RMs to include, strongest first.
        var ceilingCap: Int
        /// Past sessions to summarize, newest first.
        var recentSessionCap: Int

        /// Everything. Used for Anthropic, where the full catalog is the cached
        /// system prefix — narrowing it per request would change the prefix on
        /// every generation and defeat the cache, costing more than it saves.
        static let full = Budget(catalogCap: .max, ceilingCap: .max, recentSessionCap: .max)

        /// Sized to land under ~2,000 tokens, so the whole prompt still fits a
        /// 4k window with room for the reply. Raise `catalogCap` first if your
        /// server loads models with a larger context — more movements on offer
        /// means better exercise selection.
        static let compact = Budget(catalogCap: 60, ceilingCap: 12, recentSessionCap: 4)
    }

    /// Rough token count for a prompt — about 3.5 characters per token for this
    /// kind of structured English. Only accurate enough to catch an order-of-
    /// magnitude problem, which is the only kind worth catching here.
    static func estimatedTokens(_ text: String) -> Int {
        Int(Double(text.count) / 3.5)
    }

    // MARK: - System prompt
    //
    // Stable across requests. Never interpolate per-request data here: on the
    // Anthropic path a byte change in the system prefix invalidates the prompt
    // cache for everything after it.

    static let coachInstructions = """
        You are the strength coach behind LimitBreak, an RPG-styled training app.
        You design one training session at a time from a fixed catalog of movements.

        Rules:
        - Only ever use exercise names that appear verbatim in the catalog. Never invent a movement.
        - Order movements sensibly: heaviest compounds first, isolation and accessory work last.
        - Respect the muscle-fatigue report. Do not program heavy work for a muscle marked \
        "Needs Rest". A muscle marked "Recovering" can take light or indirect work only. \
        Prefer muscles marked "Ready" or "Dormant" — especially Dormant ones, which have been \
        neglected.
        - Pair muscle groups that work well together in one session (push muscles together, \
        pull muscles together, hinge and squat patterns together). Do not scatter unrelated \
        muscle groups across a session just to hit the requested count.
        - Prescribe a real working weight in pounds for every movement, derived from the \
        lifter's recorded ceiling for that movement and the goal's target percentage. When \
        there is no recorded ceiling, infer a sensible starting weight from their ceilings on \
        similar movements, and be conservative. Use 0 for bodyweight movements carrying no \
        added load.
        - Give the session a short, punchy, video-game-themed title of 2 to 4 words.
        - The rationale is two sentences at most, addressed to the lifter. Say what this \
        session targets and which muscles you steered around and why. Plain language, no jargon.
        - Each movement's note is one short sentence on why it earned its slot.
        """

    /// The movement catalog, rendered as the closed set the coach may pick from.
    static func catalogBlock(_ catalog: [ExerciseBrief]) -> String {
        let lines = catalog
            .map { "- \($0.name) (\($0.muscleGroups.joined(separator: ", ")); \($0.equipment))" }
            .joined(separator: "\n")
        return "Movement catalog — the only movements you may use:\n\(lines)"
    }

    // MARK: - Request block
    //
    // All per-request, volatile content: who the lifter is, what they've done
    // lately, and what they want from this session.

    static func requestBlock(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        context: TrainingContext,
        budget: Budget = .full,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []

        lines.append("GOAL: \(context.goal.rawValue)")
        lines.append(context.goal.coachingBrief)
        lines.append("")
        lines.append("EXPERIENCE: \(context.experience.rawValue)")
        lines.append(context.experience.coachingBrief)
        lines.append("Trains about \(context.daysPerWeek) days per week.")
        lines.append("")

        lines.append("MUSCLE FATIGUE REPORT (as of now):")
        for group in MuscleGroup.allCases {
            guard let status = context.muscleStatuses[group] else { continue }
            let state = status.state(now: now).rawValue
            let recency = status.lastTrained.map { date -> String in
                let days = Int(now.timeIntervalSince(date) / 86_400)
                return days <= 0 ? "today" : (days == 1 ? "1 day ago" : "\(days) days ago")
            } ?? "not in the last week"
            lines.append("- \(group.displayName): \(state) — last trained \(recency), "
                         + "\(status.weeklySets) sets this week")
        }
        lines.append("")

        // Lead with the sessions that actually trained the muscles this
        // workout targets, so a tight budget spends its slots on what the coach
        // recently programmed for *these* muscles rather than an unrelated leg
        // day. Sessions that don't hit the target fill any remaining slots (and
        // are all that's shown for a full-body focus, where nothing is
        // singled out). `recentSessions` is newest-first and `filter` preserves
        // order, so each group stays newest-first.
        let targetNames = Set(targetMuscleGroups.compactMap {
            MuscleGroup(rawValue: $0)?.displayName
        })
        let prioritized: [TrainingContext.SessionSummary]
        if targetNames.isEmpty {
            prioritized = context.recentSessions
        } else {
            let related = context.recentSessions.filter {
                !Set($0.muscleGroups).isDisjoint(with: targetNames)
            }
            let others = context.recentSessions.filter {
                Set($0.muscleGroups).isDisjoint(with: targetNames)
            }
            prioritized = related + others
        }
        let sessions = Array(prioritized.prefix(budget.recentSessionCap))
        if !sessions.isEmpty {
            lines.append("RECENT SESSIONS (newest first):")
            for session in sessions {
                let ago = session.daysAgo == 0 ? "today" : "\(session.daysAgo)d ago"
                let groups = session.muscleGroups.isEmpty
                    ? "no sets logged"
                    : session.muscleGroups.joined(separator: ", ")
                lines.append("- \(ago): \(session.name) — \(groups) (\(session.workingSets) working sets)")
            }
            lines.append("")
        }

        // Strongest first, so a tight budget keeps the lifts that best anchor
        // load prescriptions rather than an arbitrary slice.
        let ceilings = context.ceilings
            .sorted { $0.value > $1.value }
            .prefix(budget.ceilingCap)
        if !ceilings.isEmpty {
            lines.append("RECORDED CEILINGS (estimated 1RM, pounds):")
            for (name, value) in ceilings {
                lines.append("- \(name): \(Int(value.rounded()))")
            }
            lines.append("")
        }

        lines.append("THIS SESSION:")
        lines.append("- Focus: \(focusLabel)")
        if !targetMuscleGroups.isEmpty {
            let display = targetMuscleGroups
                .compactMap { MuscleGroup(rawValue: $0)?.displayName ?? $0 }
                .joined(separator: ", ")
            lines.append("- Requested emphasis: \(display)")
        }
        lines.append("- Select exactly \(exerciseCount) movements.")
        if let durationMinutes {
            lines.append("- Target length: about \(durationMinutes) minutes.")
        }
        lines.append(context.withPartner
            ? "- A training partner is present to spot, so heavy free-weight work is safe to program."
            : "- Training alone with no spotter — keep free-weight loads to what can be racked solo.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Self-hosted output contract

    /// The response shape, spelled out for backends that can't enforce a schema.
    ///
    /// Local models are chattier than hosted ones, so this leans hard on "no
    /// prose" — but the parser doesn't trust it. `JSONExtractor` pulls the object
    /// out of whatever wrapping arrives, which is what actually makes this work.
    static let jsonOutputContract = """
        OUTPUT FORMAT — follow this exactly.

        Reply with a single JSON object and nothing else. No prose before or after \
        it, no explanation, no markdown code fences.

        The object has exactly these keys:
        {
          "title": string — the session name, 2 to 4 words,
          "rationale": string — at most two sentences to the lifter,
          "exercises": [
            {
              "name": string — a movement name copied verbatim from the catalog,
              "sets": integer — working sets, 2 to 5,
              "repRangeLow": integer — low end of the rep range,
              "repRangeHigh": integer — high end of the rep range,
              "targetLoadPounds": number — working weight in pounds, 0 for bodyweight,
              "restSeconds": integer — rest between sets in seconds,
              "note": string — one short sentence on why this movement is here
            }
          ]
        }

        Every key is required on every object. Do not add keys that are not listed \
        here. Do not wrap the object in another object. Numbers are bare JSON \
        numbers, not strings and not written out in words.
        """

    /// The complete single-turn prompt for a schema-less backend.
    ///
    /// `/api/chat` has no system-prompt channel — there is one `message` field —
    /// so the instructions, catalog, output contract, and request are joined into
    /// one string. Order matters: the contract sits immediately before the
    /// request so the format rules are the last thing read before generating.
    static func selfHostedPlanPrompt(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        context: TrainingContext,
        catalog: [ExerciseBrief],
        budget: Budget = .compact,
        now: Date = Date()
    ) -> String {
        // Narrowed to movements that hit the requested muscles, then topped up
        // with accessories. Matching the reply back to real exercises still runs
        // against the *full* library, so trimming what's on offer here can't
        // cause a valid pick to be dropped later.
        let offered = WorkoutAI.focusedCatalog(
            catalog,
            targetMuscleGroups: targetMuscleGroups,
            cap: budget.catalogCap
        )

        return [
            coachInstructions,
            catalogBlock(offered),
            jsonOutputContract,
            requestBlock(
                focusLabel: focusLabel,
                targetMuscleGroups: targetMuscleGroups,
                exerciseCount: exerciseCount,
                durationMinutes: durationMinutes,
                context: context,
                budget: budget,
                now: now
            ),
        ].joined(separator: "\n\n")
    }
}

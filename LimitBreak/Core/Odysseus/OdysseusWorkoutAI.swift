import Foundation

/// The self-hosted coaching tier: the same curated prompts as the Claude tier,
/// sent to a local model on the lifter's own machine.
///
/// The difference that shapes this whole file is that `/api/chat` returns free
/// text. There is no schema to enforce the plan's shape, so what comes back is
/// parsed defensively: `JSONExtractor` finds the object inside whatever prose
/// or fences wrap it, and `LoosePlan` below tolerates the small deviations
/// local models reliably produce — a number sent as a string, a missing note.
///
/// That leniency lives here and nowhere else. `CoachedPlan` stays strict for
/// the Claude path, where the server already guarantees the shape.
enum OdysseusWorkoutAI {

    /// Whether a generation can be attempted: server, token, and model all set.
    static var isConfigured: Bool { OdysseusConfig.isConfigured }

    // MARK: - Generation

    static func generatePlan(
        focusLabel: String,
        targetMuscleGroups: [String],
        exerciseCount: Int,
        durationMinutes: Int?,
        context: TrainingContext,
        catalog: [ExerciseBrief]
    ) async throws -> CoachedPlan {
        guard let token = KeychainStore.odysseusToken,
              let endpointID = OdysseusConfig.endpointID,
              let model = OdysseusConfig.model
        else { throw OdysseusClient.OdysseusError.notConfigured }

        let baseURL = OdysseusConfig.baseURL
        guard !baseURL.isEmpty else { throw OdysseusClient.OdysseusError.notConfigured }

        let prompt = PromptBuilder.selfHostedPlanPrompt(
            focusLabel: focusLabel,
            targetMuscleGroups: targetMuscleGroups,
            exerciseCount: exerciseCount,
            durationMinutes: durationMinutes,
            context: context,
            catalog: catalog
        )

        let reply = try await sendReusingSession(
            prompt: prompt,
            baseURL: baseURL,
            token: token,
            endpointID: endpointID,
            model: model
        )

        return try decodePlan(from: reply)
    }

    // MARK: - Session handling

    /// Sends `prompt` on the persisted session, creating one first if there
    /// isn't one yet.
    ///
    /// The session carries conversation history server-side, so reusing a
    /// single id across launches is what gives the coach continuity between
    /// generations. It's only rebuilt when the server reports it's gone — and
    /// then the turn is retried once, so a pruned session costs a round trip
    /// rather than a failed generation.
    private static func sendReusingSession(
        prompt: String,
        baseURL: String,
        token: String,
        endpointID: String,
        model: String
    ) async throws -> String {
        let sessionID = try await currentSessionID(
            baseURL: baseURL, token: token, endpointID: endpointID, model: model
        )

        do {
            return try await OdysseusClient.chat(
                baseURL: baseURL, token: token, sessionID: sessionID, message: prompt
            )
        } catch OdysseusClient.OdysseusError.sessionNotFound {
            OdysseusConfig.clearSession()
            let fresh = try await currentSessionID(
                baseURL: baseURL, token: token, endpointID: endpointID, model: model
            )
            return try await OdysseusClient.chat(
                baseURL: baseURL, token: token, sessionID: fresh, message: prompt
            )
        }
    }

    /// The persisted session id, or a newly created one.
    static func currentSessionID(
        baseURL: String,
        token: String,
        endpointID: String,
        model: String
    ) async throws -> String {
        if let existing = OdysseusConfig.sessionID { return existing }

        let session = try await OdysseusClient.createSession(
            baseURL: baseURL,
            token: token,
            endpointID: endpointID,
            model: model,
            name: "LimitBreak"
        )
        OdysseusConfig.sessionID = session.id
        return session.id
    }

    // MARK: - Reply parsing

    /// Turns a free-text reply into a plan, or throws with a description that
    /// names the actual problem.
    ///
    /// Every balanced object in the reply is tried, not just the first: a
    /// thinking model often emits a draft or a preamble object before the real
    /// answer, and the plan is whichever candidate actually contains movements.
    static func decodePlan(from reply: String) throws -> CoachedPlan {
        let candidates: [String]
        switch JSONExtractor.scan(reply) {
        case .found(let objects):
            candidates = objects
        case .truncated:
            // Tail rather than head: the useful evidence is where it stopped.
            throw OdysseusClient.OdysseusError.replyTruncated(
                snippet: OdysseusClient.snippet(String(reply.suffix(180)))
            )
        case .none:
            throw OdysseusClient.OdysseusError.replyNotJSON(
                snippet: OdysseusClient.snippet(reply)
            )
        }

        let decoder = JSONDecoder()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let loose = try? decoder.decode(LoosePlan.self, from: data)
            else { continue }

            let plan = loose.coachedPlan
            // A plan with no movements isn't something the caller can render,
            // and the on-device tiers handle it better than an empty list.
            if !plan.exercises.isEmpty { return plan }
        }

        throw OdysseusClient.OdysseusError.planShapeUnexpected(
            snippet: OdysseusClient.snippet(candidates.last ?? reply)
        )
    }

    // MARK: - Lenient decoding

    /// The plan shape as a local model actually emits it.
    ///
    /// Everything optional here has been seen missing in practice. The
    /// non-optional fields — a movement's name, and the exercise list itself —
    /// are the ones a plan is meaningless without, so a reply lacking them is
    /// correctly a decode failure.
    private struct LoosePlan: Decodable {
        let title: String?
        let rationale: String?
        let exercises: [LooseExercise]

        private enum CodingKeys: String, CodingKey {
            case title, rationale, exercises
            // Aliases small models drift toward when naming the list, or when
            // wrapping the whole plan in one more layer.
            case movements, workout, plan, session, exerciseList = "exercise_list"
        }

        /// Keys that may hold the exercise array directly.
        private static let listKeys: [CodingKeys] = [
            .exercises, .movements, .exerciseList, .workout, .plan, .session,
        ]

        /// Keys that may hold a nested object which itself contains the plan.
        private static let wrapperKeys: [CodingKeys] = [.workout, .plan, .session]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let found = Self.listKeys.lazy
                .compactMap({ try? container.decode([LooseExercise].self, forKey: $0) })
                .first(where: { !$0.isEmpty }) {
                title = try? container.decode(String.self, forKey: .title)
                rationale = try? container.decode(String.self, forKey: .rationale)
                exercises = found
                return
            }

            // No array at this level — the model nested the plan one layer
            // deeper, e.g. {"workout": {"title": ..., "exercises": [...]}}.
            // Recurse, but keep any title and rationale from whichever level
            // actually carried them.
            for key in Self.wrapperKeys {
                guard let nested = try? container.decode(LoosePlan.self, forKey: key),
                      !nested.exercises.isEmpty
                else { continue }
                title = nested.title ?? (try? container.decode(String.self, forKey: .title))
                rationale = nested.rationale ?? (try? container.decode(String.self, forKey: .rationale))
                exercises = nested.exercises
                return
            }

            throw DecodingError.keyNotFound(
                CodingKeys.exercises,
                .init(codingPath: container.codingPath,
                      debugDescription: "No exercise list in the reply.")
            )
        }

        var coachedPlan: CoachedPlan {
            CoachedPlan(
                title: title?.trimmed.nilIfEmpty ?? "Training Session",
                rationale: rationale?.trimmed ?? "",
                exercises: exercises.map(\.coachedExercise)
            )
        }
    }

    private struct LooseExercise: Decodable {
        let name: String
        let sets: Int?
        let repRangeLow: Int?
        let repRangeHigh: Int?
        let targetLoadPounds: Double?
        let restSeconds: Int?
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case name, exercise
            case sets
            case repRangeLow, repRangeHigh
            case targetLoadPounds, restSeconds, note
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = (try? container.decode(String.self, forKey: .name))
                    ?? (try? container.decode(String.self, forKey: .exercise)) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.name,
                    .init(codingPath: container.codingPath,
                          debugDescription: "Movement has no name.")
                )
            }
            self.name = name
            sets = container.lenientInt(.sets)
            repRangeLow = container.lenientInt(.repRangeLow)
            repRangeHigh = container.lenientInt(.repRangeHigh)
            targetLoadPounds = container.lenientDouble(.targetLoadPounds)
            restSeconds = container.lenientInt(.restSeconds)
            note = try? container.decode(String.self, forKey: .note)
        }

        /// Defaults are a plain hypertrophy prescription — a reasonable session
        /// if the model omitted a field, and `WorkoutAI.matchToCatalog` clamps
        /// everything to sane bounds afterward regardless.
        var coachedExercise: CoachedExercise {
            let low = repRangeLow ?? 8
            let high = repRangeHigh ?? max(low, 12)
            return CoachedExercise(
                name: name.trimmed,
                sets: sets ?? 3,
                repRangeLow: low,
                repRangeHigh: high,
                targetLoadPounds: targetLoadPounds ?? 0,
                restSeconds: restSeconds ?? 90,
                note: note?.trimmed ?? ""
            )
        }
    }
}

// MARK: - Number coercion

private extension KeyedDecodingContainer {
    /// Accepts an integer written as a JSON number, a float, or a string —
    /// all three turn up from local models asked for `"sets": 3`.
    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value.rounded()) }
        if let text = try? decode(String.self, forKey: key) {
            let digits = text.trimmingCharacters(in: .whitespaces)
            if let value = Int(digits) { return value }
            if let value = Double(digits) { return Int(value.rounded()) }
            // "8-12" in a single field: take the first number and let the
            // caller's range clamping sort out the rest.
            if let first = digits.split(whereSeparator: { !$0.isNumber }).first {
                return Int(first)
            }
        }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let text = try? decode(String.self, forKey: key) {
            // Strip a trailing unit: "135 lbs" is common when a model is asked
            // for a weight in pounds.
            let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(cleaned)
        }
        return nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

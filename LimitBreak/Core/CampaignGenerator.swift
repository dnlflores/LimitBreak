import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Draft shape

/// A campaign exactly as a model emits it.
///
/// Kept separate from `CampaignBlueprint` on purpose: this is untrusted input.
/// Nothing decoded here reaches the store without passing through
/// `CampaignGenerator.blueprint(from:context:source:)`, which is where a
/// hallucinated movement or an unreachable target gets dropped.
struct DraftedCampaign: Decodable {
    var title: String = ""
    var premise: String = ""
    var objective: String = ""
    var weeks: Int = 0
    var milestones: [DraftedMilestone] = []

    private enum CodingKeys: String, CodingKey {
        case title, premise, objective, weeks, milestones
        // What a chattier model calls the list when it doesn't follow the contract.
        case goals, objectives
    }

    /// Hand-written rather than synthesized: a synthesized `Decodable` treats a
    /// missing key as an error even when the property has a default, and a
    /// campaign that fails to decode because the model omitted `premise` is a
    /// campaign the lifter doesn't get.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        premise = (try? container.decode(String.self, forKey: .premise)) ?? ""
        objective = (try? container.decode(String.self, forKey: .objective)) ?? ""
        weeks = (try? container.decode(Int.self, forKey: .weeks))
            ?? (try? container.decode(String.self, forKey: .weeks)).flatMap { Int($0.filter(\.isNumber)) }
            ?? 0
        for key in [CodingKeys.milestones, .goals, .objectives] {
            if let list = try? container.decode([DraftedMilestone].self, forKey: key), !list.isEmpty {
                milestones = list
                break
            }
        }
    }
}

/// One drafted milestone. Every field is optional and every number tolerates
/// arriving as a string, because a self-hosted model reliably sends at least one
/// of `"targetReps": "5"`, a missing `windowDays`, or an empty `muscleGroup`.
struct DraftedMilestone: Decodable {
    var detail: String = ""
    var kind: String = ""
    var exerciseName: String? = nil
    var muscleGroup: String? = nil
    var targetLoad: Double = 0
    var targetReps: Int = 0
    var targetCount: Int = 0
    var windowDays: Int = 0

    private enum CodingKeys: String, CodingKey {
        case detail, kind, exerciseName, muscleGroup
        case targetLoad, targetReps, targetCount, windowDays
        // Snake-case spellings small models drift toward.
        case exerciseNameSnake = "exercise_name"
        case muscleGroupSnake = "muscle_group"
        case targetLoadSnake = "target_load"
        case targetRepsSnake = "target_reps"
        case targetCountSnake = "target_count"
        case windowDaysSnake = "window_days"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detail = (try? container.decode(String.self, forKey: .detail)) ?? ""
        kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        exerciseName = Self.string(container, .exerciseName, .exerciseNameSnake)
        muscleGroup = Self.string(container, .muscleGroup, .muscleGroupSnake)
        targetLoad = Self.number(container, .targetLoad, .targetLoadSnake) ?? 0
        targetReps = Int(Self.number(container, .targetReps, .targetRepsSnake) ?? 0)
        targetCount = Int(Self.number(container, .targetCount, .targetCountSnake) ?? 0)
        windowDays = Int(Self.number(container, .windowDays, .windowDaysSnake) ?? 0)
    }

    /// First non-empty string across the accepted spellings.
    private static func string(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// A number across the accepted spellings, whether it arrived as a JSON
    /// number or quoted as a string.
    private static func number(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) -> Double? {
        for key in keys {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" }) {
                return value
            }
        }
        return nil
    }
}

// MARK: - Generator

/// Proposes a campaign, routing through whichever intelligence tier the lifter
/// has chosen.
///
/// The tiering mirrors `NarrativeEngine.generatePatchNotes` exactly — cloud if
/// they opted in and configured it, then Apple's on-device model, then the
/// deterministic template — and for the same reason: an arc the lifter can't
/// start because they're on a plane is worse than a plainer arc they can. Every
/// path here ends in a real campaign; none of them can return nothing.
enum CampaignGenerator {

    /// Proposes an arc for `context`.
    ///
    /// `provider` is non-nil only when cloud AI is enabled; it names the backend
    /// to route through. Any failure falls through to the next tier, so this is
    /// non-throwing by construction.
    static func propose(
        context: TrainingContext,
        provider: AIProvider? = nil,
        now: Date = Date()
    ) async -> CampaignBlueprint {
        if let provider {
            do {
                switch provider {
                case .claude:
                    if CloudWorkoutAI.isConfigured {
                        return try await proposeWithClaude(context: context, now: now)
                    }
                case .odysseus:
                    if OdysseusWorkoutAI.isConfigured {
                        return try await proposeWithOdysseus(context: context, now: now)
                    }
                }
            } catch {
                // A network blip, a declined request, or an unusable draft must
                // never leave the lifter without an arc — fall through.
            }
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            if let blueprint = try? await proposeWithFoundationModel(context: context, now: now) {
                return blueprint
            }
        }
        #endif

        return CampaignEngine.template(context: context, now: now)
    }

    // MARK: - Validation

    /// Turns an untrusted draft into a blueprint, or nil when nothing usable
    /// survives.
    ///
    /// This is the whole safety layer, and it is deliberately pure so it can be
    /// tested without a model. Three things get enforced that a schema can't:
    /// load targets may only name a movement the lifter actually has a ceiling
    /// on (no coaching someone toward a lift they've never done), counts and
    /// windows are clamped to sane ranges, and the arc length is forced into
    /// `CampaignEngine.weekRange`. Side quests are appended here rather than
    /// asked for, since neglect is something the app measures, not something a
    /// model should guess at.
    static func blueprint(
        from draft: DraftedCampaign,
        context: TrainingContext,
        source: CampaignSource,
        now: Date = Date()
    ) -> CampaignBlueprint? {
        let fallback = CampaignEngine.template(context: context, now: now)
        let ceilings = Dictionary(
            context.ceilings.map { ($0.key.lowercased(), $0.key) },
            uniquingKeysWith: { first, _ in first }
        )

        var specs: [MilestoneSpec] = []
        for drafted in draft.milestones {
            guard specs.count < maximumRequiredMilestones,
                  let spec = milestone(from: drafted, ceilings: ceilings)
            else { continue }
            specs.append(spec)
        }
        guard !specs.isEmpty else { return nil }

        specs.append(contentsOf: CampaignEngine.sideQuests(from: context.muscleStatuses, now: now))

        let weeks = min(
            max(draft.weeks, CampaignEngine.weekRange.lowerBound),
            CampaignEngine.weekRange.upperBound
        )

        return CampaignBlueprint(
            title: text(draft.title, fallback: fallback.title),
            premise: text(draft.premise, fallback: fallback.premise),
            objective: text(draft.objective, fallback: fallback.objective),
            weeks: weeks,
            milestones: specs,
            source: source
        )
    }

    /// How many required milestones an arc may carry. Past a handful the
    /// objective stops being one thing.
    static let maximumRequiredMilestones = 5

    /// Validates one drafted milestone against its kind's requirements.
    private static func milestone(
        from drafted: DraftedMilestone,
        ceilings: [String: String]
    ) -> MilestoneSpec? {
        guard let kind = MilestoneKind(rawValue: drafted.kind) else { return nil }
        let detail = drafted.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }

        switch kind {
        case .liftTarget:
            // Only movements the lifter already has a ceiling on. A model that
            // invents a lift produces a milestone that can never complete, since
            // evaluation matches on the stored exercise name — so it's dropped
            // rather than shown as an objective that quietly never closes.
            guard let named = drafted.exerciseName?.lowercased(),
                  let name = ceilings[named],
                  drafted.targetLoad > 0
            else { return nil }
            return MilestoneSpec(
                detail: detail,
                kind: .liftTarget,
                exerciseName: name,
                targetLoad: drafted.targetLoad,
                targetReps: clamp(drafted.targetReps, 1, 50)
            )

        case .muscleFrequency:
            guard let raw = drafted.muscleGroup, let group = muscleGroup(named: raw) else { return nil }
            return MilestoneSpec(
                detail: detail,
                kind: .muscleFrequency,
                muscleGroup: group,
                targetCount: clamp(drafted.targetCount, 1, 7),
                // A frequency milestone with no window is meaningless — "train
                // hamstrings 3 times, ever" is not a plan — so an omitted window
                // becomes the week the phrasing implies.
                windowDays: drafted.windowDays > 0 ? clamp(drafted.windowDays, 2, 30) : 7
            )

        case .sessionCount:
            guard drafted.targetCount > 0 else { return nil }
            return MilestoneSpec(
                detail: detail,
                kind: .sessionCount,
                targetCount: clamp(drafted.targetCount, 1, 100),
                windowDays: max(0, min(drafted.windowDays, 90))
            )

        case .volumeTotal:
            guard drafted.targetLoad > 0 else { return nil }
            return MilestoneSpec(
                detail: detail,
                kind: .volumeTotal,
                targetLoad: drafted.targetLoad
            )

        case .recordCount:
            guard drafted.targetCount > 0 else { return nil }
            return MilestoneSpec(
                detail: detail,
                kind: .recordCount,
                targetCount: clamp(drafted.targetCount, 1, 20),
                windowDays: max(0, min(drafted.windowDays, 90))
            )
        }
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    /// Resolves a muscle name from either spelling the app uses: the stored raw
    /// value ("Lats", "Deltoids") or the gym name the lifter — and therefore the
    /// prompt — sees ("Back", "Shoulders").
    private static func muscleGroup(named raw: String) -> MuscleGroup? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return MuscleGroup.allCases.first {
            $0.rawValue.lowercased() == key || $0.displayName.lowercased() == key
        }
    }

    // MARK: - Cloud tiers

    /// Claude drafts the arc against a JSON schema, reusing the same hardened
    /// request path as workout coaching.
    private static func proposeWithClaude(
        context: TrainingContext,
        now: Date
    ) async throws -> CampaignBlueprint {
        let draft: DraftedCampaign = try await ClaudeClient.structuredRequest(
            system: [ClaudeClient.SystemBlock(text: PromptBuilder.campaignInstructions)],
            userMessage: PromptBuilder.campaignRequestBlock(
                context: context,
                weekRange: CampaignEngine.weekRange,
                now: now
            ),
            schema: campaignSchema,
            as: DraftedCampaign.self,
            maxTokens: 4_000
        )
        guard let blueprint = blueprint(from: draft, context: context, source: .claude, now: now) else {
            throw ClaudeClient.ClientError.malformedResponse
        }
        return blueprint
    }

    /// A self-hosted model returns free text, so the object is dug out of
    /// whatever prose or tool-call envelope wraps it — the same treatment the
    /// coached plan gets.
    private static func proposeWithOdysseus(
        context: TrainingContext,
        now: Date
    ) async throws -> CampaignBlueprint {
        guard let token = KeychainStore.odysseusToken,
              let endpointID = OdysseusConfig.endpointID,
              let model = OdysseusConfig.model
        else { throw OdysseusClient.OdysseusError.notConfigured }

        let baseURL = OdysseusConfig.baseURL
        guard !baseURL.isEmpty else { throw OdysseusClient.OdysseusError.notConfigured }

        let session = try await OdysseusClient.createSession(
            baseURL: baseURL, token: token, endpointID: endpointID, model: model,
            name: "LimitBreak Campaign"
        )
        let reply = try await OdysseusClient.chat(
            baseURL: baseURL,
            token: token,
            sessionID: session.id,
            message: PromptBuilder.selfHostedCampaignPrompt(
                context: context,
                weekRange: CampaignEngine.weekRange,
                now: now
            )
        )

        guard let draft = decodeDraft(from: reply),
              let blueprint = blueprint(from: draft, context: context, source: .selfHosted, now: now)
        else { throw OdysseusClient.OdysseusError.emptyReply }
        return blueprint
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func proposeWithFoundationModel(
        context: TrainingContext,
        now: Date
    ) async throws -> CampaignBlueprint {
        let session = LanguageModelSession(
            instructions: PromptBuilder.campaignInstructions + "\n\n" + PromptBuilder.campaignOutputContract
        )
        let response = try await session.respond(
            to: PromptBuilder.campaignRequestBlock(
                context: context,
                weekRange: CampaignEngine.weekRange,
                budget: .compact,
                now: now
            )
        )
        guard let draft = decodeDraft(from: response.content),
              let blueprint = blueprint(from: draft, context: context, source: .onDevice, now: now)
        else { throw ClaudeClient.ClientError.malformedResponse }
        return blueprint
    }
    #endif

    /// Pulls a campaign draft out of a free-text reply. Every balanced object is
    /// tried, not just the first: a thinking model often emits a scratch object
    /// before the answer, and the draft is whichever candidate has milestones.
    ///
    /// Internal so the leniency can be tested against the replies local models
    /// actually produce.
    static func decodeDraft(from reply: String) -> DraftedCampaign? {
        guard case .found(let objects) = JSONExtractor.scan(reply) else { return nil }
        let decoder = JSONDecoder()
        for candidate in objects {
            guard let data = candidate.data(using: .utf8),
                  let draft = try? decoder.decode(DraftedCampaign.self, from: data),
                  !draft.milestones.isEmpty
            else { continue }
            return draft
        }
        return nil
    }

    // MARK: - Helpers

    private static func text(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Response schema

    /// As with the plan schema, JSON Schema numeric bounds aren't supported by
    /// structured outputs — ranges are stated in the descriptions and clamped
    /// after decoding.
    private static let campaignSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "Short game-chapter-style name for the arc, 2 to 4 words.",
            ],
            "premise": [
                "type": "string",
                "description": "At most two sentences of framing for the arc, in the app's voice.",
            ],
            "objective": [
                "type": "string",
                "description": "One plain sentence to the lifter on what this arc is for.",
            ],
            "weeks": [
                "type": "integer",
                "description": "Length of the arc in weeks, between 4 and 8.",
            ],
            "milestones": [
                "type": "array",
                "description": "3 to 5 milestones that together form one coherent objective.",
                "items": [
                    "type": "object",
                    "properties": [
                        "detail": [
                            "type": "string",
                            "description": "The short line the lifter reads, e.g. 'Squat 225 for 5'.",
                        ],
                        "kind": [
                            "type": "string",
                            "enum": MilestoneKind.allCases.map(\.rawValue),
                            "description": "How this milestone is measured against the training log.",
                        ],
                        "exerciseName": [
                            "type": "string",
                            "description": "For liftTarget only: the movement, copied verbatim from the recorded ceilings. Empty string otherwise.",
                        ],
                        "muscleGroup": [
                            "type": "string",
                            "description": "For muscleFrequency only: one of Chest, Lats, Traps, Quads, Hamstrings, Deltoids, Triceps, Biceps, Core, Calves, Glutes, Forearms. Empty string otherwise.",
                        ],
                        "targetLoad": [
                            "type": "number",
                            "description": "Pounds: the bar weight for liftTarget, the total for volumeTotal, 0 otherwise.",
                        ],
                        "targetReps": [
                            "type": "integer",
                            "description": "Reps the load must be moved for on a liftTarget, 0 otherwise.",
                        ],
                        "targetCount": [
                            "type": "integer",
                            "description": "How many sessions, records, or muscle-group hits are needed. 0 for liftTarget and volumeTotal.",
                        ],
                        "windowDays": [
                            "type": "integer",
                            "description": "The rolling window the count must land inside, in days. Use 0 to mean across the whole arc.",
                        ],
                    ],
                    "required": [
                        "detail", "kind", "exerciseName", "muscleGroup",
                        "targetLoad", "targetReps", "targetCount", "windowDays",
                    ],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["title", "premise", "objective", "weeks", "milestones"],
        "additionalProperties": false,
    ]
}

import Foundation

// MARK: - The log a milestone is judged against

/// A value-type snapshot of the training log, flattened to exactly what a
/// milestone can be judged on.
///
/// Milestones close themselves from real data, so the evaluation has to be
/// trustworthy — which means it has to be testable without a store, a clock, or
/// a network. Everything here is a plain value built once from SwiftData, and
/// every rule below reads only from this.
struct CampaignLog {

    /// One working set. Warmups never make it in: nobody earns a milestone on a
    /// warmup, and letting them count would make "squat 225×5" collectable by
    /// accident.
    struct LoggedSet: Equatable {
        var date: Date
        var exerciseName: String
        /// Primary plus secondary groups, as the muscle report counts them.
        var muscleGroups: [MuscleGroup]
        /// The real load moved, body weight included (`ExerciseSet.effectiveLoad`).
        var load: Double
        var reps: Int

        var volume: Double { max(0, load) * Double(reps) }
    }

    struct LoggedSession: Equatable {
        var date: Date
        var sets: [LoggedSet]

        func trains(_ group: MuscleGroup) -> Bool {
            sets.contains { $0.muscleGroups.contains(group) }
        }
    }

    /// A broken ceiling. Only the date matters for milestones, but the movement
    /// is carried so future kinds can key off it without a second snapshot.
    struct LoggedRecord: Equatable {
        var date: Date
        var exerciseName: String
    }

    var sessions: [LoggedSession] = []
    var records: [LoggedRecord] = []

    /// Every working set across every session, oldest first.
    var allSets: [LoggedSet] {
        sessions.flatMap(\.sets).sorted { $0.date < $1.date }
    }

    /// Flattens the store into the snapshot. The only place this file touches
    /// SwiftData types, and it reads them — nothing here mutates.
    static func build(sessions: [WorkoutSession], records: [PRRecord] = []) -> CampaignLog {
        let logged = sessions.map { session in
            LoggedSession(
                date: session.startDate,
                sets: session.sets
                    .filter { !$0.isWarmup }
                    .compactMap { set in
                        guard let exercise = set.exercise else { return nil }
                        return LoggedSet(
                            date: set.timestamp,
                            exerciseName: exercise.name,
                            muscleGroups: exercise.allMuscleGroups,
                            load: set.effectiveLoad,
                            reps: set.reps
                        )
                    }
                    .sorted { $0.date < $1.date }
            )
        }
        .sorted { $0.date < $1.date }

        return CampaignLog(
            sessions: logged,
            records: records
                .map { LoggedRecord(date: $0.dateAchieved, exerciseName: $0.exercise?.name ?? "") }
                .sorted { $0.date < $1.date }
        )
    }
}

// MARK: - Pace

/// How far through the arc the lifter is, against how far through the calendar
/// they are. The only input adaptation needs.
struct CampaignPace: Equatable {
    var requiredTotal: Int
    var requiredComplete: Int
    /// 0 at the start date, 1 at the end date, and past 1 once the deadline has
    /// gone by with work outstanding.
    var elapsedFraction: Double

    /// What an evenly-paced arc would have banked by now. Fractional on purpose:
    /// "0.4 milestones behind" is noise, "1.6 behind" is a real drift.
    var expectedComplete: Double { Double(requiredTotal) * min(1, elapsedFraction) }

    var shortfall: Double { max(0, expectedComplete - Double(requiredComplete)) }

    var outstanding: Int { max(0, requiredTotal - requiredComplete) }

    static func measure(
        requiredTotal: Int,
        requiredComplete: Int,
        start: Date,
        end: Date,
        now: Date = Date()
    ) -> CampaignPace {
        let span = end.timeIntervalSince(start)
        let elapsed = span > 0 ? now.timeIntervalSince(start) / span : 1
        return CampaignPace(
            requiredTotal: requiredTotal,
            requiredComplete: requiredComplete,
            elapsedFraction: max(0, elapsed)
        )
    }
}

/// What the campaign should do about the lifter's pace.
///
/// Note what is missing: there is no `failed`. A lifter who drifts gets more
/// road or a smaller objective, in that order, and the arc stays finishable
/// either way. That's the whole design — a periodization layer that punishes a
/// bad month is a periodization layer people delete.
enum CampaignAdaptation: Equatable {
    /// Pace is fine, or close enough that nudging the plan would be noise.
    case onTrack
    /// Behind with the plan still standing: `demoting` required milestones become
    /// optional side quests. They are never deleted — progress already made
    /// stays visible, the objective just stops depending on them.
    case rescoped(demoting: Int)
    /// Out of calendar with work left: the deadline moves.
    case extended(byDays: Int)
    /// Every required milestone is banked.
    case complete
}

// MARK: - Blueprint

/// Which tier drafted an arc. Mirrors `PlanSource` so the UI can be honest about
/// where the plan came from — a deterministic template must never be presented
/// as coaching.
enum CampaignSource: Equatable {
    case claude
    case selfHosted
    case onDevice
    case template

    var label: String {
        switch self {
        case .claude:     return "Charted by Claude"
        case .selfHosted: return "Charted by your server"
        case .onDevice:   return "Charted on device"
        case .template:   return "Charted from your history"
        }
    }
}

/// A proposed campaign, before it becomes SwiftData.
struct CampaignBlueprint: Equatable {
    var title: String
    var premise: String
    var objective: String
    /// Length of the arc. Always inside `CampaignEngine.weekRange`.
    var weeks: Int
    var milestones: [MilestoneSpec]
    var source: CampaignSource = .template

    func endDate(from start: Date) -> Date {
        start.addingTimeInterval(Double(weeks) * 7 * 86_400)
    }
}

// MARK: - Engine

/// The rules of the campaign layer: what counts as done, what to do when the
/// lifter drifts, and what arc to propose when nothing smarter is available.
///
/// Everything here is a pure function over values. Persistence lives in
/// `CampaignStore`, model calls live in `CampaignGenerator`, prompt text lives
/// in `PromptBuilder` — so these rules can be reasoned about and tested on their
/// own, which for the one part of the app that tells a lifter they succeeded or
/// not is the bar worth clearing.
enum CampaignEngine {

    /// A campaign is a block of real training, not a to-do list — short enough
    /// to stay urgent, long enough for a lift to actually move.
    static let weekRange = 4...8

    // MARK: - Milestone evaluation

    /// When the log first satisfied `spec`, or nil if it hasn't yet.
    ///
    /// Returns the date of the *set that did it* rather than "now", so a
    /// milestone earned on Tuesday and noticed on Friday is dated Tuesday. This
    /// is the single source of truth for milestone completion — the UI has no
    /// check-off, and nothing else may set `isComplete`.
    static func completionDate(
        for spec: MilestoneSpec,
        log: CampaignLog,
        since start: Date,
        now: Date = Date()
    ) -> Date? {
        switch spec.kind {
        case .liftTarget:
            return firstQualifyingLift(spec, log: log, since: start, now: now)

        case .muscleFrequency:
            guard let group = spec.muscleGroup else { return nil }
            let dates = log.sessions.filter { $0.trains(group) }.map(\.date)
            return firstDate(reaching: spec.targetCount, within: spec.windowDays, in: dates, since: start, now: now)

        case .sessionCount:
            // A session with no working sets logged is a start button, not a
            // workout, and shouldn't advance an objective.
            let dates = log.sessions.filter { !$0.sets.isEmpty }.map(\.date)
            return firstDate(reaching: spec.targetCount, within: spec.windowDays, in: dates, since: start, now: now)

        case .recordCount:
            return firstDate(reaching: spec.targetCount, within: spec.windowDays, in: log.records.map(\.date), since: start, now: now)

        case .volumeTotal:
            guard spec.targetLoad > 0 else { return nil }
            var running: Double = 0
            for set in log.allSets where set.date >= start && set.date <= now {
                running += set.volume
                if running >= spec.targetLoad { return set.date }
            }
            return nil
        }
    }

    /// The first working set inside the arc that hit the bar and the reps.
    ///
    /// `targetReps` of 0 means "any reps", and a `targetLoad` of 0 means "any
    /// load" — so a bodyweight milestone ("30 push-ups") and a barbell one
    /// ("225 × 5") both fall out of the same comparison.
    private static func firstQualifyingLift(
        _ spec: MilestoneSpec,
        log: CampaignLog,
        since start: Date,
        now: Date
    ) -> Date? {
        guard let name = spec.exerciseName?.lowercased(), !name.isEmpty else { return nil }
        return log.allSets.first { set in
            set.date >= start && set.date <= now
                && set.exerciseName.lowercased() == name
                && set.load >= spec.targetLoad - 0.001
                && set.reps >= spec.targetReps
        }?.date
    }

    /// The date `count` events first landed inside one rolling `windowDays`
    /// window — the mechanic behind "train hamstrings 3× in a week".
    ///
    /// A window of 0 means the whole arc, which is the same sweep with no lower
    /// bound. Internal rather than private so the window arithmetic can be
    /// tested directly; it is fiddly and quietly load-bearing.
    static func firstDate(
        reaching count: Int,
        within windowDays: Int,
        in dates: [Date],
        since start: Date,
        now: Date = Date()
    ) -> Date? {
        guard count > 0 else { return nil }
        let candidates = dates.filter { $0 >= start && $0 <= now }.sorted()
        guard candidates.count >= count else { return nil }

        for (index, date) in candidates.enumerated() where index + 1 >= count {
            let earliest = windowDays > 0
                ? date.addingTimeInterval(-Double(windowDays) * 86_400)
                : Date.distantPast
            let inWindow = candidates[...index].filter { $0 >= earliest }.count
            if inWindow >= count { return date }
        }
        return nil
    }

    // MARK: - Adaptation

    /// Days added each time a campaign runs out of road.
    static let extensionDays = 7
    /// How many times the deadline may move before the arc is rescoped instead.
    /// Without a cap an untrained campaign would slide forever and mean nothing;
    /// with it, the arc shrinks to something the lifter's real cadence can close.
    static let maximumExtensions = 3
    /// How far behind an even pace counts as drift rather than noise, in
    /// milestones. Set above 1 so a single slow week never rewrites the plan.
    static let rescopeShortfall = 1.5

    /// What to do about the lifter's pace right now.
    ///
    /// Read the order: finished first, then out-of-time (extend), then drifting
    /// (rescope), then leave it alone. Every branch leaves the campaign
    /// completable — the function has no way to express failure, which is the
    /// point.
    static func adaptation(pace: CampaignPace, extensionsUsed: Int) -> CampaignAdaptation {
        guard pace.requiredTotal > 0 else { return .complete }
        if pace.requiredComplete >= pace.requiredTotal { return .complete }

        if pace.elapsedFraction >= 1 {
            // The deadline passed with work outstanding. Give more road; once
            // that's exhausted, shrink the objective to the single milestone
            // closest to hand rather than declaring the arc lost.
            if extensionsUsed < maximumExtensions {
                return .extended(byDays: extensionDays)
            }
            return .rescoped(demoting: max(1, pace.outstanding - 1))
        }

        // Mid-flight drift. Only acted on past the halfway mark — early in an
        // arc there is nothing to conclude from a quiet week — and only when
        // there's something left to shed.
        if pace.elapsedFraction >= 0.5, pace.shortfall >= rescopeShortfall, pace.outstanding > 1 {
            return .rescoped(demoting: 1)
        }

        return .onTrack
    }

    // MARK: - Side quests

    /// Optional objectives drawn from the muscles the lifter has stopped
    /// training. Dormant means untouched for a week (`FreshnessState.dormant`),
    /// which is exactly the signal worth surfacing: not a failure, just a gap
    /// nobody noticed.
    ///
    /// Capped, and ordered by how long each has been ignored, so the lifter gets
    /// the two or three that matter rather than a wall of every muscle they
    /// skipped.
    static func sideQuests(
        from statuses: [MuscleGroup: MuscleStatus],
        now: Date = Date(),
        limit: Int = 3
    ) -> [MilestoneSpec] {
        statuses.values
            .filter { $0.state(now: now) == .dormant }
            .sorted { left, right in
                // Never-trained (nil) sorts first; otherwise oldest first.
                switch (left.lastTrained, right.lastTrained) {
                case (nil, nil):               return left.group.rawValue < right.group.rawValue
                case (nil, _):                 return true
                case (_, nil):                 return false
                case let (l?, r?):             return l < r
                }
            }
            .prefix(limit)
            .map { status in
                MilestoneSpec(
                    detail: "Wake up \(status.group.displayName) — train it twice in a week",
                    kind: .muscleFrequency,
                    muscleGroup: status.group,
                    targetCount: 2,
                    windowDays: 7,
                    isSideQuest: true
                )
            }
    }

    // MARK: - Deterministic proposal

    /// The offline arc: a real campaign built from the lifter's own numbers with
    /// no model involved.
    ///
    /// This is the floor, not a placeholder — every AI tier falls through to it,
    /// so it has to produce something a lifter would actually chase. It reads
    /// the same `TrainingContext` the coach does: their strongest lift becomes
    /// the number to beat, their neglected muscle becomes the frequency target,
    /// and their stated cadence sets how many sessions the arc asks for.
    static func template(context: TrainingContext, now: Date = Date()) -> CampaignBlueprint {
        let weeks = templateWeeks(for: context)
        let flavor = templateFlavor(for: context.goal)

        var specs: [MilestoneSpec] = []

        // 1. Show up. Three quarters of their stated cadence, so the arc asks
        //    for consistency without assuming a perfect month.
        let sessionTarget = max(4, Int((Double(context.daysPerWeek * weeks) * 0.75).rounded()))
        specs.append(MilestoneSpec(
            detail: "Log \(sessionTarget) sessions before the arc closes",
            kind: .sessionCount,
            targetCount: sessionTarget
        ))

        // 2. Move a real number. Their strongest recorded lift, pushed by the
        //    margin their goal justifies, at their goal's heavy rep target.
        if let anchor = context.ceilings.max(by: { $0.value < $1.value }), anchor.value > 0 {
            let reps = max(1, context.goal.repRange.low)
            let target = (anchor.value * templateLiftGain(for: context.goal) / 5).rounded() * 5
            specs.append(MilestoneSpec(
                detail: "\(anchor.key): \(target.cleanWeight) for \(reps)",
                kind: .liftTarget,
                exerciseName: anchor.key,
                targetLoad: target,
                targetReps: reps
            ))
        }

        // 3. Close the biggest gap. The least-trained muscle, twice a week —
        //    frequency, not volume, because that's what fixes neglect.
        if let neglected = neglectedGroup(in: context, now: now) {
            specs.append(MilestoneSpec(
                detail: "Train \(neglected.displayName) twice a week",
                kind: .muscleFrequency,
                muscleGroup: neglected,
                targetCount: 2,
                windowDays: 7
            ))
        }

        // 4. Break something. Two ceilings over a month-plus is ambitious but
        //    reachable at any level, and it's the milestone the app is named for.
        specs.append(MilestoneSpec(
            detail: "Trigger 2 LimitBreaks",
            kind: .recordCount,
            targetCount: 2
        ))

        specs.append(contentsOf: sideQuests(from: context.muscleStatuses, now: now))

        return CampaignBlueprint(
            title: flavor.title,
            premise: flavor.premise,
            objective: flavor.objective,
            weeks: weeks,
            milestones: specs,
            source: .template
        )
    }

    /// Arc length. Strength work needs the longest runway — loads move in
    /// pounds per month, not per week — and beginners need the shortest, because
    /// eight weeks is a long time to wait for a first win.
    private static func templateWeeks(for context: TrainingContext) -> Int {
        let weeks: Int
        switch (context.experience, context.goal) {
        case (.beginner, _):        weeks = 4
        case (_, .getStronger):     weeks = 8
        case (.advanced, _):        weeks = 8
        default:                    weeks = 6
        }
        return min(max(weeks, weekRange.lowerBound), weekRange.upperBound)
    }

    /// How much the anchor lift should climb over the arc. Conservative on
    /// purpose: a milestone the lifter can't hit is worse than one they clear
    /// early, because only one of those gets them back in the gym.
    private static func templateLiftGain(for goal: TrainingGoal) -> Double {
        switch goal {
        case .getStronger:  return 1.05
        case .buildMuscle:  return 1.04
        default:            return 1.03
        }
    }

    /// The muscle most worth chasing: fewest sets this week, dormant first.
    private static func neglectedGroup(in context: TrainingContext, now: Date) -> MuscleGroup? {
        context.muscleStatuses.values
            .min { left, right in
                let leftDormant = left.state(now: now) == .dormant
                let rightDormant = right.state(now: now) == .dormant
                if leftDormant != rightDormant { return leftDormant }
                if left.weeklySets != right.weeklySets { return left.weeklySets < right.weeklySets }
                return left.group.rawValue < right.group.rawValue
            }?
            .group
    }

    /// Offline flavour text per goal. Deterministic and hand-written — the same
    /// role `NarrativeEngine.templatePatchNotes` plays for the weekly notes.
    private static func templateFlavor(
        for goal: TrainingGoal
    ) -> (title: String, premise: String, objective: String) {
        switch goal {
        case .getStronger:
            return (
                "The Iron Ascent",
                "The bar has been sitting at the same weight long enough to feel permanent. It isn't — it's just unchallenged.",
                "Add real weight to your strongest lift and hold your training cadence while you do it."
            )
        case .buildMuscle:
            return (
                "Mass Effect",
                "Tissue is built by repetition under load, week after week, long past the point it stops feeling novel.",
                "Accumulate hard sets across the whole body and push your anchor lift up as you go."
            )
        case .loseFat:
            return (
                "The Long Burn",
                "Every session is a withdrawal against a debt that only compounds when you skip.",
                "Keep the work density high and the sessions frequent for the length of the arc."
            )
        case .getToned:
            return (
                "Balanced Blade",
                "A body that only trains what it likes is a body with holes in it.",
                "Cover every muscle group on a rotation and keep showing up."
            )
        case .endurance:
            return (
                "Endless March",
                "Capacity is the slowest stat to move and the last one to leave you.",
                "Build sustained work capacity with high-rep volume and unbroken frequency."
            )
        }
    }
}

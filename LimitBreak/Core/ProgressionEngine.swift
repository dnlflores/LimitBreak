import Foundation

/// Progressive overload, made deterministic.
///
/// The coach (and the fallback tiers) already saw the lifter's history as a
/// summary. What was missing was the concrete last-session → next-session math
/// for a single lift: "you did 3×8 at 135 last time, so aim for 3×9 at 135
/// today." This engine derives exactly that, using two evidence-based ideas:
///
/// - **Double progression** — hold the weight and add reps until every working
///   set caps the rep range, then "cash in" the reps for a heavier load and
///   reset to the bottom of the range. Reps first, weight second.
/// - **Daily undulating periodization (DUP)** — a lift alternates between a
///   *heavy* track (lower reps, more load) and a *volume* track (higher reps,
///   moderate load) from session to session, and each track progresses on its
///   own. This is why "some sessions go for max weight and some for max reps":
///   they're two tracks of the same lift, not indecision.
///
/// Everything here is a pure function of an exercise's logged sets and the
/// lifter's goal — no persistence, no new stored fields — so it stays testable
/// and can't drift out of sync with history.
enum TrainingEmphasis: String, Codable {
    /// Lower reps, heavier load — the strength/top-end track.
    case heavy
    /// Higher reps, moderate load — the hypertrophy/work-capacity track.
    case volume

    var label: String {
        switch self {
        case .heavy:  return "Heavy"
        case .volume: return "Volume"
        }
    }

    /// A one-liner describing the track, for cards and prompts.
    var descriptor: String {
        switch self {
        case .heavy:  return "lower reps, heavier load"
        case .volume: return "higher reps, moderate load"
        }
    }

    /// The other track — used to undulate from one session to the next.
    var flipped: TrainingEmphasis { self == .heavy ? .volume : .heavy }
}

// MARK: - Goal → rep ranges

extension TrainingGoal {
    /// The full working rep range this goal centers on, matching the numbers in
    /// `coachingBrief` so the deterministic engine and the AI coach agree.
    var repRange: (low: Int, high: Int) {
        switch self {
        case .loseFat:     return (12, 20)
        case .buildMuscle: return (6, 12)
        case .getToned:    return (10, 15)
        case .getStronger: return (3, 6)
        case .endurance:   return (15, 25)
        }
    }

    /// Which track a lift opens on when it has no history — strength work starts
    /// heavy, everything else starts on the volume track.
    var defaultEmphasis: TrainingEmphasis {
        self == .getStronger ? .heavy : .volume
    }

    /// The rep band for one DUP track: the lower half of the goal's range for the
    /// heavy track, the upper half for volume. Isolation movements get a slightly
    /// wider volume band, since their load climbs too slowly to progress on weight
    /// alone.
    func repBand(for emphasis: TrainingEmphasis, isolation: Bool) -> (low: Int, high: Int) {
        let (low, high) = repRange
        let mid = (low + high) / 2
        switch emphasis {
        case .heavy:
            return (low, max(low, mid))
        case .volume:
            let top = isolation ? high + 2 : high
            return (min(mid + 1, top), top)
        }
    }
}

// MARK: - Target

/// The concrete prescription for one lift this session, derived from its own
/// history. `targetReps` is the single number to chase; `repRangeLow/High` frame
/// it so the UI can still let the lifter slide within the band.
struct ProgressionTarget {
    let emphasis: TrainingEmphasis
    let sets: Int
    let repRangeLow: Int
    let repRangeHigh: Int
    /// The rep count to aim for this session — the top of what you should hit.
    let targetReps: Int
    /// Working weight in canonical pounds. Nil for unloaded bodyweight movements,
    /// where reps are the only lever.
    let targetWeightPounds: Double?
    /// One line to the lifter explaining the jump from last time.
    let rationale: String
    /// What was actually done last time on this track — powers "beat last 3×8"
    /// copy. Nil when the lift has no history yet.
    let previous: PriorPerformance?

    /// A lift's last recorded working effort on one DUP track.
    struct PriorPerformance {
        let weightPounds: Double
        let topReps: Int
        let sets: Int
    }

    /// A compact line for the AI prompt, e.g.
    /// "Bench Press: aim 3×5 @ 140 lb (last 3×8 @ 135 — capped the range)".
    func promptLine(exerciseName: String) -> String {
        var head = "\(exerciseName): aim \(sets)×\(targetReps)"
        if let weight = targetWeightPounds, weight > 0 {
            head += " @ \(Int(weight.rounded())) lb"
        }
        if let previous {
            var tail = "last \(previous.sets)×\(previous.topReps)"
            if previous.weightPounds > 0 { tail += " @ \(Int(previous.weightPounds.rounded())) lb" }
            head += " (\(tail))"
        }
        return head
    }
}

// MARK: - Engine

enum ProgressionEngine {
    /// Sets to prescribe when history doesn't dictate a count.
    static let defaultSets = 3

    /// The next-session target for a lift, or nil for movements progression
    /// doesn't model (duration/distance/custom metrics keep their own behavior).
    ///
    /// - Parameters:
    ///   - emphasis: force a track (used by the AI path, where the whole session
    ///     undulates together). When nil, the track is inferred per lift by
    ///     flipping whatever the last session used.
    ///   - experience: the lifter's self-rated experience, used only to scale a
    ///     first-time bodyweight-based load estimate (see `startingTarget`).
    ///   - bodyWeightLbs: the lifter's bodyweight, when known. Lets a movement
    ///     with no history and no recorded ceiling still get a conservative
    ///     starting load instead of a blank — otherwise weight stays nil.
    static func nextTarget(
        for exercise: Exercise,
        goal: TrainingGoal,
        withPartner: Bool = false,
        emphasis explicitEmphasis: TrainingEmphasis? = nil,
        experience: ExperienceLevel = .intermediate,
        bodyWeightLbs: Double? = nil,
        now: Date = Date()
    ) -> ProgressionTarget? {
        switch exercise.trackingType {
        case .weightAndReps, .bodyweightAndReps:
            break
        default:
            return nil
        }

        // A spot only changes the math on free-weight presses/squats; elsewhere
        // it's a fair proxy for "not a compound", so the band widens for those.
        let isolation = !exercise.benefitsFromSpotter
        let increment = exercise.defaultIncrement > 0 ? exercise.defaultIncrement : 5

        // Every working set for this lift, grouped by the session it belongs to.
        var groups: [UUID: (session: WorkoutSession, sets: [ExerciseSet])] = [:]
        for set in exercise.sets where !set.isWarmup {
            guard let session = set.session else { continue }
            groups[session.id, default: (session, [])].sets.append(set)
        }
        let sessionsNewestFirst = groups.values.sorted { $0.session.startDate > $1.session.startDate }

        // Track: honor an explicit one, else flip whatever the last session ran.
        let emphasis: TrainingEmphasis
        if let explicitEmphasis {
            emphasis = explicitEmphasis
        } else if let last = sessionsNewestFirst.first {
            let heavyHigh = goal.repBand(for: .heavy, isolation: isolation).high
            let lastTopReps = last.sets.map(\.reps).max() ?? 0
            emphasis = (lastTopReps <= heavyHigh ? TrainingEmphasis.heavy : .volume).flipped
        } else {
            emphasis = goal.defaultEmphasis
        }

        let band = goal.repBand(for: emphasis, isolation: isolation)

        // No history: seed from the recorded ceiling, or fall back to reps only.
        guard !sessionsNewestFirst.isEmpty else {
            return startingTarget(
                exercise: exercise, emphasis: emphasis, band: band,
                increment: increment, withPartner: withPartner,
                experience: experience, bodyWeightLbs: bodyWeightLbs
            )
        }

        // The last time this lift was run on *this* track (top reps inside the
        // band), so heavy and volume progress independently. Falls back to the
        // most recent session when the track has never been run.
        let prior = sessionsNewestFirst.first { grp in
            let top = grp.sets.map(\.reps).max() ?? 0
            return top >= band.low && top <= band.high
        } ?? sessionsNewestFirst[0]

        let priorSets = prior.sets
        let priorSetCount = priorSets.count
        let topReps = priorSets.map(\.reps).max() ?? 0
        let priorWeight = priorSets.map(\.weight).max() ?? 0
        // Min reps among the sets at the heaviest load tells us whether *every*
        // working set capped the range (the trigger to add weight).
        let minRepsAtTopWeight = priorSets
            .filter { $0.weight >= priorWeight - 0.01 }
            .map(\.reps).min() ?? topReps
        // The lifter's own reps-in-reserve read for this lift last time it ran on
        // this track (1–5, lower = closer to failure). Every working set carries
        // the same stamp, so any non-nil one speaks for the movement.
        let priorRIR = priorSets.compactMap(\.repsInReserve).min()
        let targetSets = priorSetCount > 0 ? priorSetCount : defaultSets
        let previous = ProgressionTarget.PriorPerformance(
            weightPounds: priorWeight, topReps: topReps, sets: priorSetCount
        )

        // Stall detection: same-track sessions stuck at the *current* working
        // weight with no rep PR across the last three. Strength isn't linear —
        // an intermediate lifter shouldn't be expected to add reps every week —
        // so a genuine plateau earns a lighter week (deload) rather than another
        // demand to beat a number they've already failed to beat twice.
        let trackAtWeight = sessionsNewestFirst.filter { grp in
            let top = grp.sets.map(\.reps).max() ?? 0
            let w = grp.sets.map(\.weight).max() ?? 0
            return top >= band.low && top <= band.high && abs(w - priorWeight) < 0.01
        }
        let stalled: Bool = {
            // Never call it a stall when they're one good set from cashing in.
            guard topReps < band.high, trackAtWeight.count >= 3 else { return false }
            let reps = trackAtWeight.prefix(3).map { $0.sets.map(\.reps).max() ?? 0 }
            return reps[0] <= max(reps[1], reps[2])
        }()

        // Unloaded bodyweight: reps are the only lever, so just add one.
        if priorWeight <= 0 {
            let nextReps = max(topReps + 1, band.low)
            return ProgressionTarget(
                emphasis: emphasis, sets: targetSets,
                repRangeLow: band.low, repRangeHigh: max(band.high, nextReps),
                targetReps: nextReps, targetWeightPounds: nil,
                rationale: "Add a rep: chase \(nextReps) (you hit \(topReps) last time).",
                previous: previous
            )
        }

        // Cash in: every set capped the range → add load, reset to the bottom.
        if minRepsAtTopWeight >= band.high {
            let bumped = snap(priorWeight + increment, to: increment)
            return ProgressionTarget(
                emphasis: emphasis, sets: targetSets,
                repRangeLow: band.low, repRangeHigh: band.high,
                targetReps: band.low, targetWeightPounds: bumped,
                rationale: "You capped \(band.high) reps on every set at \(priorWeight.cleanWeight) lb — bump to \(bumped.cleanWeight) and rebuild from \(band.low).",
                previous: previous
            )
        }

        // Back off: the load was too heavy to keep reps inside the range last time
        // (you fell below the bottom), so drop it a notch rather than asking for
        // reps the weight won't allow. Progression that overshot gets walked back.
        if topReps < band.low {
            let eased = max(increment, snap(priorWeight - increment, to: increment))
            return ProgressionTarget(
                emphasis: emphasis, sets: targetSets,
                repRangeLow: band.low, repRangeHigh: band.high,
                targetReps: band.low, targetWeightPounds: eased,
                rationale: "\(priorWeight.cleanWeight) lb pushed you below \(band.low) reps — ease to \(eased.cleanWeight) and own the \(band.low)–\(band.high) range before loading again.",
                previous: previous
            )
        }

        // Stalled three sessions at this load → a lighter week to shed fatigue,
        // then rebuild. Reps sit mid-range with a couple left in reserve.
        if stalled {
            let deload = max(increment, snap(priorWeight * 0.9, to: increment))
            let mid = max(band.low, (band.low + band.high) / 2)
            return ProgressionTarget(
                emphasis: emphasis, sets: targetSets,
                repRangeLow: band.low, repRangeHigh: band.high,
                targetReps: mid, targetWeightPounds: deload,
                rationale: "Stuck at \(priorWeight.cleanWeight) lb for three sessions — take a lighter week at \(deload.cleanWeight) for \(mid) reps, leave 2–3 in reserve, then rebuild. Strength isn't linear.",
                previous: previous
            )
        }

        // Near failure but still short of the top → consolidate the same numbers.
        if let priorRIR, priorRIR <= 1, topReps < band.high {
            let holdReps = max(topReps, band.low)
            return ProgressionTarget(
                emphasis: emphasis, sets: targetSets,
                repRangeLow: band.low, repRangeHigh: band.high,
                targetReps: holdReps, targetWeightPounds: priorWeight,
                rationale: "You had little left last time — match \(priorWeight.cleanWeight) lb × \(holdReps) and own it before the load moves.",
                previous: previous
            )
        }

        // Otherwise add a rep on the same load (the rep side of double progression).
        let nextReps = min(max(topReps + 1, band.low), band.high)
        return ProgressionTarget(
            emphasis: emphasis, sets: targetSets,
            repRangeLow: band.low, repRangeHigh: band.high,
            targetReps: nextReps, targetWeightPounds: priorWeight,
            rationale: "Beat last time: \(priorWeight.cleanWeight) lb for \(nextReps) (you hit \(topReps)). Cap \(band.high) and the load climbs.",
            previous: previous
        )
    }

    // MARK: - Helpers

    /// A first-time target: a fraction of the recorded ceiling appropriate to the
    /// track, or — with no ceiling — a bodyweight-based estimate, falling back to
    /// a rep range only when even bodyweight is unknown.
    private static func startingTarget(
        exercise: Exercise,
        emphasis: TrainingEmphasis,
        band: (low: Int, high: Int),
        increment: Double,
        withPartner: Bool,
        experience: ExperienceLevel,
        bodyWeightLbs: Double?
    ) -> ProgressionTarget {
        let spotted = withPartner && exercise.benefitsFromSpotter
        let ceiling = exercise.ceiling(for: "1RM")
        guard ceiling > 0 else {
            // No recorded ceiling. Rather than leave the load blank (which reads
            // as "no weight recommended" for a brand-new lifter), estimate a
            // conservative first working weight from bodyweight when we know it.
            if let bodyWeightLbs, bodyWeightLbs > 0,
               let estimate = estimatedStartingWeight(
                   exercise: exercise, bodyWeightLbs: bodyWeightLbs, emphasis: emphasis,
                   spotted: spotted, experience: experience, increment: increment
               ) {
                return ProgressionTarget(
                    emphasis: emphasis, sets: defaultSets,
                    repRangeLow: band.low, repRangeHigh: band.high,
                    targetReps: band.low, targetWeightPounds: estimate,
                    rationale: "No history yet — starting conservatively at \(estimate.cleanWeight) lb, judged from your bodyweight. Adjust to what feels right and the numbers take over from there.",
                    previous: nil
                )
            }
            return ProgressionTarget(
                emphasis: emphasis, sets: defaultSets,
                repRangeLow: band.low, repRangeHigh: band.high,
                targetReps: band.low, targetWeightPounds: nil,
                rationale: "First time through — start light, aim for \(band.low)–\(band.high) reps, and let the numbers build.",
                previous: nil
            )
        }
        // Heavy track sits closer to the ceiling than the volume track; a spot
        // buys a little more on both.
        let fraction: Double
        switch (emphasis, spotted) {
        case (.heavy, true):   fraction = 0.82
        case (.heavy, false):  fraction = 0.78
        case (.volume, true):  fraction = 0.72
        case (.volume, false): fraction = 0.68
        }
        let weight = snap(ceiling * fraction, to: increment)
        return ProgressionTarget(
            emphasis: emphasis, sets: defaultSets,
            repRangeLow: band.low, repRangeHigh: band.high,
            targetReps: band.low, targetWeightPounds: weight,
            rationale: "No \(emphasis.label.lowercased()) history yet — starting near \(Int((fraction * 100).rounded()))% of your \(ceiling.cleanWeight) lb ceiling at \(weight.cleanWeight) lb.",
            previous: nil
        )
    }

    /// A conservative first-load estimate for a *loaded* movement the lifter has
    /// never logged and has no recorded ceiling for. Anchored to bodyweight and
    /// scaled by the muscle worked (a rough proxy for how much load the pattern
    /// carries), the equipment, experience, and track — then biased deliberately
    /// light, because starting under is the safe error: the lifter tunes up from
    /// here and the progression engine takes over next session.
    ///
    /// Returns nil where a load estimate makes no sense — unloaded bodyweight
    /// movements, assisted movements (their weight is negative assistance), and
    /// non weight-and-reps tracking — so those keep their reps-only start.
    private static func estimatedStartingWeight(
        exercise: Exercise,
        bodyWeightLbs: Double,
        emphasis: TrainingEmphasis,
        spotted: Bool,
        experience: ExperienceLevel,
        increment: Double
    ) -> Double? {
        guard exercise.trackingType == .weightAndReps, !exercise.isAssisted else { return nil }

        // Working-set load as a fraction of bodyweight for an intermediate lifter,
        // keyed by the movement's primary muscle.
        let muscleFraction: Double
        switch exercise.muscleGroup {
        case .quads, .glutes: muscleFraction = 0.75
        case .hamstrings:     muscleFraction = 0.65
        case .calves:         muscleFraction = 0.60
        case .traps:          muscleFraction = 0.50
        case .chest, .lats:   muscleFraction = 0.45
        case .deltoids:       muscleFraction = 0.28
        case .triceps:        muscleFraction = 0.24
        case .biceps:         muscleFraction = 0.22
        case .core:           muscleFraction = 0.20
        case .forearms:       muscleFraction = 0.18
        }

        // How much of that load the equipment actually carries. Dumbbells and
        // kettlebells are loaded per hand, so they sit well under the barbell
        // baseline; cables and bands lighter still.
        let equipmentFactor: Double
        switch EquipmentType(rawValue: exercise.equipmentType) {
        case .barbell, .specialtyBar: equipmentFactor = 1.0
        case .machine:                equipmentFactor = 1.05
        case .cable:                  equipmentFactor = 0.55
        case .dumbbell:               equipmentFactor = 0.50
        case .kettlebell:             equipmentFactor = 0.45
        case .resistanceBand:         equipmentFactor = 0.35
        case .bodyweight, .none:      return nil
        }

        let experienceFactor: Double
        switch experience {
        case .beginner:     experienceFactor = 0.75
        case .intermediate: experienceFactor = 1.0
        case .advanced:     experienceFactor = 1.2
        }

        let trackFactor = emphasis == .heavy ? 1.05 : 0.92
        let spotFactor = spotted ? 1.05 : 1.0
        // A deliberate haircut so the estimate lands under a true working weight.
        let safety = 0.85

        let raw = bodyWeightLbs * muscleFraction * equipmentFactor
            * experienceFactor * trackFactor * spotFactor * safety
        // Never below a single increment, so it always lands on a loadable weight.
        return max(increment, snap(raw, to: increment))
    }

    /// Rounds a load to the movement's increment so prescriptions land on plates.
    private static func snap(_ weight: Double, to increment: Double) -> Double {
        guard increment > 0 else { return weight }
        return (weight / increment).rounded() * increment
    }
}

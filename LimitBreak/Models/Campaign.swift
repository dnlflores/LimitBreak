import Foundation
import SwiftData

// MARK: - Status

/// Where a campaign sits in its own arc.
///
/// There is deliberately no `failed` case, and adding one would undo the point
/// of the feature. A campaign that runs out of road is extended or rescoped
/// (`CampaignEngine.adaptation`), never lost — the arc exists to keep someone
/// training, and telling a lifter they failed the thing that was supposed to
/// motivate them is the one outcome that reliably makes them stop.
enum CampaignStatus: String, Codable, CaseIterable, Identifiable {
    case active = "Active"
    case complete = "Complete"
    /// Retired by the lifter to chart a different arc. Kept rather than deleted
    /// so the chapters written under it survive as history.
    case retired = "Retired"

    var id: String { rawValue }
}

// MARK: - Milestone kinds

/// What a milestone measures.
///
/// Every kind is answered from data the lifter already logs. There is no manual
/// check-off anywhere in the campaign — a milestone can only be completed by
/// actually training, which is what makes the arc mean anything. Adding a kind
/// means teaching `CampaignEngine.completionDate` how to read it out of the log,
/// and nothing else.
enum MilestoneKind: String, Codable, CaseIterable, Identifiable {
    /// A number on a specific bar: "Squat 225 × 5".
    case liftTarget
    /// A muscle group hit N times inside a rolling window: "hamstrings 3× in a week".
    case muscleFrequency
    /// Sessions logged: "8 sessions this month".
    case sessionCount
    /// Pounds moved across the arc.
    case volumeTotal
    /// LimitBreaks (PRs) broken across the arc.
    case recordCount

    var id: String { rawValue }

    /// The SF Symbol the milestone row leads with.
    var icon: String {
        switch self {
        case .liftTarget:      return "scalemass.fill"
        case .muscleFrequency: return "repeat"
        case .sessionCount:    return "flag.checkered"
        case .volumeTotal:     return "chart.bar.fill"
        case .recordCount:     return "crown.fill"
        }
    }
}

// MARK: - Milestone spec (the value type everything is judged as)

/// One milestone, as a plain value.
///
/// The persisted `CampaignMilestone` is a thin SwiftData shell around this;
/// evaluation, generation and adaptation all work on the value type so none of
/// them need a `ModelContext` — which is what makes the rules testable in
/// isolation and keeps them honest.
struct MilestoneSpec: Equatable {
    /// The lifter-facing sentence, e.g. "Squat 225 for 5".
    var detail: String
    var kind: MilestoneKind
    /// Which movement, for `.liftTarget`. Matched case-insensitively.
    var exerciseName: String? = nil
    /// Which muscle, for `.muscleFrequency`.
    var muscleGroup: MuscleGroup? = nil
    /// Pounds — the bar weight for `.liftTarget`, the total for `.volumeTotal`.
    var targetLoad: Double = 0
    /// Reps that load has to be moved for. Zero means any.
    var targetReps: Int = 0
    /// How many of the counted thing are needed.
    var targetCount: Int = 0
    /// The rolling window the count has to land inside, in days. Zero means the
    /// whole campaign — "8 sessions this month" is a window of 0 on a 4-week
    /// arc, "hamstrings 3× in a week" is a window of 7.
    var windowDays: Int = 0
    /// Side quests are optional colour, not part of the objective. They come
    /// from neglected muscles (`CampaignEngine.sideQuests`) and never gate
    /// completion — and a required milestone the lifter can't reach is *demoted*
    /// to one rather than deleted.
    var isSideQuest: Bool = false
}

// MARK: - Campaign

/// A 4–8 week arc with a real objective, derived from what the lifter has
/// actually been doing.
///
/// This is the app's only forward-looking state. Everything else in LimitBreak
/// describes training that already happened; a campaign says what the next
/// month and a half is *for*, and its milestones close themselves as the log
/// fills in underneath them.
@Model
final class Campaign {
    @Attribute(.unique) var id: UUID = UUID()
    /// Short, punchy arc name — "The Century Ascent".
    var title: String = ""
    /// Two sentences of RPG framing. Flavour, not instruction.
    var premise: String = ""
    /// The one thing this arc is for, in plain language.
    var objective: String = ""
    var startDate: Date = Date()
    /// Moves when the lifter falls behind — see `extensionCount`.
    var endDate: Date = Date()
    var statusRaw: String = CampaignStatus.active.rawValue
    /// How many times the deadline has already been pushed out. Capped by
    /// `CampaignEngine.maximumExtensions`, after which the arc rescopes instead.
    var extensionCount: Int = 0
    /// How many required milestones have been demoted to side quests to keep the
    /// arc reachable. Surfaced so the UI can say the plan changed, honestly.
    var rescopeCount: Int = 0
    /// Which tier wrote this arc, so the UI never claims a template was coached.
    var sourceLabel: String = ""
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \CampaignMilestone.campaign)
    var milestones: [CampaignMilestone] = []

    /// The weekly patch notes, repointed. They used to be a read-once artifact
    /// with nowhere to live; here each week's notes are a chapter of the arc
    /// they were written during.
    @Relationship(deleteRule: .cascade, inverse: \CampaignChapter.campaign)
    var chapters: [CampaignChapter] = []

    init(
        title: String,
        premise: String,
        objective: String,
        startDate: Date = Date(),
        endDate: Date,
        sourceLabel: String = ""
    ) {
        self.id = UUID()
        self.title = title
        self.premise = premise
        self.objective = objective
        self.startDate = startDate
        self.endDate = endDate
        self.sourceLabel = sourceLabel
        self.createdAt = Date()
        self.milestones = []
        self.chapters = []
    }

    var status: CampaignStatus {
        get { CampaignStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var orderedMilestones: [CampaignMilestone] {
        milestones.sorted { $0.order < $1.order }
    }

    /// The milestones that make up the objective. Only these gate completion.
    var requiredMilestones: [CampaignMilestone] {
        orderedMilestones.filter { !$0.isSideQuest }
    }

    /// Optional objectives — neglected muscles, and anything demoted to keep the
    /// arc reachable.
    var sideQuests: [CampaignMilestone] {
        orderedMilestones.filter(\.isSideQuest)
    }

    var orderedChapters: [CampaignChapter] {
        chapters.sorted { $0.writtenAt > $1.writtenAt }
    }

    /// Total length in whole weeks, rounded up — grows when the arc is extended.
    var weekCount: Int {
        let days = endDate.timeIntervalSince(startDate) / 86_400
        return max(1, Int((days / 7).rounded(.up)))
    }

    /// Which week the lifter is in right now, 1-based and clamped to the arc.
    func currentWeek(now: Date = Date()) -> Int {
        let days = max(0, now.timeIntervalSince(startDate) / 86_400)
        return min(weekCount, Int(days / 7) + 1)
    }

    /// Share of the required objective banked, 0...1.
    var completionFraction: Double {
        let required = requiredMilestones
        guard !required.isEmpty else { return 1 }
        return Double(required.filter(\.isComplete).count) / Double(required.count)
    }

    /// Days left before the deadline; negative once it has passed (which is a
    /// prompt to extend, not a failure).
    func daysRemaining(now: Date = Date()) -> Int {
        Int((endDate.timeIntervalSince(now) / 86_400).rounded(.up))
    }
}

// MARK: - Milestone

/// One objective inside a campaign, persisted.
///
/// The interesting fields are all targets — nothing here records the lifter
/// *saying* they did something, only what the training log has to contain for
/// this to be true.
@Model
final class CampaignMilestone {
    @Attribute(.unique) var id: UUID = UUID()
    var order: Int = 0
    var detail: String = ""
    var kindRaw: String = MilestoneKind.sessionCount.rawValue
    var exerciseName: String? = nil
    var muscleGroupRaw: String? = nil
    var targetLoad: Double = 0
    var targetReps: Int = 0
    var targetCount: Int = 0
    var windowDays: Int = 0
    var isSideQuest: Bool = false
    var isComplete: Bool = false
    /// When the log first satisfied this — the date of the set that did it, not
    /// the date the app noticed. So a milestone earned while offline still reads
    /// as earned on the day it was earned.
    var completedAt: Date? = nil

    var campaign: Campaign?

    init(spec: MilestoneSpec, order: Int) {
        self.id = UUID()
        self.order = order
        self.detail = spec.detail
        self.kindRaw = spec.kind.rawValue
        self.exerciseName = spec.exerciseName
        self.muscleGroupRaw = spec.muscleGroup?.rawValue
        self.targetLoad = spec.targetLoad
        self.targetReps = spec.targetReps
        self.targetCount = spec.targetCount
        self.windowDays = spec.windowDays
        self.isSideQuest = spec.isSideQuest
    }

    var kind: MilestoneKind { MilestoneKind(rawValue: kindRaw) ?? .sessionCount }
    var muscleGroup: MuscleGroup? { muscleGroupRaw.flatMap(MuscleGroup.init(rawValue:)) }

    /// The value-type view evaluation runs against.
    var spec: MilestoneSpec {
        MilestoneSpec(
            detail: detail,
            kind: kind,
            exerciseName: exerciseName,
            muscleGroup: muscleGroup,
            targetLoad: targetLoad,
            targetReps: targetReps,
            targetCount: targetCount,
            windowDays: windowDays,
            isSideQuest: isSideQuest
        )
    }

    /// Which Train-tab focus best serves this milestone, so tapping it lands the
    /// lifter somewhere useful rather than on a generic launcher.
    var suggestedFocus: WorkoutFocus {
        switch muscleGroup {
        case .chest:                       return .chest
        case .lats, .traps:                return .back
        case .deltoids:                    return .shoulders
        case .biceps, .triceps, .forearms: return .arms
        case .quads, .hamstrings, .glutes, .calves: return .legs
        case .core:                        return .core
        case .none:                        return .fullBody
        }
    }
}

// MARK: - Chapter

/// One week's patch notes, filed under the campaign they were written during.
///
/// This is the old Saga, repointed. The notes themselves are unchanged — same
/// generator, same Markdown contract — but they now accumulate into the arc's
/// running story instead of being regenerated over the top of themselves and
/// forgotten on the next launch.
@Model
final class CampaignChapter {
    @Attribute(.unique) var id: UUID = UUID()
    /// Which week of the campaign this covers, 1-based.
    var weekIndex: Int = 1
    var writtenAt: Date = Date()
    /// The notes in `NarrativeEngine`'s Markdown contract — a `## ` title then
    /// `- ` bullets — so `PatchNotesFormatter` renders them exactly as before.
    var markdown: String = ""

    var campaign: Campaign?

    init(weekIndex: Int, markdown: String, writtenAt: Date = Date()) {
        self.id = UUID()
        self.weekIndex = weekIndex
        self.markdown = markdown
        self.writtenAt = writtenAt
    }

    /// The `## ` title line, for collapsed chapter rows.
    var headline: String {
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return "Week \(weekIndex)"
    }
}

// MARK: - Tap-to-train hand-off

/// "Go train this" — the intent a tapped milestone raises.
///
/// Deliberately a value, not a navigation call. `RootTabView` owns tab
/// selection and `WorkoutManager` is already the shared, observable place both
/// tabs can see, so the campaign publishes what the lifter wants to do and the
/// root switches tabs in response. A real deep link into a pre-configured AI
/// generation would have to reach through three sheet presentations that all own
/// their own state, so the Train tab reads the intent as a banner and pre-selects
/// the focus instead.
struct CampaignTrainingIntent: Equatable, Identifiable {
    let id = UUID()
    /// The milestone that raised it, so the banner can be dismissed per-objective.
    var milestoneID: UUID
    /// What the lifter tapped, echoed back on the Train tab.
    var headline: String
    /// The focus the generator should open on.
    var focus: WorkoutFocus
}

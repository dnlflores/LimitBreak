import Foundation
import SwiftData

/// The persistence half of the campaign layer.
///
/// `CampaignEngine` decides things and `CampaignStore` writes them down; the
/// split exists so every rule stays testable without a store. Nothing in here
/// makes a judgement call of its own — it fetches, hands values to the engine,
/// and applies whatever comes back.
@MainActor
enum CampaignStore {

    // MARK: - Lookup

    /// The campaign the lifter is currently running, if any.
    static func active(in context: ModelContext) -> Campaign? {
        let all = (try? context.fetch(FetchDescriptor<Campaign>())) ?? []
        return all
            .filter { $0.status == .active }
            .max { $0.startDate < $1.startDate }
    }

    /// Finished and retired arcs, newest first — the campaign log.
    static func past(in context: ModelContext) -> [Campaign] {
        let all = (try? context.fetch(FetchDescriptor<Campaign>())) ?? []
        return all
            .filter { $0.status != .active }
            .sorted { $0.startDate > $1.startDate }
    }

    // MARK: - Starting

    /// Materializes a blueprint into the store and makes it the running arc.
    ///
    /// Any campaign still marked active is retired rather than deleted — one arc
    /// runs at a time, but the chapters written under the old one are the
    /// lifter's history and never get thrown away.
    @discardableResult
    static func start(
        _ blueprint: CampaignBlueprint,
        in context: ModelContext,
        now: Date = Date()
    ) -> Campaign {
        for existing in (try? context.fetch(FetchDescriptor<Campaign>())) ?? []
        where existing.status == .active {
            existing.status = .retired
        }

        // Anchored to the start of the day, not the minute the button was
        // pressed — a lifter who already trained this morning and then charts an
        // arc should have that session count, not narrowly miss the window.
        let start = Calendar.current.startOfDay(for: now)
        let campaign = Campaign(
            title: blueprint.title,
            premise: blueprint.premise,
            objective: blueprint.objective,
            startDate: start,
            endDate: blueprint.endDate(from: start),
            sourceLabel: blueprint.source.label
        )
        context.insert(campaign)

        for (index, spec) in blueprint.milestones.enumerated() {
            let milestone = CampaignMilestone(spec: spec, order: index)
            milestone.campaign = campaign
            context.insert(milestone)
        }

        try? context.save()
        // A brand-new arc is evaluated immediately: milestones are measured from
        // the start date, and a lifter who already trained today should see that
        // reflected rather than wondering if it counted.
        refresh(campaign, in: context, now: now)
        return campaign
    }

    // MARK: - Refresh

    /// Re-reads the training log, closes any milestone it now satisfies, and
    /// applies whatever adaptation the lifter's pace calls for.
    ///
    /// Safe to call on every appearance — it is idempotent, and a milestone
    /// already complete is never reopened. Completion is stamped with the date of
    /// the set that earned it, not the moment the app noticed.
    @discardableResult
    static func refresh(
        _ campaign: Campaign,
        in context: ModelContext,
        now: Date = Date()
    ) -> CampaignAdaptation {
        guard campaign.status == .active else { return .onTrack }

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let records = (try? context.fetch(FetchDescriptor<PRRecord>())) ?? []
        let log = CampaignLog.build(sessions: sessions, records: records)

        for milestone in campaign.milestones where !milestone.isComplete {
            guard let earned = CampaignEngine.completionDate(
                for: milestone.spec,
                log: log,
                since: campaign.startDate,
                now: now
            ) else { continue }
            milestone.isComplete = true
            milestone.completedAt = earned
        }

        let required = campaign.requiredMilestones
        let pace = CampaignPace.measure(
            requiredTotal: required.count,
            requiredComplete: required.filter(\.isComplete).count,
            start: campaign.startDate,
            end: campaign.endDate,
            now: now
        )
        let adaptation = CampaignEngine.adaptation(pace: pace, extensionsUsed: campaign.extensionCount)
        apply(adaptation, to: campaign)

        try? context.save()
        return adaptation
    }

    /// Writes an adaptation into the campaign.
    ///
    /// The two mutating cases are both survivable by design: extending moves the
    /// deadline, and rescoping *demotes* required milestones to optional side
    /// quests rather than deleting them — so a lifter who did half the work keeps
    /// seeing that half, and the objective simply stops depending on the part
    /// their month couldn't carry.
    private static func apply(_ adaptation: CampaignAdaptation, to campaign: Campaign) {
        switch adaptation {
        case .onTrack:
            break

        case .complete:
            campaign.status = .complete

        case .extended(let days):
            campaign.endDate = campaign.endDate.addingTimeInterval(Double(days) * 86_400)
            campaign.extensionCount += 1

        case .rescoped(let demoting):
            // Shed from the far end first: the last milestones in the arc are the
            // ones the remaining calendar is least likely to reach.
            let candidates = campaign.requiredMilestones
                .filter { !$0.isComplete }
                .sorted { $0.order > $1.order }
            for milestone in candidates.prefix(demoting) {
                milestone.isSideQuest = true
                campaign.rescopeCount += 1
            }
            // Demoting can leave nothing required outstanding, which closes the
            // arc — the lifter finishes what they could actually finish.
            let required = campaign.requiredMilestones
            if !required.isEmpty, required.allSatisfy(\.isComplete) {
                campaign.status = .complete
            }
        }
    }

    // MARK: - Chapters

    /// Files a week's patch notes into the running arc.
    ///
    /// This is where the old Saga ended up. The notes are generated exactly as
    /// before — same `NarrativeEngine`, same Markdown contract — they just have
    /// somewhere to live now.
    @discardableResult
    static func recordChapter(
        markdown: String,
        in campaign: Campaign,
        context: ModelContext,
        now: Date = Date()
    ) -> CampaignChapter {
        let chapter = CampaignChapter(
            weekIndex: campaign.currentWeek(now: now),
            markdown: markdown,
            writtenAt: now
        )
        chapter.campaign = campaign
        context.insert(chapter)
        try? context.save()
        return chapter
    }

    // MARK: - Retiring

    /// Ends an arc early at the lifter's request. Retired, never deleted.
    static func retire(_ campaign: Campaign, in context: ModelContext) {
        campaign.status = .retired
        try? context.save()
    }

    // MARK: - Context assembly

    /// Builds the coach's view of the lifter for campaign generation.
    ///
    /// Reuses `TrainingContext` verbatim rather than defining a parallel view:
    /// the arc is planned off the same cadence, ceilings and fatigue the session
    /// coach reads, and two drifting definitions of "the lifter's state" is a bug
    /// waiting to happen.
    static func trainingContext(
        for profile: TrainingProfile,
        in context: ModelContext,
        now: Date = Date()
    ) -> TrainingContext {
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        return TrainingContext.build(
            profile: profile,
            sessions: sessions,
            exercises: exercises,
            withPartner: false,
            now: now
        )
    }
}

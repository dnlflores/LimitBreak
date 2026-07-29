import SwiftUI
import SwiftData

/// The Campaign tab: the app's only forward-looking screen.
///
/// It replaced the Saga, which wrote a weekly recap of numbers the lifter had
/// already lived through and then forgot it. This shows the arc they're in the
/// middle of — what it's for, how far through it they are, and which objectives
/// their own training log has already closed. The recap survives inside it, as
/// the arc's chapters.
struct CampaignView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkoutManager.self) private var workout

    @Query private var profiles: [TrainingProfile]
    @Query(sort: \Campaign.startDate, order: .reverse) private var campaigns: [Campaign]

    @State private var isForging = false
    @State private var isWritingChapter = false
    /// What the last refresh did to the plan, so the lifter is told when their
    /// arc changed shape rather than finding a different deadline silently.
    @State private var adaptation: CampaignAdaptation = .onTrack

    private var campaign: Campaign? {
        campaigns.first { $0.status == .active }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let campaign {
                        arcCard(campaign)
                        adaptationNote(campaign)
                        objectiveSection(campaign)
                        sideQuestSection(campaign)
                        chapterSection(campaign)
                    } else {
                        pitchCard
                        forgeButton
                    }

                    Text(privacyFooter)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: refresh)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Campaign")
                .font(.largeTitle.bold())
            Spacer()
            if let campaign {
                Menu {
                    Button("Retire this campaign", systemImage: "flag.slash", role: .destructive) {
                        CampaignStore.retire(campaign, in: modelContext)
                        Haptics.shared.tick()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(Theme.textDim)
                        .glassCircle(diameter: 38)
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Running arc

    private func arcCard(_ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(campaign.sourceLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            Text(campaign.title)
                .font(.system(.title, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.limitBreakGradient)
                .fixedSize(horizontal: false, vertical: true)

            Text(campaign.premise)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.stroke)

            Text(campaign.objective)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.teal)
                .fixedSize(horizontal: false, vertical: true)

            progressBar(campaign)

            HStack {
                Label("Week \(campaign.currentWeek()) of \(campaign.weekCount)", systemImage: "calendar")
                Spacer()
                Text(remainingText(campaign))
            }
            .font(.caption)
            .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.limitBreakGradient.opacity(0.5), lineWidth: 1)
        )
    }

    private func progressBar(_ campaign: Campaign) -> some View {
        let done = campaign.requiredMilestones.filter(\.isComplete).count
        let total = max(1, campaign.requiredMilestones.count)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    Capsule()
                        .fill(Theme.limitBreakGradient)
                        .frame(width: proxy.size.width * campaign.completionFraction)
                }
            }
            .frame(height: 8)

            Text("\(done) of \(total) objectives cleared")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
    }

    /// Days left, or an honest read of an overrun deadline. A campaign past its
    /// end date is never described as failed — the next refresh extends it.
    private func remainingText(_ campaign: Campaign) -> String {
        let days = campaign.daysRemaining()
        if days > 1 { return "\(days) days left" }
        if days == 1 { return "1 day left" }
        return "Final stretch"
    }

    /// Says out loud when the plan changed under the lifter. Silence here would
    /// make an extended deadline feel like a bug.
    @ViewBuilder
    private func adaptationNote(_ campaign: Campaign) -> some View {
        switch adaptation {
        case .extended(let days):
            note(
                icon: "calendar.badge.plus",
                tint: Theme.teal,
                text: "The arc needed more road, so it got \(days) more days. Nothing was lost — "
                    + "campaigns bend before they break."
            )
        case .rescoped(let count):
            note(
                icon: "arrow.triangle.branch",
                tint: Theme.coral,
                text: "\(count) objective\(count == 1 ? "" : "s") moved to side quests so this arc "
                    + "stays finishable. Everything you've already banked still counts."
            )
        case .complete, .onTrack:
            if campaign.rescopeCount > 0 || campaign.extensionCount > 0 {
                note(
                    icon: "arrow.triangle.2.circlepath",
                    tint: Theme.textDim,
                    text: "This arc has been re-planned around your real cadence "
                        + "(\(campaign.extensionCount) extension\(campaign.extensionCount == 1 ? "" : "s"), "
                        + "\(campaign.rescopeCount) rescope\(campaign.rescopeCount == 1 ? "" : "s"))."
                )
            }
        }
    }

    private func note(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    // MARK: - Objectives

    private func objectiveSection(_ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("OBJECTIVES", icon: "target")
            ForEach(campaign.requiredMilestones) { milestone in
                milestoneRow(milestone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private func sideQuestSection(_ campaign: Campaign) -> some View {
        let quests = campaign.sideQuests
        if !quests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("SIDE QUESTS", icon: "sparkles")
                Text("Optional. Drawn from the muscles you've stopped training.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
                ForEach(quests) { milestone in
                    milestoneRow(milestone)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// One objective. There is no check-off control anywhere on this row by
    /// design — the only way to complete a milestone is to log the training that
    /// satisfies it, so the tap target goes to the Train tab instead.
    private func milestoneRow(_ milestone: CampaignMilestone) -> some View {
        Button {
            train(milestone)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: milestone.isComplete ? "checkmark.seal.fill" : milestone.kind.icon)
                    .font(.headline)
                    .foregroundStyle(milestone.isComplete ? Theme.emerald : Theme.violet)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(milestone.detail)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(milestone.isComplete ? Theme.textDim : .white)
                        .strikethrough(milestone.isComplete, color: Theme.textDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let earned = milestone.completedAt {
                        Text("Cleared \(earned.formatted(.dateTime.month().day()))")
                            .font(.caption2)
                            .foregroundStyle(Theme.emerald)
                    }
                }

                Spacer(minLength: 0)

                if !milestone.isComplete {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(milestone.isComplete)
    }

    // MARK: - Chapters

    private func chapterSection(_ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("CHAPTERS", icon: "scroll.fill")

            if campaign.chapters.isEmpty {
                Text("Each week's patch notes are filed here as a chapter of this arc.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            ForEach(campaign.orderedChapters) { chapter in
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEEK \(chapter.weekIndex) \u{2022} \(chapter.writtenAt.formatted(.dateTime.month().day()))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1.2)
                    PatchNotesBody(markdown: chapter.markdown)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Button {
                writeChapter(campaign)
            } label: {
                HStack {
                    if isWritingChapter {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("WRITE THIS WEEK'S CHAPTER")
                        .font(.subheadline.weight(.bold))
                        .kerning(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.limitBreakGradient, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.black)
            }
            .disabled(isWritingChapter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Empty state

    private var pitchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("No campaign running")
                .font(.title3.weight(.bold))
            Text("A campaign is a 4 to 8 week arc with one objective, built from what you've "
                 + "actually been lifting. Its milestones close themselves as you train — there's "
                 + "nothing to tick off. Fall behind and the arc re-plans around you rather than "
                 + "writing you off.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var forgeButton: some View {
        Button {
            forge()
        } label: {
            HStack {
                if isForging {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "map.fill")
                }
                Text(isForging ? "CHARTING\u{2026}" : "CHART A CAMPAIGN")
                    .font(.subheadline.weight(.bold))
                    .kerning(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.limitBreakGradient, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.black)
        }
        .disabled(isForging)
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.gold)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)
        }
    }

    // MARK: - Actions

    /// Re-reads the training log so milestones close themselves, and applies any
    /// adaptation the lifter's pace calls for. Cheap and idempotent, so it runs
    /// on every appearance rather than on a schedule the lifter can't see.
    private func refresh() {
        guard let campaign else { return }
        adaptation = CampaignStore.refresh(campaign, in: modelContext)
    }

    /// The provider to route through, or nil when cloud AI is off — in which
    /// case the arc is charted on-device.
    private var activeProvider: AIProvider? {
        guard let profile = profiles.first, profile.cloudAIEnabled else { return nil }
        return profile.aiProvider
    }

    private func forge() {
        guard !isForging else { return }
        isForging = true
        Haptics.shared.tick()

        let profile = TrainingProfile.current(in: modelContext)
        let context = CampaignStore.trainingContext(for: profile, in: modelContext)
        let provider = activeProvider

        Task { @MainActor in
            let blueprint = await CampaignGenerator.propose(context: context, provider: provider)
            withAnimation(.spring(duration: 0.4)) {
                CampaignStore.start(blueprint, in: modelContext)
                isForging = false
            }
            Haptics.shared.success()
        }
    }

    /// Generates this week's patch notes and files them as a chapter. Same
    /// generator the Saga used — the notes just aren't thrown away now.
    private func writeChapter(_ campaign: Campaign) {
        guard !isWritingChapter else { return }
        isWritingChapter = true
        Haptics.shared.tick()

        let telemetry = NarrativeEngine.weeklyTelemetry(context: modelContext)
        let provider = activeProvider

        Task { @MainActor in
            let notes = await NarrativeEngine.generatePatchNotes(from: telemetry, provider: provider)
            withAnimation(.spring(duration: 0.4)) {
                CampaignStore.recordChapter(markdown: notes, in: campaign, context: modelContext)
                isWritingChapter = false
            }
            Haptics.shared.success()
        }
    }

    /// Raises the "go train this" intent. `RootTabView` is watching for it and
    /// switches to the Train tab; the launcher there reads it as a banner.
    private func train(_ milestone: CampaignMilestone) {
        Haptics.shared.tick()
        workout.campaignIntent = CampaignTrainingIntent(
            milestoneID: milestone.id,
            headline: milestone.detail,
            focus: milestone.suggestedFocus
        )
    }

    /// Where the arc is composed — and therefore where the lifter's training
    /// history goes — tracks the AI provider chosen in Settings.
    private var privacyFooter: String {
        let onDevice = "Campaigns are charted entirely on-device. Your training history never leaves this phone."
        guard let profile = profiles.first, profile.cloudAIEnabled else { return onDevice }
        switch profile.aiProvider {
        case .claude where CloudWorkoutAI.isConfigured:
            return "Campaigns are charted by Claude. Your training summary is sent to Anthropic to plan the arc — nothing else leaves your device."
        case .odysseus where OdysseusConfig.isConfigured:
            return "Campaigns are charted by your own Odysseus server. Your training summary is sent over your tailnet — nothing else leaves your device."
        default:
            return onDevice
        }
    }
}

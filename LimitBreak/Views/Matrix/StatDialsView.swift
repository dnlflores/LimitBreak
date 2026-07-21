import SwiftUI

/// Three tappable gauge dials: weekly volume vs last week, session count vs
/// goal, and muscle recovery. Tapping a dial opens its workout breakdown.
struct StatDialsView: View {
    let sessions: [WorkoutSession]

    @State private var selectedDial: Dial?

    private enum Dial: String, Identifiable {
        case volume, sessions, recovery
        var id: String { rawValue }
    }

    private static let weeklySessionGoal = 5

    // MARK: - Weekly math

    private var thisWeekSessions: [WorkoutSession] {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return sessions.filter { $0.startDate >= weekAgo }
    }

    private var lastWeekSessions: [WorkoutSession] {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        return sessions.filter { $0.startDate >= twoWeeksAgo && $0.startDate < weekAgo }
    }

    private var thisWeekVolume: Double { thisWeekSessions.reduce(0) { $0 + $1.totalVolume } }
    private var lastWeekVolume: Double { lastWeekSessions.reduce(0) { $0 + $1.totalVolume } }

    private var statuses: [MuscleGroup: MuscleStatus] {
        MuscleRecovery.statuses(sessions: sessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("POWER DIALS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            // Floating Liquid Glass orbs; close siblings blend their glass together.
            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 12) {
                    volumeDial
                    sessionsDial
                    recoveryDial
                }
            }
        }
        .sheet(item: $selectedDial) { dial in
            dialBreakdown(dial)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Dials

    private var volumeDial: some View {
        let progress = lastWeekVolume > 0
            ? min(thisWeekVolume / lastWeekVolume, 1)
            : (thisWeekVolume > 0 ? 1 : 0)
        return RingDial(
            title: "Volume",
            value: Int(thisWeekVolume).formatted(.number.notation(.compactName)),
            subtitle: lastWeekVolume > 0
                ? "of \(Int(lastWeekVolume).formatted(.number.notation(.compactName))) last wk"
                : "this week",
            progress: progress,
            color: Theme.violet
        ) {
            selectedDial = .volume
        }
    }

    private var sessionsDial: some View {
        RingDial(
            title: "Sessions",
            value: "\(thisWeekSessions.count)",
            subtitle: "of \(Self.weeklySessionGoal) this wk",
            progress: min(Double(thisWeekSessions.count) / Double(Self.weeklySessionGoal), 1),
            color: Theme.emerald
        ) {
            selectedDial = .sessions
        }
    }

    private var recoveryDial: some View {
        let fraction = MuscleRecovery.readyFraction(statuses: statuses)
        return RingDial(
            title: "Recovery",
            value: "\(Int((fraction * 100).rounded()))%",
            subtitle: "muscles ready",
            progress: fraction,
            color: Theme.gold
        ) {
            selectedDial = .recovery
        }
    }

    // MARK: - Breakdown sheets

    @ViewBuilder
    private func dialBreakdown(_ dial: Dial) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch dial {
                    case .volume: volumeBreakdown
                    case .sessions: sessionsBreakdown
                    case .recovery: recoveryBreakdown
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle(breakdownTitle(dial))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedDial = nil }
                }
            }
        }
    }

    private func breakdownTitle(_ dial: Dial) -> String {
        switch dial {
        case .volume: "Weekly Volume"
        case .sessions: "This Week's Sessions"
        case .recovery: "Muscle Recovery"
        }
    }

    private var volumeBreakdown: some View {
        Group {
            HStack {
                comparisonTile(label: "THIS WEEK", value: thisWeekVolume, color: Theme.violet)
                comparisonTile(label: "LAST WEEK", value: lastWeekVolume, color: Theme.textDim)
            }
            if thisWeekSessions.isEmpty {
                emptyNote("No sessions logged this week yet.")
            }
            ForEach(thisWeekSessions, id: \.id) { session in
                sessionRow(session)
            }
        }
    }

    private var sessionsBreakdown: some View {
        Group {
            if thisWeekSessions.isEmpty {
                emptyNote("No sessions logged this week yet.")
            }
            ForEach(thisWeekSessions, id: \.id) { session in
                sessionRow(session)
            }
        }
    }

    private var recoveryBreakdown: some View {
        ForEach(MuscleGroup.allCases) { group in
            let status = statuses[group] ?? MuscleStatus(group: group)
            let state = status.state()
            HStack {
                Circle()
                    .fill(state.color)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rawValue)
                        .font(.subheadline.weight(.semibold))
                    if let last = status.lastTrained {
                        Text("Last trained \(last.formatted(.relative(presentation: .named))) · \(status.weeklySets) sets this week")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    } else {
                        Text("Not trained in the last week")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Spacer()
                Text(state.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state == .dormant ? Theme.textDim : state.color)
            }
            .cardStyle()
        }
    }

    private func comparisonTile(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(Int(value).formatted(.number.notation(.compactName)))
                .statNumberStyle()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Text("\(Int(session.totalVolume).formatted()) lbs")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.emerald)
        }
        .cardStyle()
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .cardStyle()
    }
}

// MARK: - Ring dial component

private struct RingDial: View {
    let title: String
    let value: String
    let subtitle: String
    let progress: Double
    let color: Color
    let action: () -> Void

    @State private var animatedProgress: Double = 0

    var body: some View {
        Button {
            Haptics.shared.tick()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: animatedProgress)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.5), radius: 3)

                    VStack(spacing: 1) {
                        Text(value)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text(subtitle)
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 10)
                }
                .padding(6)
                .frame(width: 90, height: 90)
                .glassEffect(.regular.interactive(), in: .circle)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.spring(duration: 0.8)) {
                animatedProgress = progress
            }
        }
        .onChange(of: progress) { _, newValue in
            withAnimation(.spring(duration: 0.5)) {
                animatedProgress = newValue
            }
        }
    }
}

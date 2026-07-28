import SwiftUI
import SwiftData

/// The skill tree: every exercise and routine the lifter has trained, ranked by
/// how deeply it's been ground. Each workout climbs mastery levels the more it's
/// performed, and every rank paid out bonus XP into the level curve.
struct MasteryView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var routines: [Routine]

    enum Scope: String, CaseIterable, Identifiable {
        case exercises = "Exercises"
        case routines = "Routines"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .exercises
    @State private var selected: Mastery.Rank?

    private var exerciseRanks: [Mastery.Rank] { Mastery.exerciseRanks(in: sessions) }
    private var routineRanks: [Mastery.Rank] { Mastery.routineRanks(in: sessions, routines: routines) }

    private var shownRanks: [Mastery.Rank] {
        scope == .exercises ? exerciseRanks : routineRanks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                scopePicker

                if shownRanks.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(shownRanks) { rank in
                            Button {
                                Haptics.shared.tick()
                                selected = rank
                            } label: {
                                MasteryRankRow(rank: rank)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selected) { rank in
            MasteryDetailSheet(rank: rank, log: logEntries(for: rank))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workout Mastery")
                    .font(.title2.bold())
                Text("Every rep of a movement sharpens the skill.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Scope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
    }

    private var emptyState: some View {
        Text(scope == .exercises
             ? "No skills yet. Log a working set to start ranking up your first movement."
             : "No routines run yet. Start a saved routine to begin leveling it up.")
            .font(.subheadline)
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .cardStyle()
    }

    // MARK: - Breakdown

    /// The training log behind a rank — every session that counted toward it,
    /// newest first, so the detail sheet can show the workouts that built it.
    private func logEntries(for rank: Mastery.Rank) -> [MasteryLogEntry] {
        switch rank.kind {
        case .exercise:
            return sessions.compactMap { session in
                let working = session.sets.filter { !$0.isWarmup && $0.exercise?.id == rank.id }
                guard !working.isEmpty else { return nil }
                let volume = working.reduce(0.0) { $0 + max(0, $1.effectiveLoad) * Double($1.reps) }
                return MasteryLogEntry(
                    date: session.startDate,
                    title: session.name,
                    detail: "\(working.count) set\(working.count == 1 ? "" : "s") · \(Int(volume).formatted()) lbs"
                )
            }
        case .routine:
            return sessions.compactMap { session in
                guard session.startedFromRoutineID == rank.id, !session.sets.isEmpty else { return nil }
                let movements = session.setsByExercise.count
                return MasteryLogEntry(
                    date: session.startDate,
                    title: session.name,
                    detail: "\(movements) exercise\(movements == 1 ? "" : "s") · \(Int(session.totalVolume).formatted()) lbs"
                )
            }
        }
    }
}

/// One session in a mastery breakdown.
struct MasteryLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
}

// MARK: - Rank row

/// A workout's mastery standing: badge, name, rank title, and a bar toward the
/// next level. Shared by the Skill Matrix teaser and the full skill tree.
struct MasteryRankRow: View {
    let rank: Mastery.Rank

    var body: some View {
        HStack(spacing: 12) {
            MasteryBadge(rank: rank, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(rank.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(rank.title.uppercased())
                        .font(.system(size: 10, weight: .black))
                        .kerning(0.8)
                        .foregroundStyle(rank.tint)
                }

                MasteryProgressBar(progress: rank.progress, tint: rank.tint)

                Text("\(rank.completions) done · \(rank.completionsRemaining) to LV \(rank.level + 1)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// The mastery seal — a tinted rounded badge stamping the current level.
struct MasteryBadge: View {
    let rank: Mastery.Rank
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(rank.tint.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(rank.tint.opacity(0.7), lineWidth: 1.5)

            VStack(spacing: 0) {
                Image(systemName: rank.icon)
                    .font(.system(size: size * 0.24, weight: .bold))
                Text("LV \(rank.level)")
                    .font(.system(size: size * 0.2, weight: .black))
                    .monospacedDigit()
            }
            .foregroundStyle(rank.tint)
        }
        .frame(width: size, height: size)
    }
}

/// A slim, tinted progress bar for mastery — mirrors XPProgressBar but carries
/// the rank's own color instead of the global level gradient.
struct MasteryProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Detail sheet

/// The full standing for a single workout: hero badge, progress to next rank,
/// the rank ladder with its XP payouts, and the training log that earned it.
struct MasteryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rank: Mastery.Rank
    let log: [MasteryLogEntry]

    /// Levels to show in the ladder — through the current rank plus a couple to
    /// chase, and at least the first six so a fresh skill shows a full road.
    private var ladderLevels: [Int] {
        Array(1...max(rank.level + 2, 6))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                ladder
                if !log.isEmpty { breakdown }
            }
            .padding()
        }
        .obsidianBackground()
        .presentationDragIndicator(.visible)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            MasteryBadge(rank: rank, size: 92)

            VStack(spacing: 4) {
                Text(rank.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("\(rank.title.uppercased()) · \(rank.isRoutine ? "ROUTINE" : "SKILL")")
                    .font(.caption.weight(.black))
                    .kerning(1.2)
                    .foregroundStyle(rank.tint)
            }

            VStack(spacing: 6) {
                MasteryProgressBar(progress: rank.progress, tint: rank.tint, height: 10)
                Text("\(rank.completions) completions · \(rank.completionsRemaining) more to LV \(rank.level + 1) (+\(rank.nextLevelXP) XP)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var ladder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RANK LADDER")
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)

            VStack(spacing: 8) {
                ForEach(ladderLevels, id: \.self) { level in
                    ladderRow(level: level)
                }
            }
            .cardStyle()
        }
    }

    private func ladderRow(level: Int) -> some View {
        let needed = Mastery.completions(toReachLevel: level)
        let reached = rank.completions >= needed
        let isCurrent = level == rank.level
        return HStack(spacing: 10) {
            Image(systemName: reached ? "checkmark.seal.fill" : "seal")
                .font(.subheadline)
                .foregroundStyle(reached ? rank.tint : Theme.textDim.opacity(0.5))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("LV \(level) · \(Mastery.title(forLevel: level))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isCurrent ? rank.tint : Color.primary)
                Text("\(needed) completion\(needed == 1 ? "" : "s")")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            Text("+\(Mastery.xp(forLevel: level, isRoutine: rank.isRoutine)) XP")
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(reached ? rank.tint : Theme.textDim)
        }
        .opacity(reached || isCurrent ? 1 : 0.7)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRAINING LOG")
                .font(.caption.weight(.bold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)

            VStack(spacing: 8) {
                ForEach(log) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: rank.icon)
                            .font(.caption)
                            .foregroundStyle(rank.tint)
                            .frame(width: 28, height: 28)
                            .background(rank.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(entry.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                        }

                        Spacer()

                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
            .cardStyle()
        }
    }
}

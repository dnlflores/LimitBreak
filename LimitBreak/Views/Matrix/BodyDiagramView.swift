import SwiftUI

/// Front + back "training dummy" figures, one tinted segment per muscle group.
/// Segment color reflects recovery state; tapping a segment opens a breakdown
/// of everything that hit that muscle in the last week.
struct BodyDiagramView: View {
    let sessions: [WorkoutSession]

    @State private var selectedGroup: MuscleGroup?

    private var statuses: [MuscleGroup: MuscleStatus] {
        MuscleRecovery.statuses(sessions: sessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BODY STATUS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            HStack(spacing: 28) {
                figure(title: "FRONT", segments: BodyFigure.front)
                figure(title: "BACK", segments: BodyFigure.back)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                legendDot(state: .needsRest)
                legendDot(state: .recovering)
                legendDot(state: .ready)
                legendDot(state: .dormant)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(Theme.textDim)
        }
        .cardStyle()
        .sheet(item: $selectedGroup) { group in
            MuscleDetailSheet(
                group: group,
                status: statuses[group] ?? MuscleStatus(group: group),
                sessions: sessions
            )
        }
    }

    private func figure(title: String, segments: [BodySegment]) -> some View {
        VStack(spacing: 8) {
            ZStack {
                // Head anchors the silhouette; it isn't a muscle group.
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 20, height: 20)
                    .position(x: 55, y: 16)

                ForEach(segments) { segment in
                    segmentView(segment)
                }
            }
            .frame(width: 110, height: 214)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
        }
    }

    private func segmentView(_ segment: BodySegment) -> some View {
        let state = statuses[segment.group]?.state() ?? .dormant
        return RoundedRectangle(cornerRadius: segment.cornerRadius)
            .fill(state.color.opacity(state == .dormant ? 1 : 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: segment.cornerRadius)
                    .strokeBorder(state == .dormant ? Theme.stroke : state.color, lineWidth: 1)
            )
            .frame(width: segment.size.width, height: segment.size.height)
            .rotationEffect(.degrees(segment.rotation))
            .position(segment.center)
            .onTapGesture {
                Haptics.shared.tick()
                selectedGroup = segment.group
            }
    }

    private func legendDot(state: FreshnessState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.rawValue)
        }
    }
}

// MARK: - Figure geometry

/// One tappable shape in the 110x214 figure design space.
private struct BodySegment: Identifiable {
    let id: String
    let group: MuscleGroup
    let center: CGPoint
    let size: CGSize
    let cornerRadius: CGFloat
    var rotation: Double = 0

    init(_ id: String, _ group: MuscleGroup, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, rotation: Double = 0) {
        self.id = id
        self.group = group
        self.center = CGPoint(x: x, y: y)
        self.size = CGSize(width: w, height: h)
        self.cornerRadius = r
        self.rotation = rotation
    }
}

private enum BodyFigure {
    static let front: [BodySegment] = [
        BodySegment("delt-fl", .deltoids, x: 33, y: 40, w: 16, h: 13, r: 6),
        BodySegment("delt-fr", .deltoids, x: 77, y: 40, w: 16, h: 13, r: 6),
        BodySegment("chest-l", .chest, x: 45.5, y: 54, w: 19, h: 17, r: 6),
        BodySegment("chest-r", .chest, x: 64.5, y: 54, w: 19, h: 17, r: 6),
        BodySegment("bicep-l", .biceps, x: 25, y: 68, w: 11, h: 24, r: 5.5, rotation: -7),
        BodySegment("bicep-r", .biceps, x: 85, y: 68, w: 11, h: 24, r: 5.5, rotation: 7),
        BodySegment("core", .core, x: 55, y: 82, w: 26, h: 36, r: 8),
        BodySegment("forearm-fl", .forearms, x: 20, y: 95, w: 9, h: 26, r: 4.5, rotation: -9),
        BodySegment("forearm-fr", .forearms, x: 90, y: 95, w: 9, h: 26, r: 4.5, rotation: 9),
        BodySegment("quad-l", .quads, x: 46, y: 126, w: 15, h: 44, r: 7.5),
        BodySegment("quad-r", .quads, x: 64, y: 126, w: 15, h: 44, r: 7.5),
        BodySegment("calf-fl", .calves, x: 45, y: 178, w: 12, h: 42, r: 6),
        BodySegment("calf-fr", .calves, x: 65, y: 178, w: 12, h: 42, r: 6),
    ]

    static let back: [BodySegment] = [
        BodySegment("delt-bl", .deltoids, x: 33, y: 40, w: 16, h: 13, r: 6),
        BodySegment("delt-br", .deltoids, x: 77, y: 40, w: 16, h: 13, r: 6),
        BodySegment("lat-l", .lats, x: 44, y: 62, w: 15, h: 32, r: 7, rotation: -6),
        BodySegment("lat-r", .lats, x: 66, y: 62, w: 15, h: 32, r: 7, rotation: 6),
        BodySegment("tricep-l", .triceps, x: 25, y: 68, w: 11, h: 24, r: 5.5, rotation: -7),
        BodySegment("tricep-r", .triceps, x: 85, y: 68, w: 11, h: 24, r: 5.5, rotation: 7),
        BodySegment("forearm-bl", .forearms, x: 20, y: 95, w: 9, h: 26, r: 4.5, rotation: -9),
        BodySegment("forearm-br", .forearms, x: 90, y: 95, w: 9, h: 26, r: 4.5, rotation: 9),
        BodySegment("glute-l", .glutes, x: 46.5, y: 96, w: 16, h: 15, r: 7),
        BodySegment("glute-r", .glutes, x: 63.5, y: 96, w: 16, h: 15, r: 7),
        BodySegment("ham-l", .hamstrings, x: 46, y: 129, w: 15, h: 44, r: 7.5),
        BodySegment("ham-r", .hamstrings, x: 64, y: 129, w: 15, h: 44, r: 7.5),
        BodySegment("calf-bl", .calves, x: 45, y: 180, w: 12, h: 42, r: 6),
        BodySegment("calf-br", .calves, x: 65, y: 180, w: 12, h: 42, r: 6),
    ]
}

// MARK: - Muscle breakdown sheet

/// Everything that hit one muscle group in the last 7 days.
private struct MuscleDetailSheet: View {
    let group: MuscleGroup
    let status: MuscleStatus
    let sessions: [WorkoutSession]

    @Environment(\.dismiss) private var dismiss

    private struct ExerciseHit: Identifiable {
        let id: String
        let exerciseName: String
        let sessionName: String
        let date: Date
        let isPrimary: Bool
        let setCount: Int
        let volume: Double
        let prCount: Int
    }

    private var hits: [ExerciseHit] {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        var result: [ExerciseHit] = []
        for session in sessions where session.startDate >= weekAgo {
            for (exercise, sets) in session.setsByExercise {
                guard exercise.allMuscleGroups.contains(group) else { continue }
                let working = sets.filter { !$0.isWarmup }
                guard !working.isEmpty else { continue }
                result.append(ExerciseHit(
                    id: "\(session.id)-\(exercise.id)",
                    exerciseName: exercise.name,
                    sessionName: session.name,
                    date: session.startDate,
                    isPrimary: exercise.muscleGroup == group,
                    setCount: working.count,
                    volume: working.reduce(0) { $0 + $1.weight * Double($1.reps) },
                    prCount: working.filter(\.isPR).count
                ))
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader

                    if hits.isEmpty {
                        Text("No sets hit this muscle in the last 7 days.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .cardStyle()
                    } else {
                        ForEach(hits) { hit in
                            hitRow(hit)
                        }
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle(group.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var statusHeader: some View {
        let state = status.state()
        return HStack(spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.rawValue)
                    .font(.headline)
                    .foregroundStyle(state == .dormant ? Theme.textDim : state.color)
                if let last = status.lastTrained {
                    Text("Last trained \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("Not trained in the last week")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(status.weeklySets)")
                    .statNumberStyle()
                Text("sets / 7d")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .cardStyle()
    }

    private func hitRow(_ hit: ExerciseHit) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.exerciseName)
                        .font(.subheadline.weight(.semibold))
                    if !hit.isPrimary {
                        Text("SECONDARY")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceRaised, in: Capsule())
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Text("\(hit.sessionName) · \(hit.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(hit.setCount) set\(hit.setCount == 1 ? "" : "s") · \(Int(hit.volume).formatted()) lbs")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)
                if hit.prCount > 0 {
                    Text("\(hit.prCount) LimitBreak\(hit.prCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Theme.gold)
                }
            }
        }
        .cardStyle()
    }
}

import SwiftUI
import SwiftData
import MapKit

/// The full battle report for one day: every session, every set, every walk.
struct DayDetailSheet: View {
    let day: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \WorkoutSession.startDate) private var allSessions: [WorkoutSession]
    @Query(sort: \Walk.date) private var allWalks: [Walk]

    @State private var sessionToEdit: WorkoutSession?
    @State private var sessionToDelete: WorkoutSession?

    private var dayInterval: DateInterval {
        Calendar.current.dateInterval(of: .day, for: day)!
    }

    private var sessions: [WorkoutSession] {
        allSessions.filter { dayInterval.contains($0.startDate) }
    }

    private var walks: [Walk] {
        allWalks.filter { dayInterval.contains($0.date) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryHeader

                    ForEach(sessions, id: \.id) { session in
                        sessionCard(session)
                    }

                    ForEach(walks, id: \.id) { walk in
                        walkCard(walk)
                    }

                    if sessions.isEmpty && walks.isEmpty {
                        Text("Nothing logged this day.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .cardStyle()
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $sessionToEdit) { session in
                EditWorkoutView(session: session)
            }
            .alert("Delete Workout?", isPresented: deleteAlertBinding, presenting: sessionToDelete) { session in
                Button("Delete", role: .destructive) {
                    workout.deleteSession(session)
                }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("\"\(session.name)\" and all its sets will be permanently removed. Records will be recalculated.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Bridges the `presenting:` alert to the optional session state.
    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    // MARK: - Summary

    private var summaryHeader: some View {
        let volume = sessions.reduce(0) { $0 + $1.totalVolume }
        let prCount = sessions.reduce(0) { $0 + $1.prCount }
        let walkMiles = walks.reduce(0) { $0 + $1.distanceMiles }

        return HStack(spacing: 12) {
            summaryTile(value: Int(volume).formatted(.number.notation(.compactName)), label: "lbs shifted", color: Theme.emerald)
            summaryTile(value: "\(prCount)", label: "LimitBreaks", color: Theme.gold)
            summaryTile(
                value: walkMiles > 0 ? String(format: "%.1f mi", walkMiles) : "\(sessions.count)",
                label: walkMiles > 0 ? "walked" : "sessions",
                color: Theme.teal
            )
        }
    }

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .statNumberStyle()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - Session card

    private func sessionCard(_ session: WorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.headline)
                    Text("\(session.startDate.formatted(date: .omitted, time: .shortened)) · \(session.duration.clockString)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text("\(Int(session.totalVolume).formatted()) lbs")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.emerald)

                Menu {
                    Button {
                        sessionToEdit = session
                    } label: {
                        Label("Edit Workout", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        sessionToDelete = session
                    } label: {
                        Label("Delete Workout", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
            }

            ForEach(session.setsByExercise, id: \.exercise.id) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.exercise.name)
                        .font(.subheadline.weight(.semibold))

                    ForEach(group.sets, id: \.id) { set in
                        setLine(set, exercise: group.exercise)
                    }
                }
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .cardStyle()
    }

    private func setLine(_ set: ExerciseSet, exercise: Exercise) -> some View {
        HStack(spacing: 6) {
            Text(setDescription(set, exercise: exercise))
                .font(.caption)
                .monospacedDigit()
            if set.isWarmup {
                Text("WARMUP")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.textDim)
            }
            if set.isPR {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.gold)
            }
            Spacer()
        }
    }

    private func setDescription(_ set: ExerciseSet, exercise: Exercise) -> String {
        switch exercise.trackingType {
        case .durationAndReps:
            if let duration = set.durationSeconds { return "\(duration.clockString)" }
        case .timeAndDistance:
            if let distance = set.distanceMeters { return "\(Int(distance)) m" }
        case .customMetric:
            return "\(set.weight.cleanWeight) \(exercise.customMetricUnit ?? "")"
        case .weightAndReps, .bodyweightAndReps:
            break
        }
        return set.weight > 0
            ? "\(set.weight.cleanWeight) lbs × \(set.reps)"
            : "\(set.reps) reps"
    }

    // MARK: - Walk card

    private func walkCard(_ walk: Walk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Walk")
                            .font(.headline)
                        Text(walk.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                } icon: {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(Theme.teal)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f mi", walk.distanceMiles))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.teal)
                    if walk.durationSeconds > 0 {
                        Text(walk.durationSeconds.clockString)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }

            if walk.routePoints.count >= 2 {
                routePreview(walk)
            }
        }
        .cardStyle()
    }

    private func routePreview(_ walk: Walk) -> some View {
        let coordinates = walk.routePoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return Map(interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.teal, lineWidth: 4)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}

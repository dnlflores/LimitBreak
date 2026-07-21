import SwiftUI
import SwiftData
import Combine

/// The Train tab: session launcher when idle, kinetic logging arena when active.
struct TrainView: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        NavigationStack {
            Group {
                if workout.activeSession != nil {
                    ActiveSessionView()
                } else {
                    SessionLauncherView()
                }
            }
            .obsidianBackground()
        }
    }
}

// MARK: - Launcher

private struct SessionLauncherView: View {
    @Environment(WorkoutManager.self) private var workout
    @State private var sessionName = ""
    @State private var showPastWorkout = false
    @State private var showWalkDraw = false

    private let suggestions = ["Push Day", "Pull Day", "Leg Day", "Upper Body", "Full Body"]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.limitBreakGradient)

            Text("Ready to break limits?")
                .font(.title2.weight(.bold))

            VStack(spacing: 12) {
                TextField("Session name", text: $sessionName)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassBorder, lineWidth: 1))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                sessionName = suggestion
                                Haptics.shared.tick()
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.surfaceRaised, in: Capsule())
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(.horizontal)

            Button {
                workout.startSession(named: sessionName)
                sessionName = ""
            } label: {
                Text("START SESSION")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            HStack(spacing: 12) {
                launcherSecondaryButton(
                    title: "Past Workout",
                    icon: "calendar.badge.plus"
                ) {
                    showPastWorkout = true
                }
                launcherSecondaryButton(
                    title: "Add a Walk",
                    icon: "figure.walk"
                ) {
                    showWalkDraw = true
                }
            }
            .padding(.horizontal)

            Spacer()
            Spacer()
        }
        .navigationTitle("Train")
        .sheet(isPresented: $showPastWorkout) {
            PastWorkoutView()
        }
        .sheet(isPresented: $showWalkDraw) {
            WalkDrawView()
        }
    }

    private func launcherSecondaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.tick()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.emerald)
                .glassControl()
        }
    }
}

// MARK: - Active session

private struct ActiveSessionView: View {
    @Environment(WorkoutManager.self) private var workout
    @State private var showExercisePicker = false
    @State private var showEndConfirmation = false
    @State private var elapsed: TimeInterval = 0

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                sessionHeader

                ForEach(workout.sessionExercises, id: \.id) { exercise in
                    ExerciseLogCard(exercise: exercise)
                }

                Button {
                    showExercisePicker = true
                } label: {
                    Label("Add Exercise", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.emerald)
                        .glassControl(cornerRadius: 16)
                }

                Button("End Session", role: .destructive) {
                    showEndConfirmation = true
                }
                .padding(.top, 6)
            }
            .padding()
            .padding(.bottom, workout.isResting ? 90 : 0)
        }
        .navigationTitle(workout.activeSession?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if workout.isResting {
                RestTimerOverlay()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: workout.isResting)
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerSheet { exercise in
                workout.addExercise(exercise)
            }
        }
        .confirmationDialog("End this session?", isPresented: $showEndConfirmation) {
            Button("End Session", role: .destructive) { workout.endSession() }
        } message: {
            Text("Your sets are saved. Ending closes the session log.")
        }
        .onReceive(clock) { _ in
            if let start = workout.activeSession?.startDate {
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private var sessionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                Text(elapsed.clockString)
                    .statNumberStyle()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("VOLUME")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                Text("\(Int(workout.activeSession?.totalVolume ?? 0).formatted()) lbs")
                    .statNumberStyle()
                    .foregroundStyle(Theme.emerald)
            }
        }
        .cardStyle()
    }
}

// MARK: - Exercise picker sheet

struct ExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var showCreator = false

    let onPick: (Exercise) -> Void

    private var filtered: [Exercise] {
        searchText.isEmpty
            ? exercises
            : exercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.id) { exercise in
                    Button {
                        onPick(exercise)
                        Haptics.shared.tick()
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name)
                                .foregroundStyle(.primary)
                            Text("\(exercise.muscleGroupRaw) · \(exercise.equipmentType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreator = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreator) {
                ExerciseEditorView { created in
                    onPick(created)
                    dismiss()
                }
            }
        }
    }
}

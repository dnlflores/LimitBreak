import SwiftUI
import SwiftData

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
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @State private var sessionName = ""
    @State private var isNaming = false
    @State private var showPastWorkout = false
    @State private var showWalkDraw = false
    @State private var showAIWorkout = false
    @State private var showRoutineLibrary = false

    private let suggestions = ["Push Day", "Pull Day", "Leg Day", "Upper Body", "Full Body"]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                aiWorkoutCard

                routinesSection

                orDivider

                manualStartCard

                secondaryActions
            }
            .padding()
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissibleKeyboard()
        .sheet(isPresented: $showPastWorkout) {
            PastWorkoutView()
        }
        .sheet(isPresented: $showWalkDraw) {
            WalkDrawView()
        }
        .sheet(isPresented: $showAIWorkout) {
            AIWorkoutSheet { title, exercises in
                workout.startSession(named: title, exercises: exercises)
            }
        }
        .sheet(isPresented: $showRoutineLibrary) {
            RoutineLibraryView()
        }
    }

    // MARK: Routines

    /// Saved curations, shown as quick-start cards. Tap to launch a session
    /// pre-loaded with the routine's exercises; "Manage" opens the full library.
    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROUTINES")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                Spacer()
                Button {
                    Haptics.shared.tick()
                    showRoutineLibrary = true
                } label: {
                    Label(routines.isEmpty ? "New" : "Manage", systemImage: routines.isEmpty ? "plus" : "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.emerald)
                }
            }

            if routines.isEmpty {
                Button {
                    Haptics.shared.tick()
                    showRoutineLibrary = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.emerald)
                        Text("Save a routine to quick-start it — build one or generate it with AI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(14)
                    .glassControl(cornerRadius: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(routines, id: \.id) { routine in
                            routineCard(routine)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func routineCard(_ routine: Routine) -> some View {
        Button {
            Haptics.shared.tick()
            workout.startSession(from: routine)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(routine.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if routine.isAIGenerated {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Theme.violet)
                    }
                }
                Text(routine.exercises.prefix(3).map(\.name).joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("\(routine.exerciseCount) exercise\(routine.exerciseCount == 1 ? "" : "s")")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.emerald)
            }
            .padding(14)
            .frame(width: 168, height: 132, alignment: .topLeading)
            .glassControl(cornerRadius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("Ready to break limits?")
                .font(.title2.weight(.bold))
        }
        .padding(.top, 8)
    }

    // MARK: AI workout hero

    private var aiWorkoutCard: some View {
        Button {
            Haptics.shared.tick()
            showAIWorkout = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.limitBreakGradient)
                    .frame(width: 52, height: 52)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Workout")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Pick a focus and length — I'll build the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.limitBreakGradient, lineWidth: 1))
            .shadow(color: Theme.violet.opacity(0.25), radius: 16, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Text("OR START YOUR OWN")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    // MARK: Manual start

    private var manualStartCard: some View {
        VStack(spacing: 14) {
            TextField("Session name (optional)", text: $sessionName)
                .textFieldStyle(.plain)
                .submitLabel(.go)
                .onSubmit { Task { await start() } }
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
                .padding(.horizontal, 2)
            }

            Button {
                Task { await start() }
            } label: {
                HStack(spacing: 8) {
                    if isNaming {
                        ProgressView().tint(.white)
                        Text("NAMING…")
                    } else {
                        Text("START SESSION")
                    }
                }
                .font(.headline)
                .kerning(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .glassCTA(tint: Theme.emerald.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isNaming)

            if sessionName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No name? I'll invent a fun one for you.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            launcherSecondaryButton(title: "Past Workout", icon: "calendar.badge.plus") {
                showPastWorkout = true
            }
            launcherSecondaryButton(title: "Add a Walk", icon: "figure.walk") {
                showWalkDraw = true
            }
        }
    }

    // MARK: Actions

    /// Starts a session, auto-generating a game-themed name when none was typed.
    private func start() async {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        guard !isNaming else { return }
        if trimmed.isEmpty {
            isNaming = true
            let name = await WorkoutAI.generateSessionName()
            isNaming = false
            workout.startSession(named: name)
        } else {
            workout.startSession(named: trimmed)
        }
        sessionName = ""
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
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Active session

private struct ActiveSessionView: View {
    @Environment(WorkoutManager.self) private var workout
    @State private var showExercisePicker = false
    @State private var showEndConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var isEndBarVisible = true

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
                        .contentShape(Rectangle())
                }
            }
            .padding()
            .padding(.bottom, contentBottomInset)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { oldValue, newValue in
            updateEndBarVisibility(from: oldValue, to: newValue)
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissibleKeyboard()
        .navigationTitle(workout.activeSession?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.shared.tick()
                    showCancelConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(Theme.textDim)
                .accessibilityLabel("Cancel session")
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if workout.isResting {
                    RestTimerOverlay()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                endSessionBar
                    .offset(y: isEndBarVisible ? 0 : 180)
                    .opacity(isEndBarVisible ? 1 : 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            .animation(.spring(duration: 0.35), value: isEndBarVisible)
        }
        .animation(.spring(duration: 0.35), value: workout.isResting)
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerSheet { exercise in
                workout.addExercise(exercise)
            }
        }
        .sheet(isPresented: $showEndConfirmation) {
            SessionConfirmSheet(
                icon: "flag.checkered",
                tint: Theme.crimson,
                title: "End this session?",
                message: "Your sets are saved. Ending closes the session log.",
                confirmLabel: "End Session"
            ) {
                workout.endSession()
            }
        }
        .sheet(isPresented: $showCancelConfirmation) {
            SessionConfirmSheet(
                icon: "trash",
                tint: Theme.crimson,
                title: "Discard this session?",
                message: "This deletes the session and any sets you've logged. Use this if you started it by accident. This can't be undone.",
                confirmLabel: "Discard Session"
            ) {
                workout.cancelSession()
            }
        }
    }

    // MARK: Sticky End Session bar

    private var endSessionBar: some View {
        Button {
            Haptics.shared.tick()
            showEndConfirmation = true
        } label: {
            Text("END SESSION")
                .font(.headline)
                .kerning(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .glassCTA(tint: Theme.crimson.opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Reserve room at the bottom of the scroll content so the last card is never
    /// trapped behind the floating End Session bar (and the rest timer when active).
    private var contentBottomInset: CGFloat {
        workout.isResting ? 168 : 84
    }

    /// Reveal-on-scroll-up: hide the End Session bar while scrolling down the log,
    /// bring it back the moment the user scrolls up or reaches the top.
    private func updateEndBarVisibility(from oldOffset: CGFloat, to newOffset: CGFloat) {
        if newOffset <= 40 {
            if !isEndBarVisible { isEndBarVisible = true }
            return
        }
        let delta = newOffset - oldOffset
        if delta > 8 {
            if isEndBarVisible { isEndBarVisible = false }
        } else if delta < -8 {
            if !isEndBarVisible { isEndBarVisible = true }
        }
    }

    private var sessionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1)
                ElapsedTimeLabel(startDate: workout.activeSession?.startDate)
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

// MARK: - Session confirmation sheet

/// A themed modal replacing the system action sheet for destructive session
/// actions (End / Discard). Presents as a compact glass card over the obsidian
/// canvas with a clear destructive CTA and a dismiss control.
private struct SessionConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss

    let icon: String
    let tint: Color
    let title: String
    let message: String
    let confirmLabel: String
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(tint.opacity(0.25)), in: Circle())

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
                    Haptics.shared.tick()
                    dismiss()
                    confirm()
                } label: {
                    Text(confirmLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .glassCTA(tint: tint.opacity(0.85))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("Keep Training")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .glassControl(cornerRadius: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .obsidianBackground()
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }
}

// MARK: - Elapsed time

/// Live-ticking session clock. Owns its own timeline so each per-second tick
/// only redraws this label — it never invalidates the parent session view,
/// which would otherwise re-evaluate presented sheets and flicker their content.
private struct ElapsedTimeLabel: View {
    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: startDate ?? .now, by: 1)) { context in
            let elapsed = startDate.map { context.date.timeIntervalSince($0) } ?? 0
            Text(elapsed.clockString)
                .statNumberStyle()
        }
    }
}

// MARK: - Exercise picker sheet

struct ExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var searchText = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var showCreator = false

    let onPick: (Exercise) -> Void

    private var filtered: [Exercise] {
        exercises.filter { exercise in
            let matchesSearch = searchText.isEmpty
                || exercise.name.localizedCaseInsensitiveContains(searchText)
            let matchesMuscle = muscleFilter == nil
                || exercise.muscleGroupRaw == muscleFilter?.rawValue
            return matchesSearch && matchesMuscle
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                searchField

                filterBar

                forgeNewCard

                ForEach(filtered, id: \.id) { exercise in
                    exerciseCard(exercise)
                }

                if filtered.isEmpty {
                    Text("No movements match \u{201C}\(searchText)\u{201D}. Forge it as a custom exercise instead.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                }
            }
            .padding()
        }
        .obsidianBackground()
        .presentationDragIndicator(.visible)
        .scrollDismissesKeyboard(.interactively)
        .dismissibleKeyboard()
        .sheet(isPresented: $showCreator) {
            ExerciseEditorView { created in
                onPick(created)
                dismiss()
            }
        }
    }

    // MARK: Header & search

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Exercise")
                    .font(.title.bold())
                Text("Pick your next movement.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
            TextField("Search movements", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil)
                ForEach(MuscleGroup.allCases) { muscle in
                    filterChip(muscle)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ muscle: MuscleGroup?) -> some View {
        let isSelected = muscleFilter == muscle
        return Button(muscle?.rawValue ?? "All") {
            muscleFilter = muscle
            Haptics.shared.tick()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.glassBorder), lineWidth: 1))
        .foregroundStyle(isSelected ? .black : .primary)
        .buttonStyle(.plain)
    }

    // MARK: Cards

    /// Entry into the Forge for movements the library doesn't know yet.
    private var forgeNewCard: some View {
        Button {
            Haptics.shared.tick()
            showCreator = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hammer.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.limitBreakGradient)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Forge New Exercise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Define a custom movement on the fly")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .cardStyle()
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.limitBreakGradient, lineWidth: 1)
                    .opacity(0.4)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private func exerciseCard(_ exercise: Exercise) -> some View {
        Button {
            onPick(exercise)
            Haptics.shared.logSet()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: exercise.muscleGroup.iconName)
                    .font(.title3)
                    .foregroundStyle(Theme.teal)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(exercise.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        if exercise.isCustom {
                            Text("CUSTOM")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.violet.opacity(0.25), in: Capsule())
                                .foregroundStyle(Theme.violet)
                        }
                    }
                    Text("\(exercise.muscleGroupRaw) · \(exercise.equipmentType)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                let ceiling = exercise.ceiling(for: "1RM")
                if ceiling > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ceiling.cleanWeight)
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.gold)
                        Text("1RM")
                            .font(.caption2)
                            .foregroundStyle(Theme.textDim)
                    }
                }

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.emerald)
            }
            .cardStyle()
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

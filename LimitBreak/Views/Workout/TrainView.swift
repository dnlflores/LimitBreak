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
    @State private var isNaming = false
    @State private var showWalkDraw = false
    @State private var showAIWorkout = false
    /// Answered before the session starts and carried into it — routines, AI
    /// plans and plain sessions all launch with whatever is selected here.
    @State private var withPartner = false
    // Debug/UI-test hook: launch with "-open-activity" to present the logger.
    @State private var showActivityLog = ProcessInfo.processInfo.arguments.contains("-open-activity")

    // Live totals feeding the Walk & Activity tiles so they read as glanceable
    // widgets rather than plain launch buttons.
    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]
    @Query(sort: \Activity.date, order: .reverse) private var activities: [Activity]
    private let health = HealthKitManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                aiWorkoutCard

                secondaryActions
            }
            .padding()
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await health.refreshTodayStats() }
        .safeAreaInset(edge: .bottom) {
            startCluster
        }
        .sheet(isPresented: $showWalkDraw) {
            WalkDrawView()
        }
        .sheet(isPresented: $showAIWorkout) {
            AIWorkoutSheet { title, exercises, setTargets, repTargets, weightTargets, supersets, partnered in
                workout.startSession(
                    named: title,
                    exercises: exercises,
                    targets: setTargets,
                    repTargets: repTargets,
                    weightTargets: weightTargets,
                    supersets: supersets,
                    withPartner: partnered
                )
            }
        }
        .sheet(isPresented: $showActivityLog) {
            ActivityLogView()
        }
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
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: Primary start (pinned at the bottom, in thumb range)

    /// The one big action, docked at the bottom. Every session gets an
    /// AI-invented name on the way in.
    private var startCluster: some View {
        VStack(spacing: 10) {
            // Asked right where the session begins, so it's answered before the
            // first set rather than reconstructed afterward.
            PartnerToggle(isOn: $withPartner)

            Button {
                Task { await start() }
            } label: {
                HStack(spacing: 10) {
                    if isNaming {
                        ProgressView().tint(.white)
                        Text("NAMING\u{2026}")
                    } else {
                        Image(systemName: "bolt.fill")
                        Text("START SESSION")
                    }
                }
                .font(.headline)
                .kerning(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .foregroundStyle(.white)
                .glassCTA(tint: Theme.emerald.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isNaming)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: AI workout

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
                    Text("Pick a focus and length \u{2014} I\u{2019}ll build the session.")
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

    // MARK: Movement tiles (Walk & Activity)

    /// The two cross-training entries, rendered as glanceable widgets: the Walk
    /// tile carries a live steps ring toward the daily goal, the Activity tile a
    /// weekly cross-training tally. Both double as the launcher for their sheet.
    private var secondaryActions: some View {
        HStack(spacing: 12) {
            walkTile
            activityTile
        }
    }

    private var walkTile: some View {
        let steps = health.todaySteps ?? StepGoalStore.todaySteps() ?? 0
        let progress = min(1, steps / Double(StepGoals.dailyGoal))
        return movementTile(
            title: "WALK",
            accent: Theme.teal,
            action: { showWalkDraw = true }
        ) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Theme.teal.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.teal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.teal)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 1) {
                    Text(steps > 0 ? steps.formatted(.number.notation(.compactName)) : "\u{2014}")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("steps")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
        } footer: {
            if todayWalkMiles > 0 {
                tileFooter(value: String(format: "%.2f mi", todayWalkMiles), caption: "logged today", accent: Theme.teal)
            } else {
                tileFooter(value: "Draw a route", caption: "Map a walk", accent: nil)
            }
        }
    }

    private var activityTile: some View {
        movementTile(
            title: "ACTIVITY",
            accent: Theme.coral,
            action: { showActivityLog = true }
        ) {
            HStack(spacing: 12) {
                Image(systemName: recentSport.icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.coral)
                    .frame(width: 52, height: 52)
                    .background(Theme.coral.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.coral.opacity(0.25), lineWidth: 1))

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(weekActivities.count)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("this week")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
        } footer: {
            if weekMinutes > 0 {
                tileFooter(value: "\(weekMinutes) min", caption: "cross-training", accent: Theme.coral)
            } else {
                tileFooter(value: "Log a sport", caption: "Basketball, tennis\u{2026}", accent: nil)
            }
        }
    }

    /// Shared chrome for the two movement tiles: a titled glass card with an
    /// accent-tinted border, a body (ring/icon + stat) and a footer line.
    private func movementTile<Body: View, Footer: View>(
        title: String,
        accent: Color,
        action: @escaping () -> Void,
        @ViewBuilder body: () -> Body,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        Button {
            Haptics.shared.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(.caption2.weight(.bold))
                        .kerning(1.5)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(accent)
                }

                body()

                footer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private func tileFooter(value: String, caption: String, accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent ?? .primary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tile data

    private var todayWalkMiles: Double {
        walks.filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.distanceMiles }
    }

    /// Activities logged since the start of the current week.
    private var weekActivities: [Activity] {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        ) else { return [] }
        return activities.filter { $0.date >= weekStart }
    }

    private var weekMinutes: Int {
        weekActivities.reduce(0) { $0 + $1.durationMinutes }
    }

    /// The sport shown on the Activity tile — the most recently logged, or a
    /// sensible default before anything is logged.
    private var recentSport: SportType {
        activities.first?.sport ?? .basketball
    }

    // MARK: Actions

    /// Starts a session, always letting the AI invent a game-themed name.
    private func start() async {
        guard !isNaming else { return }
        isNaming = true
        let name = await WorkoutAI.generateSessionName()
        isNaming = false
        workout.startSession(named: name, withPartner: withPartner)
    }
}

// MARK: - Active session

private struct ActiveSessionView: View {
    @Environment(WorkoutManager.self) private var workout
    @State private var showExercisePicker = false
    @State private var showEndConfirmation = false
    @State private var showCancelConfirmation = false
    /// Superset-building mode: cards become checkboxes and the toolbar swaps to a
    /// Cancel/Group pair. `supersetSelection` holds the picked exercise ids.
    @State private var isSelectingSuperset = false
    @State private var supersetSelection: Set<UUID> = []
    /// The movement whose logging sheet is open, if any.
    @State private var loggingExercise: Exercise?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                sessionHeader

                if isSelectingSuperset { supersetSelectionHint }

                ReorderableVStack(sessionExercisesBinding, spacing: 14) { $exercise, grip in
                    let alreadyGrouped = workout.supersetTag(for: exercise) != nil
                    ExerciseLogCard(
                        exercise: exercise,
                        grip: grip,
                        isSelecting: isSelectingSuperset,
                        isSelected: alreadyGrouped || supersetSelection.contains(exercise.id),
                        isLocked: alreadyGrouped,
                        onToggleSelect: { toggleSupersetSelection(exercise) },
                        onOpen: { loggingExercise = exercise }
                    )
                }

                if !isSelectingSuperset {
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
            }
            .padding()
            .padding(.bottom, contentBottomInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(workout.activeSession?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelectingSuperset {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { exitSupersetSelection() }
                        .tint(Theme.textDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Group") { confirmSuperset() }
                        .fontWeight(.semibold)
                        .tint(Theme.teal)
                        .disabled(supersetSelection.count < 2)
                }
            } else {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            beginSupersetSelection()
                        } label: {
                            Label("Build a Superset", systemImage: "link")
                        }
                        .disabled(workout.sessionExercises.count < 2)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(Theme.textDim)
                    .accessibilityLabel("Session options")
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if workout.isResting {
                    RestTimerOverlay()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                endSessionBar
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .animation(.spring(duration: 0.35), value: workout.isResting)
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerSheet { exercise in
                workout.addExercise(exercise)
            }
        }
        .sheet(item: $loggingExercise) { exercise in
            ExerciseLogSheet(exercise: exercise)
        }
        .sheet(isPresented: $showEndConfirmation) {
            SessionConfirmSheet(
                icon: "flag.checkered",
                tint: Theme.emerald,
                title: "End this session?",
                message: "Saves everything you logged to your history.",
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

    /// Routes reordering back through the manager so the watch and Live Activity
    /// see the new running order too.
    private var sessionExercisesBinding: Binding<[Exercise]> {
        Binding(
            get: { workout.sessionExercises },
            set: { workout.reorderExercises(to: $0) }
        )
    }

    // MARK: Superset building

    /// Banner shown atop the log while picking exercises for a new superset.
    private var supersetSelectionHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Theme.teal)
            Text(supersetSelection.count < 2
                 ? "Tap 2 or more exercises to run them as a superset."
                 : "\(supersetSelection.count) selected — tap Group to link them.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.teal.opacity(0.3), lineWidth: 1))
    }

    private func beginSupersetSelection() {
        Haptics.shared.tick()
        supersetSelection = []
        withAnimation(.snappy) { isSelectingSuperset = true }
    }

    private func exitSupersetSelection() {
        withAnimation(.snappy) { isSelectingSuperset = false }
        supersetSelection = []
    }

    private func toggleSupersetSelection(_ exercise: Exercise) {
        // Movements already in a superset are locked out of a new one.
        guard workout.supersetTag(for: exercise) == nil else { return }
        if supersetSelection.contains(exercise.id) {
            supersetSelection.remove(exercise.id)
        } else {
            supersetSelection.insert(exercise.id)
        }
    }

    private func confirmSuperset() {
        let members = workout.sessionExercises.filter { supersetSelection.contains($0.id) }
        guard members.count > 1 else { return }
        workout.groupAsSuperset(members)
        exitSupersetSelection()
    }

    /// Reserve room at the bottom of the scroll content so the last card is never
    /// trapped behind the pinned End Session bar (and the rest timer when active).
    private var contentBottomInset: CGFloat {
        workout.isResting ? 168 : 84
    }

    private var sessionHeader: some View {
        VStack(spacing: 10) {
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

            partnerRow
        }
        .cardStyle()
    }

    /// Mid-session correction for the partner question — someone showing up on
    /// set three shouldn't leave the session logged as solo.
    private var partnerRow: some View {
        Button {
            workout.setTrainingWithPartner(!workout.isTrainingWithPartner)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workout.isTrainingWithPartner ? "person.2.fill" : "person.fill")
                    .font(.caption)
                Text(workout.isTrainingWithPartner ? "Training with a partner" : "Training solo")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("CHANGE")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
            }
            .foregroundStyle(workout.isTrainingWithPartner ? Theme.teal : Theme.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                workout.isTrainingWithPartner
                    ? AnyShapeStyle(Theme.teal.opacity(0.12))
                    : AnyShapeStyle(Color.white.opacity(0.03)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workout.isTrainingWithPartner ? "Training with a partner. Tap to switch to solo." : "Training solo. Tap to switch to with a partner.")
    }
}

// MARK: - Session confirmation sheet

/// A themed modal replacing the system action sheet for destructive session
/// actions (End / Discard). Presents as a compact glass card over the obsidian
/// canvas with a clear destructive CTA and a dismiss control.
/// Measures the confirmation sheet's natural content height so its detent can
/// hug it, avoiding dead space below the buttons.
private struct ConfirmSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 380
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SessionConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss

    let icon: String
    let tint: Color
    let title: String
    let message: String
    let confirmLabel: String
    var cancelLabel: String = "Keep Training"
    let confirm: () -> Void

    @State private var sheetHeight: CGFloat = 380

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
                    Text(cancelLabel)
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
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ConfirmSheetHeightKey.self, value: proxy.size.height)
            }
        )
        .obsidianBackground()
        .onPreferenceChange(ConfirmSheetHeightKey.self) { sheetHeight = $0 }
        .presentationDetents([.height(sheetHeight)])
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
        return Button(muscle?.displayName ?? "All") {
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
                    Text("\(exercise.muscleGroupDisplay) · \(exercise.equipmentType)")
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

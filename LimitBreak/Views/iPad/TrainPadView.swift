import SwiftUI
import SwiftData

/// The Train tab on iPad: a launch console when idle, a two-pane training rig
/// when a session is live.
///
/// The phone has to hide the session's vitals behind a scroll and dock the end
/// button over the content. Here the log sits in the main pane while elapsed
/// time, volume, the rest timer and the session controls live in a rail that is
/// always visible — you can see the whole session while you log it.
struct TrainPadView: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        NavigationStack {
            Group {
                if workout.activeSession != nil {
                    ActiveSessionPadView()
                } else {
                    SessionLauncherPadView()
                }
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Launcher

private struct SessionLauncherPadView: View {
    @Environment(WorkoutManager.self) private var workout

    @Query(sort: \Walk.date, order: .reverse) private var walks: [Walk]
    @Query(sort: \Activity.date, order: .reverse) private var activities: [Activity]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(filter: #Predicate<Routine> { !$0.isPlanDay },
           sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @Query(sort: \WeeklyPlan.createdAt, order: .reverse) private var plans: [WeeklyPlan]

    @State private var isNaming = false
    @State private var withPartner = false
    @State private var showWalkDraw = false
    @State private var showAIWorkout = false
    @State private var showActivityLog = ProcessInfo.processInfo.arguments.contains("-open-activity")

    private let health = HealthKitManager.shared

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= PadLayout.twoColumnMinWidth
            VStack(spacing: PadLayout.gutter) {
                PadScreenHeader(title: "Train", subtitle: "Pick your entry point — then break some limits.") {
                    EmptyView()
                }

                if wide {
                    HStack(alignment: .top, spacing: PadLayout.gutter) {
                        // Both columns are top-aligned so the hero lines up with
                        // Today's plan across the gutter, and the quick-start grid
                        // grows downward to fill the height instead of leaving the
                        // pane centered in a sea of empty space.
                        ScrollView(showsIndicators: false) {
                            mainColumn.padding(.bottom, PadLayout.scrollBottomInset)
                        }

                        ScrollView(showsIndicators: false) {
                            railColumn.padding(.bottom, PadLayout.scrollBottomInset)
                        }
                        .frame(width: PadLayout.railWidth)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: PadLayout.gutter) {
                            mainColumn
                            railColumn
                        }
                        .padding(.bottom, PadLayout.scrollBottomInset)
                    }
                }
            }
            .padding(.horizontal, PadLayout.screenPadding)
            .padding(.top, 4)
        }
        .task { await health.refreshTodayStats() }
        .sheet(isPresented: $showWalkDraw) { WalkDrawView() }
        .sheet(isPresented: $showActivityLog) { ActivityLogView() }
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
    }

    // MARK: Main pane

    private var mainColumn: some View {
        VStack(spacing: PadLayout.gutter) {
            heroCard
            HStack(alignment: .top, spacing: PadLayout.gutter) {
                walkTile
                activityTile
            }
            quickStartPanel
        }
    }

    /// The one big entry point: name the session, choose company, start lifting.
    /// The AI drafter sits inside the same card because it's the other half of
    /// the same decision.
    private var heroCard: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(Theme.limitBreakGradient)
                Text("Ready to break limits?")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Start an empty session and log as you go, or let the coach draft one for you.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(.top, 12)

            PartnerToggle(isOn: $withPartner)
                .frame(maxWidth: 460)

            HStack(spacing: 14) {
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
                    .kerning(1.4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isNaming)

                Button {
                    Haptics.shared.tick()
                    showAIWorkout = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text("AI WORKOUT")
                    }
                    .font(.headline)
                    .kerning(1.4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.violet.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 620)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Theme.limitBreakGradient, lineWidth: 1))
        .shadow(color: Theme.violet.opacity(0.25), radius: 22, y: 10)
    }

    private var walkTile: some View {
        let steps = health.todaySteps ?? StepGoalStore.todaySteps() ?? 0
        let progress = min(1, steps / Double(StepGoals.dailyGoal))
        return movementTile(title: "WALK", accent: Theme.teal, action: { showWalkDraw = true }) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.teal.opacity(0.15), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.teal, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.teal)
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 2) {
                    Text(steps > 0 ? steps.formatted(.number.notation(.compactName)) : "\u{2014}")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("steps today")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    Text(todayWalkMiles > 0
                         ? String(format: "%.2f mi logged", todayWalkMiles)
                         : "Draw a route to log one")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(todayWalkMiles > 0 ? Theme.teal : Theme.textDim)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var activityTile: some View {
        movementTile(title: "ACTIVITY", accent: Theme.coral, action: { showActivityLog = true }) {
            HStack(spacing: 16) {
                Image(systemName: recentSport.icon)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.coral)
                    .frame(width: 72, height: 72)
                    .background(Theme.coral.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.coral.opacity(0.25), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(weekActivities.count)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("sports this week")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    Text(weekMinutes > 0 ? "\(weekMinutes) min cross-training" : "Basketball, tennis\u{2026}")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(weekMinutes > 0 ? Theme.coral : Theme.textDim)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func movementTile<Body: View>(
        title: String,
        accent: Color,
        action: @escaping () -> Void,
        @ViewBuilder body: () -> Body
    ) -> some View {
        Button {
            Haptics.shared.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .kerning(1.6)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(accent)
                }
                body()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(accent.opacity(0.28), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    // MARK: Rail

    /// The rail carries the session context the main column doesn't: today's
    /// scheduled focus (or a nudge to plan one) and the last few sessions.
    private var railColumn: some View {
        VStack(spacing: PadLayout.gutter) {
            if hasTodayPlan {
                todayPanel
            } else {
                planNudgePanel
            }
            recentPanel
        }
    }

    /// True when the active plan has a routine scheduled for today.
    private var hasTodayPlan: Bool {
        let today = PlanWeekday.today
        guard let plan = plans.first,
              let day = plan.days.first(where: { $0.weekday == today }) else { return false }
        return day.routine != nil
    }

    /// Shown in the rail when nothing is scheduled, so it never reads as a blank
    /// slab for someone who hasn't built a weekly plan yet.
    private var planNudgePanel: some View {
        PadPanel("TODAY") {
            VStack(alignment: .leading, spacing: 8) {
                Text("No session scheduled")
                    .font(.title3.weight(.bold))
                Text("Build a weekly plan and your day's focus shows up here, ready to start with one tap.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder
    private var todayPanel: some View {
        let today = PlanWeekday.today
        if let plan = plans.first,
           let day = plan.days.first(where: { $0.weekday == today }),
           let routine = day.routine {
            PadPanel("TODAY \u{2014} \(PlanWeekday.name(today).uppercased())") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(day.focus.label)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.limitBreakGradient)
                    Text(routine.exercises.map(\.name).prefix(4).joined(separator: " \u{00B7} "))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)

                    Button {
                        Haptics.shared.tick()
                        workout.startSession(from: routine, withPartner: plan.withPartner)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("START TODAY'S SESSION")
                                .font(.subheadline.weight(.bold))
                                .kerning(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .glassCTA(tint: Theme.emerald.opacity(0.85))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Saved routines as a two-column grid of start cards. In the main pane it
    /// grows downward to carry the height, and an empty state keeps the panel
    /// present (and inviting) before any routine is saved.
    private var quickStartPanel: some View {
        PadPanel("QUICK START") {
            if routines.isEmpty {
                quickStartEmptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(routines.prefix(8), id: \.id) { routine in
                        routineCard(routine)
                    }
                }
            }
        }
    }

    private func routineCard(_ routine: Routine) -> some View {
        Button {
            Haptics.shared.tick()
            workout.startSession(from: routine, withPartner: withPartner)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: routine.isAIGenerated ? "sparkles" : "square.stack.3d.up.fill")
                        .font(.subheadline)
                        .foregroundStyle(routine.isAIGenerated ? Theme.violet : Theme.teal)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    Spacer(minLength: 4)
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.emerald)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassControl(cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var quickStartEmptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.title)
                .foregroundStyle(Theme.teal)
            Text("Save a routine in the Library and it lands here — one tap to start it.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var recentPanel: some View {
        if !sessions.isEmpty {
            PadPanel("LAST SESSIONS") {
                VStack(spacing: 10) {
                    ForEach(sessions.prefix(4)) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer(minLength: 6)
                            Text("\(Int(session.totalVolume).formatted()) lbs")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.emerald)
                        }
                    }
                }
            }
        }
    }

    // MARK: Data

    private var todayWalkMiles: Double {
        walks.filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.distanceMiles }
    }

    private var weekActivities: [Activity] {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        ) else { return [] }
        return activities.filter { $0.date >= weekStart }
    }

    private var weekMinutes: Int { weekActivities.reduce(0) { $0 + $1.durationMinutes } }

    private var recentSport: SportType { activities.first?.sport ?? .basketball }

    private func start() async {
        guard !isNaming else { return }
        isNaming = true
        let name = await WorkoutAI.generateSessionName()
        isNaming = false
        workout.startSession(named: name, withPartner: withPartner)
    }
}

// MARK: - Active session

private struct ActiveSessionPadView: View {
    @Environment(WorkoutManager.self) private var workout

    @State private var showExercisePicker = false
    @State private var showEndConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var isSelectingSuperset = false
    @State private var supersetSelection: Set<UUID> = []
    @State private var loggingExercise: Exercise?

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= PadLayout.twoColumnMinWidth
            HStack(alignment: .top, spacing: PadLayout.gutter) {
                ScrollView(showsIndicators: false) {
                    logStack.padding(.bottom, PadLayout.scrollBottomInset)
                }

                if wide {
                    ScrollView(showsIndicators: false) {
                        railStack.padding(.bottom, PadLayout.scrollBottomInset)
                    }
                    .frame(width: PadLayout.railWidth)
                }
            }
            .padding(.horizontal, PadLayout.screenPadding)
            .padding(.top, 4)
            // Narrow windows lose the rail, so the controls dock at the bottom
            // exactly as they do on the phone.
            .overlay(alignment: .bottom) {
                if !wide {
                    VStack(spacing: 10) {
                        if workout.isResting { RestTimerOverlay() }
                        endSessionButton
                    }
                    .padding(.horizontal, PadLayout.screenPadding)
                    .padding(.bottom, 12)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: workout.isResting)
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerSheet { exercise in workout.addExercise(exercise) }
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

    // MARK: Log pane

    private var logStack: some View {
        VStack(spacing: 16) {
            PadScreenHeader(
                title: workout.activeSession?.name ?? "Session",
                subtitle: isSelectingSuperset
                    ? (supersetSelection.count < 2
                       ? "Tap 2 or more movements to run them as a superset."
                       : "\(supersetSelection.count) selected \u{2014} tap Group to link them.")
                    : "\(workout.sessionExercises.count) movement\(workout.sessionExercises.count == 1 ? "" : "s") in play"
            ) {
                if isSelectingSuperset {
                    HStack(spacing: 10) {
                        Button("Cancel") { exitSupersetSelection() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glassControl()
                        Button("Group") { confirmSuperset() }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .foregroundStyle(supersetSelection.count < 2 ? Theme.textDim : .white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glassCTA(tint: Theme.teal.opacity(0.75))
                            .disabled(supersetSelection.count < 2)
                    }
                } else {
                    EmptyView()
                }
            }

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
                        .padding(.vertical, 16)
                        .foregroundStyle(Theme.emerald)
                        .glassControl(cornerRadius: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Rail

    private var railStack: some View {
        VStack(spacing: PadLayout.gutter) {
            vitalsPanel

            if workout.isResting {
                RestTimerOverlay()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            controlsPanel

            if !prSets.isEmpty { limitBreakPanel }
        }
    }

    /// Elapsed time, volume and set counts, always on screen while you lift.
    private var vitalsPanel: some View {
        PadPanel("SESSION VITALS") {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    vital(label: "Elapsed", tint: Theme.teal) {
                        PadElapsedLabel(startDate: workout.activeSession?.startDate)
                    }
                    vital(label: "Volume", tint: Theme.emerald) {
                        Text("\(Int(workout.activeSession?.totalVolume ?? 0).formatted())")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 12) {
                    vital(label: "Sets", tint: Theme.violet) {
                        Text("\(workingSetCount)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .monospacedDigit()
                    }
                    vital(label: "LimitBreaks", tint: Theme.gold) {
                        Text("\(prSets.count)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .monospacedDigit()
                    }
                }

                partnerRow
            }
        }
    }

    private func vital<Content: View>(
        label: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .kerning(1.1)
                .foregroundStyle(Theme.textDim)
            content()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.2), lineWidth: 1))
    }

    private var partnerRow: some View {
        Button {
            workout.setTrainingWithPartner(!workout.isTrainingWithPartner)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workout.isTrainingWithPartner ? "person.2.fill" : "person.fill")
                    .font(.subheadline)
                Text(workout.isTrainingWithPartner ? "Training with a partner" : "Training solo")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("CHANGE")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
            }
            .foregroundStyle(workout.isTrainingWithPartner ? Theme.teal : Theme.textDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                workout.isTrainingWithPartner
                    ? AnyShapeStyle(Theme.teal.opacity(0.12))
                    : AnyShapeStyle(Color.white.opacity(0.03)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workout.isTrainingWithPartner
                            ? "Training with a partner. Tap to switch to solo."
                            : "Training solo. Tap to switch to with a partner.")
    }

    private var controlsPanel: some View {
        PadPanel("SESSION") {
            VStack(spacing: 10) {
                Button {
                    beginSupersetSelection()
                } label: {
                    Label("Build a Superset", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(workout.sessionExercises.count < 2 ? Theme.textDim : Theme.teal)
                        .glassControl(cornerRadius: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workout.sessionExercises.count < 2 || isSelectingSuperset)

                endSessionButton

                Button {
                    Haptics.shared.tick()
                    showCancelConfirmation = true
                } label: {
                    Text("Discard Session")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Theme.crimson)
                        .glassControl(cornerRadius: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var endSessionButton: some View {
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

    /// Records set during *this* session, called out while they're still fresh.
    @ViewBuilder
    private var limitBreakPanel: some View {
        PadPanel("LIMITBREAKS THIS SESSION") {
            VStack(spacing: 10) {
                ForEach(prSets, id: \.id) { set in
                    HStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.gold)
                            .frame(width: 30, height: 30)
                            .background(Theme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(set.exercise?.name ?? "Movement")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(set.weight.cleanWeight) \u{00D7} \(set.reps)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Derived

    private var workingSetCount: Int {
        (workout.activeSession?.sets ?? []).filter { !$0.isWarmup }.count
    }

    private var prSets: [ExerciseSet] {
        (workout.activeSession?.sets ?? [])
            .filter(\.isPR)
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var sessionExercisesBinding: Binding<[Exercise]> {
        Binding(
            get: { workout.sessionExercises },
            set: { workout.reorderExercises(to: $0) }
        )
    }

    // MARK: Superset building

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
}

/// Live session clock, isolated so its per-second tick doesn't redraw the rail.
private struct PadElapsedLabel: View {
    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: startDate ?? .now, by: 1)) { context in
            let elapsed = startDate.map { context.date.timeIntervalSince($0) } ?? 0
            Text(elapsed.clockString)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .monospacedDigit()
        }
    }
}

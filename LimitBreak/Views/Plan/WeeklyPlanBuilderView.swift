import SwiftUI
import SwiftData

// MARK: - Shared generation

/// Generates one day's workout and maps it to routine draft items, reusing the
/// same AI pipeline the Train tab's generator uses. Shared by the builder wizard
/// and the per-day "Regenerate" action.
enum PlanBuilding {
    @MainActor
    static func generateDay(
        focus: WorkoutFocus,
        exercisesPerDay: Int,
        duration: WorkoutLength,
        withPartner: Bool,
        allowSupersets: Bool,
        exercises: [Exercise],
        sessions: [WorkoutSession],
        profile: TrainingProfile?
    ) async -> (title: String, items: [WorkoutManager.RoutineDraftItem])? {
        let catalog = exercises.map {
            ExerciseBrief(name: $0.name, muscleGroups: $0.allMuscleGroups.map(\.rawValue), equipment: $0.equipmentType)
        }
        // Only assemble the training context when the lifter has opted into
        // cloud AI — without it `generatePlan` stays fully on-device.
        var context: TrainingContext?
        if let profile, profile.cloudAIEnabled {
            context = TrainingContext.build(
                profile: profile,
                sessions: sessions,
                exercises: exercises,
                withPartner: withPartner
            )
        }

        let plan = await WorkoutAI.generatePlan(
            focusLabel: focus.label,
            targetMuscleGroups: focus.targetMuscleGroups,
            exerciseCount: exercisesPerDay,
            durationMinutes: duration.minutes,
            withPartner: withPartner,
            allowSupersets: allowSupersets,
            context: context,
            catalog: catalog
        )

        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }) { first, _ in first }
        let items = plan.exercises.compactMap { planned -> WorkoutManager.RoutineDraftItem? in
            guard let exercise = byName[planned.name.lowercased()] else { return nil }
            let weight: Double? = {
                guard let load = planned.prescription?.targetLoadPounds, load > 0 else { return nil }
                return load
            }()
            return (exercise, max(1, planned.sets), planned.targetReps, weight, planned.supersetGroup)
        }
        guard !items.isEmpty else { return nil }
        return (plan.title, items)
    }
}

// MARK: - Builder wizard

/// Two-step wizard: pick training days (and generation defaults), then a focus
/// per day. On finish it generates a workout for each day and replaces the
/// active plan.
struct WeeklyPlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var profiles: [TrainingProfile]

    let existing: WeeklyPlan?

    @State private var step = 1
    @State private var selectedWeekdays: Set<Int> = []
    @State private var focuses: [Int: WorkoutFocus] = [:]
    @State private var exercisesPerDay = 5
    @State private var duration: WorkoutLength = .any
    @State private var withPartner = false
    @State private var allowSupersets = true

    @State private var isGenerating = false
    @State private var progressText = ""
    @State private var generatedCount = 0
    @State private var totalCount = 0

    init(existing: WeeklyPlan?) {
        self.existing = existing
        if let existing {
            _selectedWeekdays = State(initialValue: Set(existing.days.map(\.weekday)))
            _focuses = State(initialValue: Dictionary(existing.days.map { ($0.weekday, $0.focus) }) { first, _ in first })
            _exercisesPerDay = State(initialValue: existing.exercisesPerDay)
            _duration = State(initialValue: existing.duration)
            _withPartner = State(initialValue: existing.withPartner)
            _allowSupersets = State(initialValue: existing.allowSupersets)
        }
    }

    private var orderedSelection: [Int] {
        selectedWeekdays.sorted { orderIndex($0) < orderIndex($1) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if step == 1 {
                    dayStep
                } else {
                    focusStep
                }
            }
            .obsidianBackground()
            .navigationTitle(step == 1 ? "Choose Your Days" : "Set Each Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .overlay { if isGenerating { generatingOverlay } }
        }
        .interactiveDismissDisabled(isGenerating)
    }

    // MARK: Step 1 — days & defaults

    private var dayStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("WHICH DAYS DO YOU TRAIN?") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                    ForEach(PlanWeekday.mondayFirst, id: \.self) { weekday in
                        dayChip(weekday)
                    }
                }
                Text("Unselected days are rest days.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }

            section("HOW MANY EXERCISES PER DAY?") {
                HStack {
                    Text("\(exercisesPerDay) exercise\(exercisesPerDay == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.emerald)
                    Spacer()
                    Stepper("", value: $exercisesPerDay, in: 3...8)
                        .labelsHidden()
                        .tint(Theme.emerald)
                }
            }

            section("HOW LONG?") {
                Picker("Duration", selection: $duration) {
                    ForEach(WorkoutLength.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            section("OPTIONS") {
                Toggle("Training with a partner", isOn: $withPartner)
                    .tint(Theme.emerald)
                Toggle("Allow supersets", isOn: $allowSupersets)
                    .tint(Theme.teal)
            }
        }
        .padding()
    }

    private func dayChip(_ weekday: Int) -> some View {
        let selected = selectedWeekdays.contains(weekday)
        return Button {
            Haptics.shared.tick()
            if selected {
                selectedWeekdays.remove(weekday)
                focuses[weekday] = nil
            } else {
                selectedWeekdays.insert(weekday)
                if focuses[weekday] == nil { focuses[weekday] = .fullBody }
            }
        } label: {
            Text(PlanWeekday.name(weekday, short: true).uppercased())
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(selected ? .black : .white)
                .background(
                    selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 — focus per day

    private var focusStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick what each day trains. The coach builds the workout to match.")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal)
                .padding(.top, 8)

            VStack(spacing: 10) {
                ForEach(orderedSelection, id: \.self) { weekday in
                    focusRow(weekday)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom)
    }

    private func focusRow(_ weekday: Int) -> some View {
        let focus = focuses[weekday] ?? .fullBody
        return HStack(spacing: 14) {
            Text(PlanWeekday.name(weekday, short: true).uppercased())
                .font(.caption2.weight(.bold))
                .frame(width: 44, height: 44)
                .foregroundStyle(.black)
                .background(Theme.emerald, in: Circle())

            Text(PlanWeekday.name(weekday))
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 4)

            Menu {
                ForEach(WorkoutFocus.allCases) { preset in
                    Button {
                        focuses[weekday] = preset
                        Haptics.shared.tick()
                    } label: {
                        Label(preset.label, systemImage: preset.icon)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: focus.icon)
                    Text(focus.label)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Theme.emerald)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassControl(cornerRadius: 12)
            }
        }
        .padding(12)
        .glassControl(cornerRadius: 16)
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step == 2 {
                Button {
                    Haptics.shared.tick()
                    withAnimation { step = 1 }
                } label: {
                    Text("BACK")
                        .font(.headline)
                        .kerning(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Theme.textDim)
                        .glassControl()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                Haptics.shared.tick()
                if step == 1 {
                    withAnimation { step = 2 }
                } else {
                    Task { await build() }
                }
            } label: {
                Text(step == 1 ? "NEXT" : "BUILD MY WEEK")
                    .font(.headline)
                    .kerning(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedWeekdays.isEmpty)
            .opacity(selectedWeekdays.isEmpty ? 0.5 : 1)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var generatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(Theme.emerald)
                Text(progressText)
                    .font(.subheadline.weight(.semibold))
                if totalCount > 0 {
                    Text("\(min(generatedCount + 1, totalCount)) of \(totalCount)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: Build

    private func build() async {
        isGenerating = true
        let weekdays = orderedSelection
        totalCount = weekdays.count
        var days: [(weekday: Int, focus: WorkoutFocus, title: String, items: [WorkoutManager.RoutineDraftItem])] = []
        for (index, weekday) in weekdays.enumerated() {
            generatedCount = index
            let focus = focuses[weekday] ?? .fullBody
            progressText = "Building \(PlanWeekday.name(weekday))…"
            if let generated = await PlanBuilding.generateDay(
                focus: focus,
                exercisesPerDay: exercisesPerDay,
                duration: duration,
                withPartner: withPartner,
                allowSupersets: allowSupersets,
                exercises: exercises,
                sessions: sessions,
                profile: profiles.first
            ) {
                days.append((weekday, focus, generated.title, generated.items))
            }
        }
        guard !days.isEmpty else {
            isGenerating = false
            return
        }
        workout.buildWeeklyPlan(
            name: existing?.name ?? "My Week",
            exercisesPerDay: exercisesPerDay,
            duration: duration,
            withPartner: withPartner,
            allowSupersets: allowSupersets,
            days: days
        )
        isGenerating = false
        dismiss()
    }

    // MARK: Helpers

    private func orderIndex(_ weekday: Int) -> Int {
        PlanWeekday.mondayFirst.firstIndex(of: weekday) ?? weekday
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
            content()
        }
    }
}

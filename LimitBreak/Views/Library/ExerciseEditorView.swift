import SwiftUI
import SwiftData

/// Custom exercise creation — every parameter from the spec is configurable,
/// styled as floating glass cards on the obsidian canvas.
struct ExerciseEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// When set, the editor updates this movement in place instead of forging a new one.
    var exercise: Exercise? = nil
    var onCreate: ((Exercise) -> Void)? = nil

    @State private var name = ""
    @State private var primaryMuscle: MuscleGroup = .chest
    @State private var secondaryMuscles: Set<MuscleGroup> = []
    @State private var trackingType: TrackingType = .weightAndReps
    @State private var equipment: EquipmentType = .barbell
    @State private var increment = 5.0
    @State private var restSeconds = 90
    @State private var formula: OneRMFormula = .epley
    @State private var customUnit = ""
    @State private var isAssisted = false

    private let incrementOptions = [1.0, 2.5, 5.0, 10.0, 25.0]
    private let restOptions = [0, 30, 45, 60, 90, 120, 180, 240, 300]

    init(exercise: Exercise? = nil, onCreate: ((Exercise) -> Void)? = nil) {
        self.exercise = exercise
        self.onCreate = onCreate
        guard let exercise else { return }
        _name = State(initialValue: exercise.name)
        _primaryMuscle = State(initialValue: exercise.muscleGroup)
        _secondaryMuscles = State(initialValue: Set(exercise.secondaryMuscles.compactMap(MuscleGroup.init)))
        _trackingType = State(initialValue: exercise.trackingType)
        _equipment = State(initialValue: EquipmentType(rawValue: exercise.equipmentType) ?? .barbell)
        _increment = State(initialValue: exercise.defaultIncrement)
        _restSeconds = State(initialValue: exercise.defaultRestSeconds)
        _formula = State(initialValue: exercise.formula)
        _customUnit = State(initialValue: exercise.customMetricUnit ?? "")
        _isAssisted = State(initialValue: exercise.isAssisted)
    }

    private var isEditing: Bool { exercise != nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                previewCard

                sectionLabel("IDENTITY")
                identityCard

                sectionLabel("TARGET MUSCLES")
                musclesCard

                sectionLabel("TRACKING")
                trackingCard

                sectionLabel("FINE-TUNING")
                tuningCard

                forgeButton
                    .padding(.top, 8)
            }
            .padding()
        }
        .obsidianBackground()
        .presentationDragIndicator(.visible)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Exercise" : "Forge Exercise")
                    .font(.title.bold())
                Text(isEditing ? "Refine this movement in your arsenal." : "Define a new movement for your arsenal.")
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .kerning(1.5)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 6)
    }

    // MARK: - Live preview

    /// Mirrors the Library card so the user sees exactly what they're forging.
    private var previewCard: some View {
        HStack(spacing: 12) {
            Image(systemName: trackingType.iconName)
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(trimmedName.isEmpty ? "Unnamed Movement" : trimmedName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(trimmedName.isEmpty ? Theme.textDim : .primary)
                    Text("CUSTOM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.violet.opacity(0.25), in: Capsule())
                        .foregroundStyle(Theme.violet)
                }
                Text("\(primaryMuscle.rawValue) · \(equipment.rawValue)")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()
        }
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.limitBreakGradient, lineWidth: 1)
                .opacity(trimmedName.isEmpty ? 0 : 0.5)
        )
        .animation(.easeInOut(duration: 0.25), value: trimmedName.isEmpty)
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            glassField("Exercise name", text: $name)

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Equipment")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EquipmentType.allCases) { type in
                            chip(
                                type.rawValue,
                                isSelected: equipment == type,
                                tint: Theme.teal
                            ) {
                                equipment = type
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Muscles

    private var musclesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Primary")
                muscleGrid(
                    MuscleGroup.allCases,
                    isSelected: { primaryMuscle == $0 },
                    tint: Theme.emerald
                ) { muscle in
                    primaryMuscle = muscle
                    secondaryMuscles.remove(muscle)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Secondary — tap all that assist")
                muscleGrid(
                    MuscleGroup.allCases.filter { $0 != primaryMuscle },
                    isSelected: { secondaryMuscles.contains($0) },
                    tint: Theme.violet
                ) { muscle in
                    if secondaryMuscles.contains(muscle) {
                        secondaryMuscles.remove(muscle)
                    } else {
                        secondaryMuscles.insert(muscle)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func muscleGrid(
        _ muscles: [MuscleGroup],
        isSelected: @escaping (MuscleGroup) -> Bool,
        tint: Color,
        onTap: @escaping (MuscleGroup) -> Void
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            ForEach(muscles) { muscle in
                chip(
                    muscle.rawValue,
                    isSelected: isSelected(muscle),
                    tint: tint,
                    fillWidth: true
                ) {
                    onTap(muscle)
                }
            }
        }
    }

    // MARK: - Tracking

    private var trackingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TrackingType.allCases) { type in
                trackingRow(type)
            }

            if trackingType == .customMetric {
                glassField("Metric unit (e.g. RPE, tension level)", text: $customUnit)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle()
        .animation(.snappy(duration: 0.25), value: trackingType)
    }

    private func trackingRow(_ type: TrackingType) -> some View {
        let isSelected = trackingType == type
        return Button {
            trackingType = type
            Haptics.shared.tick()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: type.iconName)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Theme.emerald : Theme.textDim)
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected ? Theme.emerald.opacity(0.15) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(type.blurb)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                    .foregroundStyle(isSelected ? Theme.emerald : Theme.textDim.opacity(0.5))
            }
            .padding(10)
            .background(
                isSelected ? Theme.emerald.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Theme.emerald.opacity(0.4) : Theme.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fine-tuning

    private var tuningCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Weight increment")
                HStack(spacing: 8) {
                    ForEach(incrementOptions, id: \.self) { option in
                        chip(
                            "\(option.cleanWeight)",
                            isSelected: increment == option,
                            tint: Theme.teal,
                            fillWidth: true
                        ) {
                            increment = option
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Rest timer")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(restOptions, id: \.self) { seconds in
                            chip(
                                seconds == 0 ? "None" : "\(seconds)s",
                                isSelected: restSeconds == seconds,
                                tint: Theme.coral
                            ) {
                                restSeconds = seconds
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("1RM formula")
                HStack(spacing: 8) {
                    ForEach(OneRMFormula.allCases) { option in
                        chip(
                            option.rawValue,
                            isSelected: formula == option,
                            tint: Theme.gold,
                            fillWidth: true
                        ) {
                            formula = option
                        }
                    }
                }
                Text(formula.blurb)
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
                    .animation(nil, value: formula)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Assistance")
                Button {
                    isAssisted.toggle()
                    Haptics.shared.tick()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.subheadline)
                            .foregroundStyle(isAssisted ? Theme.violet : Theme.textDim)
                            .frame(width: 34, height: 34)
                            .background(
                                isAssisted ? Theme.violet.opacity(0.15) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Assisted movement")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Accepts negative weight — more assistance = easier (assisted pull-ups, dips).")
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                        }

                        Spacer()

                        Image(systemName: isAssisted ? "checkmark.circle.fill" : "circle")
                            .font(.headline)
                            .foregroundStyle(isAssisted ? Theme.violet : Theme.textDim.opacity(0.5))
                    }
                    .padding(10)
                    .background(
                        isAssisted ? Theme.violet.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isAssisted ? Theme.violet.opacity(0.4) : Theme.stroke, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    // MARK: - Shared controls

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textDim)
    }

    private func glassField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    private func chip(
        _ label: String,
        isSelected: Bool,
        tint: Color,
        fillWidth: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        Button {
            onTap()
            Haptics.shared.tick()
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .background(
                    isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.surfaceRaised),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.glassBorder),
                        lineWidth: 1
                    )
                )
                .foregroundStyle(isSelected ? .black : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Forge

    private var forgeButton: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isEditing ? "checkmark" : "hammer.fill")
                Text(isEditing ? "SAVE CHANGES" : "FORGE EXERCISE")
                    .kerning(1.5)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .glassCTA(tint: trimmedName.isEmpty ? Theme.cobalt.opacity(0.5) : Theme.emerald.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(trimmedName.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: trimmedName.isEmpty)
    }

    private func save() {
        let unit = trackingType == .customMetric && !customUnit.isEmpty ? customUnit : nil
        let target: Exercise
        if let exercise {
            // Update the existing movement in place, preserving its records and history.
            exercise.name = trimmedName
            exercise.muscleGroupRaw = primaryMuscle.rawValue
            exercise.secondaryMuscles = secondaryMuscles.map(\.rawValue)
            exercise.trackingTypeRaw = trackingType.rawValue
            exercise.equipmentType = equipment.rawValue
            exercise.defaultIncrement = increment
            exercise.defaultRestSeconds = restSeconds
            exercise.formulaRaw = formula.rawValue
            exercise.customMetricUnit = unit
            exercise.isAssisted = isAssisted
            target = exercise
        } else {
            target = Exercise(
                name: trimmedName,
                muscleGroup: primaryMuscle.rawValue,
                secondaryMuscles: secondaryMuscles.map(\.rawValue),
                trackingType: trackingType,
                equipmentType: equipment.rawValue,
                defaultIncrement: increment,
                defaultRestSeconds: restSeconds,
                formula: formula,
                customMetricUnit: unit,
                isCustom: true,
                isAssisted: isAssisted
            )
            modelContext.insert(target)
        }
        try? modelContext.save()
        Haptics.shared.success()
        onCreate?(target)
        dismiss()
    }
}

// MARK: - Display metadata

private extension TrackingType {
    var iconName: String {
        switch self {
        case .weightAndReps: "dumbbell.fill"
        case .bodyweightAndReps: "figure.core.training"
        case .durationAndReps: "timer"
        case .timeAndDistance: "figure.run"
        case .customMetric: "slider.horizontal.3"
        }
    }

    var blurb: String {
        switch self {
        case .weightAndReps: "Weight on the bar × repetitions"
        case .bodyweightAndReps: "Reps, plus optional added weight"
        case .durationAndReps: "Time under tension × repetitions"
        case .timeAndDistance: "Cardio and conditioning: time + distance"
        case .customMetric: "Your own unit — RPE, band tension, tempo"
        }
    }
}

private extension OneRMFormula {
    var blurb: String {
        switch self {
        case .epley: "w × (1 + r/30) — rep PRs count toward your ceiling."
        case .brzycki: "w × 36/(37−r) — conservative below 10 reps."
        case .rawMax: "Bar weight only — reps never inflate the record."
        }
    }
}

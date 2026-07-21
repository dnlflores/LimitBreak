import SwiftUI
import SwiftData

/// Custom exercise creation form — every parameter from the spec is configurable.
struct ExerciseEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

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

    private let incrementOptions = [1.0, 2.5, 5.0, 10.0, 25.0]
    private let restOptions = [0, 30, 45, 60, 90, 120, 180, 240, 300]

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Exercise name", text: $name)
                    Picker("Equipment", selection: $equipment) {
                        ForEach(EquipmentType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }

                Section("Target Muscles") {
                    Picker("Primary", selection: $primaryMuscle) {
                        ForEach(MuscleGroup.allCases) { muscle in
                            Text(muscle.rawValue).tag(muscle)
                        }
                    }
                    secondaryMusclePicker
                }

                Section("Tracking") {
                    Picker("Parameter Type", selection: $trackingType) {
                        ForEach(TrackingType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    if trackingType == .customMetric {
                        TextField("Metric unit (e.g. RPE, tension level)", text: $customUnit)
                    }
                    Picker("Weight Increment", selection: $increment) {
                        ForEach(incrementOptions, id: \.self) { option in
                            Text("\(option.cleanWeight) lbs").tag(option)
                        }
                    }
                    Picker("Rest Timer", selection: $restSeconds) {
                        ForEach(restOptions, id: \.self) { seconds in
                            Text(seconds == 0 ? "None" : "\(seconds)s").tag(seconds)
                        }
                    }
                    Picker("1RM Formula", selection: $formula) {
                        ForEach(OneRMFormula.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var secondaryMusclePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MuscleGroup.allCases.filter { $0 != primaryMuscle }) { muscle in
                    let isSelected = secondaryMuscles.contains(muscle)
                    Button(muscle.rawValue) {
                        if isSelected {
                            secondaryMuscles.remove(muscle)
                        } else {
                            secondaryMuscles.insert(muscle)
                        }
                        Haptics.shared.tick()
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isSelected ? Theme.emerald : Theme.surfaceRaised, in: Capsule())
                    .foregroundStyle(isSelected ? .black : .primary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func create() {
        let exercise = Exercise(
            name: name.trimmingCharacters(in: .whitespaces),
            muscleGroup: primaryMuscle.rawValue,
            secondaryMuscles: secondaryMuscles.map(\.rawValue),
            trackingType: trackingType,
            equipmentType: equipment.rawValue,
            defaultIncrement: increment,
            defaultRestSeconds: restSeconds,
            formula: formula,
            customMetricUnit: trackingType == .customMetric && !customUnit.isEmpty ? customUnit : nil,
            isCustom: true
        )
        modelContext.insert(exercise)
        try? modelContext.save()
        Haptics.shared.success()
        onCreate?(exercise)
        dismiss()
    }
}

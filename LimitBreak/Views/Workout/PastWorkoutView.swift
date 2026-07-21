import SwiftUI
import SwiftData

/// Retroactive logging: rebuild a workout you did in the past, set by set.
/// Records that beat your all-time ceiling still count — quietly.
struct PastWorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout

    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    @State private var sessionName = ""
    @State private var entries: [EntryDraft] = []
    @State private var showExercisePicker = false

    private struct EntryDraft: Identifiable {
        let id = UUID()
        var exercise: Exercise
        var sets: [SetDraft] = [SetDraft()]
    }

    private struct SetDraft: Identifiable {
        let id = UUID()
        var weight = ""
        var reps = ""
        var isWarmup = false
    }

    private var canSave: Bool {
        entries.contains { entry in
            entry.sets.contains { (Int($0.reps) ?? 0) > 0 || (Double($0.weight) ?? 0) > 0 }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    detailsCard

                    ForEach($entries) { $entry in
                        exerciseCard($entry)
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
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle("Log Past Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showExercisePicker) {
                ExercisePickerSheet { exercise in
                    guard !entries.contains(where: { $0.exercise.id == exercise.id }) else { return }
                    entries.append(EntryDraft(exercise: exercise))
                }
            }
        }
    }

    // MARK: - Cards

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker(
                "When",
                selection: $date,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.subheadline.weight(.semibold))
            .tint(Theme.emerald)

            TextField("Session name (e.g. Push Day)", text: $sessionName)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .cardStyle()
    }

    private func exerciseCard(_ entry: Binding<EntryDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.wrappedValue.exercise.name)
                    .font(.headline)
                Spacer()
                Button {
                    entries.removeAll { $0.id == entry.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.crimson)
                }
            }

            ForEach(entry.sets) { $set in
                setRow($set, index: entry.wrappedValue.sets.firstIndex { $0.id == set.id } ?? 0) {
                    entry.wrappedValue.sets.removeAll { $0.id == set.id }
                }
            }

            Button {
                var sets = entry.wrappedValue.sets
                // Prefill from the previous row so straight sets are one tap each.
                var draft = SetDraft()
                if let last = sets.last {
                    draft.weight = last.weight
                    draft.reps = last.reps
                }
                sets.append(draft)
                entry.wrappedValue.sets = sets
                Haptics.shared.tick()
            } label: {
                Label("Add Set", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.emerald)
            }
        }
        .cardStyle()
    }

    private func setRow(_ set: Binding<SetDraft>, index: Int, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .frame(width: 20)
                .foregroundStyle(Theme.textDim)

            TextField("lbs", text: set.weight)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .padding(8)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))

            Text("×")
                .foregroundStyle(Theme.textDim)

            TextField("reps", text: set.reps)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(8)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))

            Button {
                set.wrappedValue.isWarmup.toggle()
                Haptics.shared.tick()
            } label: {
                Text("W")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(
                        set.wrappedValue.isWarmup ? Theme.gold.opacity(0.3) : Theme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(set.wrappedValue.isWarmup ? Theme.gold : Theme.textDim)
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    // MARK: - Save

    private func save() {
        let payload: [(exercise: Exercise, sets: [PastSetEntry])] = entries.compactMap { entry in
            let sets = entry.sets.compactMap { draft -> PastSetEntry? in
                let weight = Double(draft.weight) ?? 0
                let reps = Int(draft.reps) ?? 0
                guard weight > 0 || reps > 0 else { return nil }
                return PastSetEntry(weight: weight, reps: reps, isWarmup: draft.isWarmup)
            }
            return sets.isEmpty ? nil : (entry.exercise, sets)
        }
        guard !payload.isEmpty else { return }
        workout.logPastSession(name: sessionName, date: date, entries: payload)
        dismiss()
    }
}

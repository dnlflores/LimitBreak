import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSessionStore.self) private var store

    var body: some View {
        Group {
            if store.state.isActive {
                WatchActiveView()
            } else {
                WatchStartView()
            }
        }
        .background(LBColor.background)
    }
}

// MARK: - Start screen: routines + AI workout

struct WatchStartView: View {
    @Environment(WatchSessionStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.send(.startAIWorkout, haptic: .start)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(LBColor.limitBreakGradient)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("AI Workout")
                                    .font(.headline)
                                Text("Built on your iPhone")
                                    .font(.caption2)
                                    .foregroundStyle(LBColor.dim)
                            }
                        }
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(LBColor.limitBreakGradient, lineWidth: 1)
                                    .opacity(0.6)
                            )
                    )
                }

                Section("Routines") {
                    if store.routines.isEmpty {
                        Text(store.hasReceivedState
                            ? "No routines yet — build one on your iPhone."
                            : "Waiting for iPhone…")
                            .font(.caption)
                            .foregroundStyle(LBColor.dim)
                    }
                    ForEach(store.routines) { routine in
                        Button {
                            store.send(.startRoutine, routineID: routine.id, haptic: .start)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: routine.isAIGenerated ? "sparkles" : "square.stack.3d.up.fill")
                                    .foregroundStyle(routine.isAIGenerated ? LBColor.violet : LBColor.emerald)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(routine.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(routine.exerciseCount) movement\(routine.exerciseCount == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(LBColor.dim)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("LimitBreak")
            .overlay {
                if store.isBusy {
                    ProgressView()
                }
            }
        }
    }
}

// MARK: - Active session: one-tap logging

struct WatchActiveView: View {
    @Environment(WatchSessionStore.self) private var store
    @State private var showEndConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let exercise = store.currentExercise {
                        exerciseCard(exercise)
                        logButton(exercise)
                        nextExerciseButton
                    } else {
                        completeCard
                    }

                    restBanner

                    endButton
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(store.state.sessionName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func exerciseCard(_ exercise: WatchExerciseSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(exercise.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            HStack(spacing: 4) {
                ForEach(0..<exercise.target, id: \.self) { index in
                    Capsule()
                        .fill(index < exercise.done ? LBColor.emerald : Color.white.opacity(0.15))
                        .frame(width: 16, height: 5)
                }
            }

            Text(exercise.nextLabel)
                .font(.caption2)
                .foregroundStyle(LBColor.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func logButton(_ exercise: WatchExerciseSnapshot) -> some View {
        Button {
            store.send(.logNextSet, haptic: .success)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                Text("LOG SET \(min(exercise.done + 1, exercise.target))")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(LBColor.emerald)
        .foregroundStyle(.black)
        .disabled(store.isBusy)
    }

    private var nextExerciseButton: some View {
        Button {
            store.send(.nextExercise)
        } label: {
            Label("Next Exercise", systemImage: "forward.fill")
                .font(.caption.weight(.semibold))
        }
        .tint(LBColor.teal)
        .disabled(store.isBusy)
    }

    private var completeCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(LBColor.emerald)
            Text("All sets complete")
                .font(.headline)
            Text("\(Int(store.state.totalVolume).formatted()) lbs shifted · \(store.state.prCount) PR\(store.state.prCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(LBColor.dim)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var restBanner: some View {
        if let restEndsAt = store.state.restEndsAt, restEndsAt > Date() {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text(timerInterval: Date()...restEndsAt, countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 50)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(LBColor.teal)
        }
    }

    private var endButton: some View {
        Button {
            showEndConfirmation = true
        } label: {
            Text("End Session")
                .font(.caption)
        }
        .tint(.red)
        .confirmationDialog("End this session?", isPresented: $showEndConfirmation) {
            Button("End Session", role: .destructive) {
                store.send(.endSession, haptic: .stop)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

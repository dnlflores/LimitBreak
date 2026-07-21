import SwiftUI
import SwiftData

/// The routine (curation) manager, opened from the Train launcher. Browse every
/// saved routine, create new ones by hand or with AI, edit, and delete. Starting
/// a routine happens from the launcher cards — this sheet is for curation.
struct RoutineLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutManager.self) private var workout
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]

    @State private var showCreate = false
    @State private var routineToEdit: Routine?
    @State private var routineToDelete: Routine?

    var body: some View {
        NavigationStack {
            ScrollView {
                if routines.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(routines, id: \.id) { routine in
                            routineCard(routine)
                        }
                    }
                    .padding()
                }
            }
            .obsidianBackground()
            .navigationTitle("Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.shared.tick()
                        showCreate = true
                    } label: {
                        Label("New Routine", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                RoutineEditorView()
            }
            .sheet(item: $routineToEdit) { routine in
                RoutineEditorView(routine: routine)
            }
            .alert("Delete Routine?", isPresented: deleteAlertBinding, presenting: routineToDelete) { routine in
                Button("Delete", role: .destructive) {
                    workout.deleteRoutine(routine)
                }
                Button("Cancel", role: .cancel) {}
            } message: { routine in
                Text("\u{201C}\(routine.name)\u{201D} will be removed. Your logged workouts are not affected.")
            }
        }
    }

    // MARK: - Routine card

    private func routineCard(_ routine: Routine) -> some View {
        Button {
            Haptics.shared.tick()
            routineToEdit = routine
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text("\(routine.exerciseCount) exercise\(routine.exerciseCount == 1 ? "" : "s")")
                            if routine.isAIGenerated {
                                Label("AI", systemImage: "sparkles")
                                    .foregroundStyle(Theme.violet)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Menu {
                        Button {
                            routineToEdit = routine
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            routineToDelete = routine
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                }

                if !routine.exercises.isEmpty {
                    Text(routine.exercises.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .cardStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { routineToDelete != nil },
            set: { if !$0 { routineToDelete = nil } }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.limitBreakGradient)
            Text("No routines yet")
                .font(.title3.weight(.bold))
            Text("Curate a reusable workout — build it by hand or let the AI draft one. Saved routines quick-start from the Train tab.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Haptics.shared.tick()
                showCreate = true
            } label: {
                Label("New Routine", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}

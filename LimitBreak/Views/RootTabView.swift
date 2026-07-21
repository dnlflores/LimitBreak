import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        @Bindable var workout = workout

        TabView {
            Tab("Matrix", systemImage: "square.grid.3x3.fill") {
                SkillMatrixView()
            }
            Tab("Train", systemImage: "bolt.fill") {
                TrainView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                WorkoutHistoryView()
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                ExerciseLibraryView()
            }
            Tab("Saga", systemImage: "scroll.fill") {
                NarrativeView()
            }
        }
        .tint(Theme.emerald)
        .overlay {
            if let event = workout.limitBreakEvent {
                LimitBreakOverlay(event: event) {
                    workout.limitBreakEvent = nil
                }
            }
        }
        .task {
            ExerciseCatalog.seedIfNeeded(context: modelContext)
        }
    }
}

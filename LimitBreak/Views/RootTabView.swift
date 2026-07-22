import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkoutManager.self) private var workout

    @State private var selectedTab: Int

    init() {
        // Debug/UI-test hook: launch with "-open-tab <index>" to land on a tab.
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-open-tab"),
           arguments.indices.contains(flagIndex + 1),
           let tab = Int(arguments[flagIndex + 1]) {
            _selectedTab = State(initialValue: tab)
        } else {
            _selectedTab = State(initialValue: 0)
        }
    }

    var body: some View {
        @Bindable var workout = workout

        TabView(selection: $selectedTab) {
            Tab("Matrix", systemImage: "square.grid.3x3.fill", value: 0) {
                SkillMatrixView()
            }
            Tab("Train", systemImage: "bolt.fill", value: 1) {
                TrainView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: 2) {
                WorkoutHistoryView()
            }
            Tab("Library", systemImage: "books.vertical.fill", value: 3) {
                ExerciseLibraryView()
            }
            Tab("Saga", systemImage: "scroll.fill", value: 4) {
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
            WidgetSnapshotter.shared.refresh()
            // Debug/UI-test hook: launch with "-auto-start-session" to begin a
            // session immediately (drives watch & Live Activity verification).
            if ProcessInfo.processInfo.arguments.contains("-auto-start-session"),
               workout.activeSession == nil {
                let all = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
                workout.startSession(named: "Boss Fight", exercises: Array(all.prefix(2)))
            }
        }
    }
}

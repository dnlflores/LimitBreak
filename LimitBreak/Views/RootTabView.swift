import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkoutManager.self) private var workout

    @Query private var profiles: [TrainingProfile]

    @State private var selectedTab: Int
    @State private var onboardingProfile: TrainingProfile?

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
            Tab("Level", systemImage: "star.circle.fill", value: 0) {
                SkillMatrixView()
            }
            Tab("Train", systemImage: "bolt.fill", value: 1) {
                TrainView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: 2) {
                WorkoutHistoryView()
            }
            Tab("Library", systemImage: "books.vertical.fill", value: 3) {
                LibraryView()
            }
            Tab("Plan", systemImage: "calendar", value: 4) {
                PlanTabView()
            }
        }
        .tint(Theme.emerald)
        // Starting a session from anywhere (e.g. tapping a plan day on the Plan
        // tab) should drop the lifter into the Train tab's live logger.
        .onChange(of: workout.activeSession == nil) { _, isIdle in
            if !isIdle { withAnimation { selectedTab = 1 } }
        }
        .overlay {
            if let event = workout.limitBreakEvent {
                LimitBreakOverlay(event: event) {
                    workout.limitBreakEvent = nil
                }
            }
        }
        .fullScreenCover(item: $onboardingProfile) { profile in
            OnboardingView(profile: profile) { onboardingProfile = nil }
        }
        .task {
            ExerciseCatalog.seedIfNeeded(context: modelContext)
            // Collapse any duplicates CloudKit mirroring may have created (the
            // seeded catalog / singleton profile can be recreated per device),
            // then keep reconciling as remote changes stream in this session.
            CloudSyncDedupe.run(context: modelContext)
            CloudSyncDedupe.startObserving(context: modelContext)
            WidgetSnapshotter.shared.refresh()
            // Re-check the step goal on each app open (awards, reminder, tile).
            await StepGoalMonitor.shared.evaluate()

            // First launch: create the profile and ask what they're training
            // for. Suppressed under "-skip-onboarding", and under
            // "-in-memory-store" so every UI test doesn't have to dismiss it.
            let arguments = ProcessInfo.processInfo.arguments
            let suppressed = arguments.contains("-skip-onboarding")
                || arguments.contains("-in-memory-store")
            let profile = TrainingProfile.current(in: modelContext)
            if !profile.hasCompletedOnboarding, !suppressed {
                onboardingProfile = profile
            }
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

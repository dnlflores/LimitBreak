//
//  LimitBreakApp.swift
//  LimitBreak
//

import SwiftUI
import SwiftData

@main
struct LimitBreakApp: App {
    let container: ModelContainer
    @State private var workout: WorkoutManager

    init() {
        let schema = LimitBreakSchema.all
        // "-in-memory-store" (UI tests) keeps test data off the real store.
        let inMemory = ProcessInfo.processInfo.arguments.contains("-in-memory-store")
        // Mirror the store to the user's private CloudKit database so their
        // training log follows them onto a new iPhone (same iCloud account).
        // In-memory test stores can't sync, so CloudKit is off for those.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: inMemory ? .none : .automatic
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        _workout = State(initialValue: WorkoutManager(context: container.mainContext))

        // Remote surfaces: watch app commands, the Live Activity's button,
        // and home-screen widget snapshots.
        PhoneWatchBridge.shared.configure(context: container.mainContext)
        SessionCommandHub.logNextSet = {
            WorkoutManager.shared?.logNextSetInOrder()
        }
        WidgetSnapshotter.shared.configure(context: container.mainContext)

        // Siri / Shortcuts read the training log through this container.
        LimitBreakStats.injectedContainer = container

        // Daily step goal + streak: ask for notification permission and arm the
        // watchers (HealthKit background delivery, plus the 7pm step and streak
        // reminders — the latter reads the training log through this context).
        StepGoalMonitor.shared.configure(context: container.mainContext)
        StepGoalMonitor.shared.requestAuthorization()
        StepGoalMonitor.shared.start()
    }

    // "-skip-splash" (UI tests) jumps straight into the app.
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("-skip-splash")

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()

                if showSplash {
                    LaunchSplashView {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.08)))
                    .zIndex(1)
                }
            }
            .environment(workout)
            .preferredColorScheme(.dark)
            .onAppear { KeyboardDismisser.install() }
        }
        .modelContainer(container)
    }
}

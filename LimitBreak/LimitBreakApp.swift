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
        let schema = Schema([
            Exercise.self,
            WorkoutSession.self,
            ExerciseSet.self,
            PRRecord.self,
            Walk.self,
            Activity.self,
            Routine.self,
            RoutineItem.self,
        ])
        // "-in-memory-store" (UI tests) keeps test data off the real store.
        let inMemory = ProcessInfo.processInfo.arguments.contains("-in-memory-store")
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
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
        }
        .modelContainer(container)
    }
}

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
            Routine.self,
            RoutineItem.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        _workout = State(initialValue: WorkoutManager(context: container.mainContext))
    }

    @State private var showSplash = true

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

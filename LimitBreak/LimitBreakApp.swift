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
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        _workout = State(initialValue: WorkoutManager(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(workout)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}

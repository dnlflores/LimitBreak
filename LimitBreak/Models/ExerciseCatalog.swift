import Foundation
import SwiftData

/// Seeds the default exercise library on first launch.
enum ExerciseCatalog {

    static func seedIfNeeded(context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Exercise>())) ?? 0
        guard count == 0 else { return }
        for exercise in defaults { context.insert(exercise) }
        try? context.save()
    }

    private static var defaults: [Exercise] {
        [
            // Chest
            Exercise(name: "Barbell Bench Press", muscleGroup: "Chest", secondaryMuscles: ["Triceps", "Deltoids"]),
            Exercise(name: "Incline Dumbbell Press", muscleGroup: "Chest", secondaryMuscles: ["Deltoids"], equipmentType: "Dumbbell"),
            Exercise(name: "Cable Fly", muscleGroup: "Chest", equipmentType: "Cable", defaultRestSeconds: 60),
            Exercise(name: "Push-Up", muscleGroup: "Chest", secondaryMuscles: ["Triceps", "Core"], trackingType: .bodyweightAndReps, equipmentType: "Bodyweight", defaultRestSeconds: 60),

            // Back
            Exercise(name: "Deadlift", muscleGroup: "Lats", secondaryMuscles: ["Hamstrings", "Glutes", "Forearms"], defaultRestSeconds: 180),
            Exercise(name: "Barbell Row", muscleGroup: "Lats", secondaryMuscles: ["Biceps", "Forearms"]),
            Exercise(name: "Lat Pulldown", muscleGroup: "Lats", secondaryMuscles: ["Biceps"], equipmentType: "Cable"),
            Exercise(name: "Pull-Up", muscleGroup: "Lats", secondaryMuscles: ["Biceps", "Forearms"], trackingType: .bodyweightAndReps, equipmentType: "Bodyweight", defaultIncrement: 2.5, defaultRestSeconds: 120),
            Exercise(name: "Seated Cable Row", muscleGroup: "Lats", secondaryMuscles: ["Biceps"], equipmentType: "Cable"),

            // Legs
            Exercise(name: "Barbell Back Squat", muscleGroup: "Quads", secondaryMuscles: ["Glutes", "Hamstrings", "Core"], defaultRestSeconds: 180),
            Exercise(name: "Front Squat", muscleGroup: "Quads", secondaryMuscles: ["Core", "Glutes"], defaultRestSeconds: 180),
            Exercise(name: "Leg Press", muscleGroup: "Quads", secondaryMuscles: ["Glutes"], equipmentType: "Machine", defaultIncrement: 10),
            Exercise(name: "Romanian Deadlift", muscleGroup: "Hamstrings", secondaryMuscles: ["Glutes", "Forearms"]),
            Exercise(name: "Leg Curl", muscleGroup: "Hamstrings", equipmentType: "Machine", defaultRestSeconds: 60),
            Exercise(name: "Walking Lunge", muscleGroup: "Quads", secondaryMuscles: ["Glutes"], equipmentType: "Dumbbell", defaultRestSeconds: 60),
            Exercise(name: "Hip Thrust", muscleGroup: "Glutes", secondaryMuscles: ["Hamstrings"]),
            Exercise(name: "Standing Calf Raise", muscleGroup: "Calves", equipmentType: "Machine", defaultIncrement: 10, defaultRestSeconds: 45),

            // Shoulders
            Exercise(name: "Overhead Press", muscleGroup: "Deltoids", secondaryMuscles: ["Triceps", "Core"], defaultIncrement: 2.5),
            Exercise(name: "Lateral Raise", muscleGroup: "Deltoids", equipmentType: "Dumbbell", defaultIncrement: 2.5, defaultRestSeconds: 45),
            Exercise(name: "Face Pull", muscleGroup: "Deltoids", secondaryMuscles: ["Lats"], equipmentType: "Cable", defaultRestSeconds: 45),

            // Arms
            Exercise(name: "Barbell Curl", muscleGroup: "Biceps", secondaryMuscles: ["Forearms"], defaultIncrement: 2.5, defaultRestSeconds: 60),
            Exercise(name: "Hammer Curl", muscleGroup: "Biceps", secondaryMuscles: ["Forearms"], equipmentType: "Dumbbell", defaultIncrement: 2.5, defaultRestSeconds: 60),
            Exercise(name: "Triceps Pushdown", muscleGroup: "Triceps", equipmentType: "Cable", defaultRestSeconds: 60),
            Exercise(name: "Skull Crusher", muscleGroup: "Triceps", equipmentType: "Specialty Bar", defaultIncrement: 2.5, defaultRestSeconds: 60),
            Exercise(name: "Dip", muscleGroup: "Triceps", secondaryMuscles: ["Chest"], trackingType: .bodyweightAndReps, equipmentType: "Bodyweight", defaultRestSeconds: 90),

            // Core & Conditioning
            Exercise(name: "Plank", muscleGroup: "Core", trackingType: .durationAndReps, equipmentType: "Bodyweight", defaultRestSeconds: 60),
            Exercise(name: "Hanging Leg Raise", muscleGroup: "Core", secondaryMuscles: ["Forearms"], trackingType: .bodyweightAndReps, equipmentType: "Bodyweight", defaultRestSeconds: 60),
            Exercise(name: "Kettlebell Swing", muscleGroup: "Glutes", secondaryMuscles: ["Hamstrings", "Core"], equipmentType: "Kettlebell", defaultRestSeconds: 60),
            Exercise(name: "Farmer's Carry", muscleGroup: "Forearms", secondaryMuscles: ["Core"], trackingType: .durationAndReps, equipmentType: "Dumbbell", defaultRestSeconds: 90),
            Exercise(name: "Treadmill Run", muscleGroup: "Quads", secondaryMuscles: ["Calves"], trackingType: .timeAndDistance, equipmentType: "Machine", defaultRestSeconds: 0),
            Exercise(name: "Rowing Erg", muscleGroup: "Lats", secondaryMuscles: ["Quads", "Core"], trackingType: .timeAndDistance, equipmentType: "Machine", defaultRestSeconds: 60),
        ]
    }
}

import Foundation
import SwiftData

/// Seeds the default exercise library on first launch, and backfills guides
/// (descriptions + how-to steps) onto catalogs seeded by older versions.
enum ExerciseCatalog {

    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []

        guard !existing.isEmpty else {
            for exercise in defaults {
                apply(guide: guides[exercise.name], to: exercise)
                context.insert(exercise)
            }
            try? context.save()
            return
        }

        // Guides shipped after the catalog was first seeded: fill any default
        // movement that doesn't have one yet, leaving user-authored text alone.
        var changed = false
        for exercise in existing where exercise.exerciseDescription == nil {
            if let guide = guides[exercise.name] {
                apply(guide: guide, to: exercise)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private static func apply(guide: Guide?, to exercise: Exercise) {
        guard let guide else { return }
        if exercise.exerciseDescription == nil { exercise.exerciseDescription = guide.description }
        if exercise.instructions == nil { exercise.instructions = guide.steps.joined(separator: "\n") }
    }

    // MARK: - Guides

    struct Guide {
        let description: String
        let steps: [String]
    }

    /// Keyed by exercise name; applied to defaults on seed and backfill.
    static let guides: [String: Guide] = [
        "Barbell Bench Press": Guide(
            description: "The classic horizontal press for building chest, shoulder, and triceps strength.",
            steps: [
                "Lie flat with eyes under the bar, feet planted, and grip slightly wider than shoulders.",
                "Unrack and lower the bar to mid-chest with elbows tucked about 45 degrees.",
                "Press back up to lockout, keeping shoulder blades pinched and hips on the bench.",
            ]),
        "Incline Dumbbell Press": Guide(
            description: "An upper-chest emphasis press with a longer range of motion than the barbell.",
            steps: [
                "Set the bench to 30-45 degrees and start with dumbbells at shoulder level.",
                "Press up and slightly inward until arms are extended.",
                "Lower under control until you feel a stretch across the upper chest.",
            ]),
        "Cable Fly": Guide(
            description: "An isolation movement that keeps constant tension on the chest through the full arc.",
            steps: [
                "Set pulleys at chest height and step forward with a slight stagger.",
                "With soft elbows, sweep the handles together in a hugging arc.",
                "Squeeze at the midline, then let the cables pull your arms open slowly.",
            ]),
        "Push-Up": Guide(
            description: "The foundational bodyweight press — chest, triceps, and core in one move.",
            steps: [
                "Set hands slightly wider than shoulders in a straight-line plank.",
                "Lower your chest to just above the floor, elbows about 45 degrees.",
                "Push back up without letting the hips sag or pike.",
            ]),
        "Deadlift": Guide(
            description: "The heaviest pull in the gym: total posterior chain, grip, and back strength.",
            steps: [
                "Stand with mid-foot under the bar; hinge and grip just outside your legs.",
                "Brace, flatten your back, and push the floor away to stand tall.",
                "Lock out with glutes, then hinge the bar back down under control.",
            ]),
        "Barbell Row": Guide(
            description: "A bent-over pull that thickens the lats and mid-back.",
            steps: [
                "Hinge to about 45 degrees with a flat back, bar hanging at arm's length.",
                "Row the bar to your lower ribs, elbows driving behind you.",
                "Pause briefly, then lower without letting the torso rise.",
            ]),
        "Lat Pulldown": Guide(
            description: "A vertical pull for lat width, easier to scale than pull-ups.",
            steps: [
                "Grip the bar wider than shoulders and sit with thighs locked under the pads.",
                "Pull the bar to your collarbone, driving elbows down and back.",
                "Control the return until arms are fully stretched.",
            ]),
        "Pull-Up": Guide(
            description: "The king of bodyweight pulls — lats, biceps, and grip.",
            steps: [
                "Hang from the bar with hands just outside shoulders.",
                "Pull your chin over the bar, leading with the chest.",
                "Lower all the way to a dead hang each rep.",
            ]),
        "Seated Cable Row": Guide(
            description: "A supported horizontal pull for mid-back thickness and posture.",
            steps: [
                "Sit tall with knees soft and grab the handle at arm's length.",
                "Row to your stomach, squeezing shoulder blades together.",
                "Let the weight stretch you forward slowly between reps.",
            ]),
        "Barbell Back Squat": Guide(
            description: "The cornerstone lower-body lift: quads, glutes, and a braced core under load.",
            steps: [
                "Rack the bar across your upper back and stand shoulder-width.",
                "Brace, then sit down between your hips until thighs reach parallel or below.",
                "Drive through mid-foot back to standing, knees tracking over toes.",
            ]),
        "Front Squat": Guide(
            description: "A quad-dominant squat that demands an upright torso and strong core.",
            steps: [
                "Rest the bar on your front delts with elbows high.",
                "Squat straight down, keeping the chest tall.",
                "Stand back up before the elbows drop.",
            ]),
        "Leg Press": Guide(
            description: "Heavy leg training without balancing a bar — quads and glutes do the work.",
            steps: [
                "Place feet shoulder-width on the platform.",
                "Lower until knees near 90 degrees without the lower back curling off the pad.",
                "Press back up, stopping just short of locked knees.",
            ]),
        "Romanian Deadlift": Guide(
            description: "A hip hinge that loads the hamstrings and glutes through a deep stretch.",
            steps: [
                "Hold the bar at your hips with a slight knee bend.",
                "Push your hips back, sliding the bar down your thighs until hamstrings stretch.",
                "Squeeze glutes to stand, keeping the bar close the whole way.",
            ]),
        "Leg Curl": Guide(
            description: "Direct hamstring isolation from the machine.",
            steps: [
                "Line your knees up with the machine's pivot point.",
                "Curl the pad toward your glutes without lifting your hips.",
                "Resist on the way back to full extension.",
            ]),
        "Walking Lunge": Guide(
            description: "A traveling single-leg builder for quads, glutes, and balance.",
            steps: [
                "Step forward far enough that both knees can bend to 90 degrees.",
                "Lower the back knee toward the floor with a tall torso.",
                "Push through the front heel into the next stride.",
            ]),
        "Hip Thrust": Guide(
            description: "The most direct way to load the glutes heavy.",
            steps: [
                "Rest your upper back on a bench with the bar over your hips.",
                "Drive through your heels until your torso is level with the floor.",
                "Squeeze hard at the top, then lower with control.",
            ]),
        "Standing Calf Raise": Guide(
            description: "Loaded ankle extension for calf size and strength.",
            steps: [
                "Stand with the balls of your feet on the platform edge.",
                "Lower your heels into a deep stretch.",
                "Rise as high as possible and pause at the top.",
            ]),
        "Overhead Press": Guide(
            description: "The strict standing press — shoulders, triceps, and a braced trunk.",
            steps: [
                "Grip just outside shoulders with the bar at your collarbone.",
                "Brace and press straight up, pulling your head through at the top.",
                "Lock out overhead, biceps by your ears, then lower to the start.",
            ]),
        "Lateral Raise": Guide(
            description: "Isolation for the side delts — the width builder.",
            steps: [
                "Stand tall with dumbbells at your sides, elbows slightly bent.",
                "Raise out to the sides until arms are parallel with the floor.",
                "Lower slowly — no swinging.",
            ]),
        "Face Pull": Guide(
            description: "Rear-delt and upper-back health work that balances all your pressing.",
            steps: [
                "Set the rope at face height and grab with thumbs toward you.",
                "Pull toward your face, spreading the rope past your ears.",
                "Squeeze the rear delts, then return under control.",
            ]),
        "Barbell Curl": Guide(
            description: "The straight-bar biceps builder.",
            steps: [
                "Stand with a shoulder-width underhand grip.",
                "Curl the bar to shoulder height without swinging the hips.",
                "Lower all the way to full elbow extension.",
            ]),
        "Hammer Curl": Guide(
            description: "A neutral-grip curl that hits the biceps and forearms together.",
            steps: [
                "Hold dumbbells with palms facing each other.",
                "Curl up keeping the neutral grip the whole way.",
                "Control the descent — no dropping.",
            ]),
        "Triceps Pushdown": Guide(
            description: "Cable isolation for all three triceps heads.",
            steps: [
                "Pin your elbows to your sides on a high cable.",
                "Push the handle down to full lockout.",
                "Let it rise only until forearms pass parallel.",
            ]),
        "Skull Crusher": Guide(
            description: "A lying extension that stretches and loads the long head of the triceps.",
            steps: [
                "Lie back with the bar over your chest, hands narrow.",
                "Bend only at the elbows, lowering the bar toward your forehead.",
                "Extend back to lockout without flaring the elbows.",
            ]),
        "Dip": Guide(
            description: "A deep bodyweight press for triceps and lower chest.",
            steps: [
                "Support yourself on parallel bars, arms locked.",
                "Lower until shoulders dip just below the elbows.",
                "Press back up without kipping.",
            ]),
        "Plank": Guide(
            description: "The isometric core standard — anti-extension under fatigue.",
            steps: [
                "Set forearms under shoulders in a straight line from head to heels.",
                "Squeeze glutes and brace your abs.",
                "Breathe steadily; stop when the hips break the line.",
            ]),
        "Hanging Leg Raise": Guide(
            description: "Lower-ab and hip-flexor work with a free grip bonus.",
            steps: [
                "Hang from a bar with a tight, hollow body.",
                "Raise your legs to at least hip height without swinging.",
                "Lower slowly to a dead hang.",
            ]),
        "Kettlebell Swing": Guide(
            description: "A ballistic hip hinge for explosive posterior-chain power and conditioning.",
            steps: [
                "Hike the bell back between your legs like a center snap.",
                "Snap your hips forward to float the bell to chest height.",
                "Let it swing back down and immediately load the next rep.",
            ]),
        "Farmer's Carry": Guide(
            description: "Loaded carries for grip, traps, and a bulletproof trunk.",
            steps: [
                "Deadlift a heavy dumbbell in each hand.",
                "Walk tall with quick, controlled steps.",
                "Keep shoulders level and core braced until time runs out.",
            ]),
        "Treadmill Run": Guide(
            description: "Steady-state or interval running for conditioning and leg endurance.",
            steps: [
                "Warm up at an easy pace for a few minutes.",
                "Settle into your target speed and keep an upright, relaxed stride.",
                "Cool down with a walk before stepping off.",
            ]),
        "Rowing Erg": Guide(
            description: "Full-body conditioning: legs, back, and lungs in every stroke.",
            steps: [
                "Drive with the legs first, then swing the torso, then pull the handle.",
                "Reverse the order on the way back: arms, torso, legs.",
                "Keep strokes long and powerful rather than fast and short.",
            ]),
    ]

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

import Foundation
import SwiftData

/// The bundled movement library (Resources/ExerciseCatalog.json): ~250
/// exercises with muscle mappings, tracking setup, and guides. Seeds the whole
/// catalog on first launch; on later launches it merges movements added in app
/// updates and backfills guides onto defaults from older versions. Custom
/// exercises are never touched.
enum ExerciseCatalog {

    struct Entry: Decodable {
        let name: String
        let muscle: String
        let secondary: [String]?
        let tracking: String?
        let equipment: String?
        let incr: Double?
        let rest: Int?
        let formula: String?
        let assisted: Bool?
        let unit: String?
        let desc: String
        let steps: [String]
    }

    /// Loaded once per launch; the JSON ships in the app bundle.
    static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "ExerciseCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }()

    static func seedIfNeeded(context: ModelContext) {
        guard !entries.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let byName = Dictionary(existing.map { ($0.name.lowercased(), $0) }) { first, _ in first }

        var changed = false
        for entry in entries {
            if let current = byName[entry.name.lowercased()] {
                // Same-named movement already there (default from an older
                // version, or a user's custom): only backfill missing guides
                // on defaults, never touch custom exercises.
                guard !current.isCustom, current.exerciseDescription == nil else { continue }
                current.exerciseDescription = entry.desc
                if current.instructions == nil {
                    current.instructions = entry.steps.joined(separator: "\n")
                }
                changed = true
            } else {
                context.insert(makeExercise(from: entry))
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private static func makeExercise(from entry: Entry) -> Exercise {
        let exercise = Exercise(
            name: entry.name,
            muscleGroup: entry.muscle,
            secondaryMuscles: entry.secondary ?? [],
            trackingType: entry.tracking.flatMap(TrackingType.init) ?? .weightAndReps,
            equipmentType: entry.equipment ?? "Barbell",
            defaultIncrement: entry.incr ?? 5.0,
            defaultRestSeconds: entry.rest ?? 90,
            formula: entry.formula.flatMap(OneRMFormula.init) ?? .epley,
            customMetricUnit: entry.unit,
            isCustom: false,
            isAssisted: entry.assisted ?? false
        )
        exercise.exerciseDescription = entry.desc
        exercise.instructions = entry.steps.joined(separator: "\n")
        return exercise
    }
}

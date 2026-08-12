import Foundation
import simd

/// A movement rendered as an animation: two keyframes, a camera, and whatever
/// the lifter is holding.
///
/// Two keyframes is not a simplification — it is the shape of the thing. A
/// resistance exercise *is* an oscillation between a start and an end position,
/// which is also exactly what the bundled exercise dataset already stores as
/// its two reference photos. Movements that genuinely aren't two-pose (Olympic
/// lifts, walking lunges) need more keyframes; the type takes a list so they
/// can have them without a redesign.
struct ExerciseClip: Sendable {
    let name: String
    /// Camera rotation about the vertical axis, degrees. Chosen per movement so
    /// the working joints aren't foreshortened — a lateral raise reads from the
    /// front, a bench press from a three-quarter view.
    let azimuth: Float
    let equipment: Equipment
    /// Floor or bench height, drawn as a faint reference so a supine or seated
    /// movement has somewhere to be. Nil for hanging movements.
    let ground: Float?
    let keyframes: [HumanoidPose]

    enum Equipment: Sendable {
        case none
        /// Held in both hands — spans the grip.
        case barbell
        /// Racked across the traps, anchored to the neck rather than the hands.
        case barbellOnBack
        case dumbbells
        /// World-anchored at `height`; the grip stays on it while the body moves.
        case fixedBar(height: Float)
    }

    /// The pose at a normalised point in the rep, eased so the figure slows at
    /// both ends the way a controlled rep does. Linear timing reads mechanical
    /// and, worse, makes the lockout look as brief as the mid-rep.
    func pose(at progress: Float) -> HumanoidPose {
        guard keyframes.count > 1 else { return keyframes.first ?? HumanoidPose() }
        guard progress < 1 else { return keyframes[keyframes.count - 1] }
        let span = Float(keyframes.count - 1)
        let scaled = max(progress, 0) * span
        let index = min(Int(scaled), keyframes.count - 2)
        let t = scaled - Float(index)
        let eased = t * t * (3 - 2 * t)
        return HumanoidPose.interpolate(keyframes[index], keyframes[index + 1], eased)
    }
}

// MARK: - Catalog

/// The authored clips, loaded once from `ExerciseMotion.json`.
///
/// Data rather than code so the catalog can grow without a recompile, and so
/// the offline authoring harness and the app read the *same* file — two copies
/// of a pose drift, and a drifted pose is one nobody notices is wrong.
enum ExerciseMotion {

    /// The clip for a movement, or nil when it hasn't been authored yet.
    /// Callers fall back to the still photo, so the catalog fills in gradually.
    static func clip(for exerciseName: String) -> ExerciseClip? {
        catalog[normalize(exerciseName)]
    }

    static var authoredCount: Int { catalog.count }
    static var authoredNames: [String] { catalog.values.map(\.name).sorted() }

    /// Punctuation- and case-insensitive, so "Pull-Up" matches "pull up".
    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let catalog: [String: ExerciseClip] = {
        guard let url = Bundle.main.url(forResource: "ExerciseMotion", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(MotionDocument.self, from: data)
        else {
            // A missing or malformed file costs the animations, not the app:
            // every call site already falls back to the still photo.
            assertionFailure("ExerciseMotion.json is missing or unreadable")
            return [:]
        }
        return Dictionary(
            document.clips.map { (normalize($0.name), $0.clip) },
            uniquingKeysWith: { first, _ in first }
        )
    }()
}

// MARK: - Decoding

private struct MotionDocument: Decodable {
    let clips: [ClipData]
}

/// The on-disk shape. Kept separate from `ExerciseClip` so the file format can
/// change — more keyframes, new equipment — without the renderer caring.
private struct ClipData: Decodable {
    let name: String
    let azimuth: Float
    let equipment: String
    let ground: Float?
    let barHeight: Float?
    let keyframes: [FrameData]

    var clip: ExerciseClip {
        ExerciseClip(
            name: name,
            azimuth: azimuth,
            equipment: resolvedEquipment,
            ground: ground,
            keyframes: keyframes.map(\.pose)
        )
    }

    private var resolvedEquipment: ExerciseClip.Equipment {
        switch equipment {
        case "barbell":       return .barbell
        case "barbellOnBack": return .barbellOnBack
        case "dumbbells":     return .dumbbells
        case "fixedBar":      return .fixedBar(height: barHeight ?? 1.425)
        default:              return .none
        }
    }
}

private struct FrameData: Decodable {
    let root: [Float]?
    let rootRotation: [Float]?
    let angles: [String: [Float]]?

    var pose: HumanoidPose {
        var result = HumanoidPose()
        if let root, root.count == 3 { result.rootPosition = SIMD3(root[0], root[1], root[2]) }
        if let rootRotation, rootRotation.count == 3 {
            result.rootRotation = SIMD3(rootRotation[0], rootRotation[1], rootRotation[2])
        }
        for (name, value) in angles ?? [:] {
            // An unknown bone name is skipped rather than fatal — a newer file
            // naming a bone this build doesn't have still renders everything
            // else it describes.
            guard let bone = HumanoidRig.Bone(rawValue: name), value.count == 3 else { continue }
            result.angles[bone] = SIMD3(value[0], value[1], value[2])
        }
        return result
    }
}

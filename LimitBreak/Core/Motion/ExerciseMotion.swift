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

/// The authored clips, looked up by movement name.
///
/// This is the spike's five movements, deliberately spanning standing, supine
/// and hanging, and both the sagittal and frontal planes — the cases that break
/// a rig that only ever swings limbs forwards and backwards.
enum ExerciseMotion {

    /// The clip for a movement, or nil when it hasn't been authored yet. Callers
    /// fall back to the still photo, so the catalog can fill in gradually.
    static func clip(for exerciseName: String) -> ExerciseClip? {
        catalog[normalize(exerciseName)]
    }

    static var authoredCount: Int { catalog.count }

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let catalog: [String: ExerciseClip] = {
        Dictionary(uniqueKeysWithValues: all.map { (normalize($0.name), $0) })
    }()

    private static let all: [ExerciseClip] = [barbellCurl, backSquat, benchPress, pullUp, lateralRaise]

    // MARK: Standing, sagittal — elbow flexion only.

    private static let barbellCurl = ExerciseClip(
        name: "Barbell Curl", azimuth: 22, equipment: .barbell, ground: 0,
        keyframes: [
            HumanoidPose(angles: [
                .upperArmL: [-8, 0, -6], .upperArmR: [-8, 0, 6],
                .forearmL: [-6, 0, 0], .forearmR: [-6, 0, 0],
            ]),
            HumanoidPose(angles: [
                .upperArmL: [-14, 0, -6], .upperArmR: [-14, 0, 6],
                .forearmL: [-142, 0, 0], .forearmR: [-142, 0, 0],
            ]),
        ]
    )

    // MARK: Standing, large root translation — the bar rides the traps.

    private static let backSquat = ExerciseClip(
        name: "Barbell Back Squat", azimuth: 26, equipment: .barbellOnBack, ground: 0,
        keyframes: [
            HumanoidPose(angles: [
                .upperArmL: [12, 0, -46], .upperArmR: [12, 0, 46],
                .forearmL: [-118, 0, 0], .forearmR: [-118, 0, 0],
            ]),
            HumanoidPose(
                rootPosition: [0, 0.52, -0.05], rootRotation: [20, 0, 0],
                angles: [
                    .upperArmL: [12, 0, -46], .upperArmR: [12, 0, 46],
                    .forearmL: [-118, 0, 0], .forearmR: [-118, 0, 0],
                    .thighL: [-92, 0, 0], .thighR: [-92, 0, 0],
                    .shinL: [84, 0, 0], .shinR: [84, 0, 0],
                    .footL: [22, 0, 0], .footR: [22, 0, 0],
                ]
            ),
        ]
    )

    // MARK: Supine — laid down entirely by the root, arms authored as "forward".

    private static let benchPress = ExerciseClip(
        name: "Barbell Bench Press", azimuth: 62, equipment: .barbell, ground: 0.42,
        keyframes: [
            HumanoidPose(
                rootPosition: [0, 0.62, 0], rootRotation: [-90, 0, 0],
                angles: [
                    .upperArmL: [-88, 0, -14], .upperArmR: [-88, 0, 14],
                    .forearmL: [-4, 0, 0], .forearmR: [-4, 0, 0],
                    .thighL: [48, 0, -6], .thighR: [48, 0, 6],
                    .shinL: [46, 0, 0], .shinR: [46, 0, 0],
                    .footL: [-40, 0, 0], .footR: [-40, 0, 0],
                ]
            ),
            HumanoidPose(
                rootPosition: [0, 0.62, 0], rootRotation: [-90, 0, 0],
                angles: [
                    .upperArmL: [-46, 0, -52], .upperArmR: [-46, 0, 52],
                    .forearmL: [-72, 0, 0], .forearmR: [-72, 0, 0],
                    .thighL: [48, 0, -6], .thighR: [48, 0, 6],
                    .shinL: [46, 0, 0], .shinR: [46, 0, 0],
                    .footL: [-40, 0, 0], .footR: [-40, 0, 0],
                ]
            ),
        ]
    )

    // MARK: Hanging — the grip stays on a fixed bar while the body travels.

    private static let pullUp = ExerciseClip(
        name: "Pull-Up", azimuth: 16, equipment: .fixedBar(height: 1.425), ground: nil,
        keyframes: [
            HumanoidPose(
                rootPosition: [0, 0.60, 0],
                angles: [
                    .upperArmL: [0, 0, -170], .upperArmR: [0, 0, 170],
                    .forearmL: [0, 0, -4], .forearmR: [0, 0, 4],
                    .thighL: [-26, 0, 0], .thighR: [-26, 0, 0],
                    .shinL: [34, 0, 0], .shinR: [34, 0, 0],
                ]
            ),
            HumanoidPose(
                rootPosition: [0, 0.996, 0],
                angles: [
                    .upperArmL: [0, 0, -140], .upperArmR: [0, 0, 140],
                    .forearmL: [0, 0, 74], .forearmR: [0, 0, -74],
                    .thighL: [-52, 0, 0], .thighR: [-52, 0, 0],
                    .shinL: [64, 0, 0], .shinR: [64, 0, 0],
                ]
            ),
        ]
    )

    // MARK: Frontal plane — the case a sagittal-only rig gets wrong.

    private static let lateralRaise = ExerciseClip(
        name: "Lateral Raise", azimuth: 8, equipment: .dumbbells, ground: 0,
        keyframes: [
            HumanoidPose(angles: [
                .upperArmL: [0, 0, -8], .upperArmR: [0, 0, 8],
                .forearmL: [-4, 0, 0], .forearmR: [-4, 0, 0],
            ]),
            HumanoidPose(angles: [
                .upperArmL: [0, 0, -88], .upperArmR: [0, 0, 88],
                .forearmL: [-6, 0, -4], .forearmR: [-6, 0, 4],
            ]),
        ]
    )
}

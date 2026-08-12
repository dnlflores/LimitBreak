import Foundation
import simd

/// The skeleton every exercise animation is posed on.
///
/// One rig, shared by the whole catalog. A movement ships as nothing but joint
/// *angles* — no mesh, no frames, no video — which is what makes this approach
/// viable at catalog scale: a pose is ~240 bytes, so all 264 movements cost
/// roughly 130 KB. The same catalog as looping video would be tens of
/// megabytes, and as GIFs, hundreds.
///
/// Angles also survive things pixels can't. They render at any resolution, from
/// any camera angle, at any tempo, in whichever accent colour the lifter picked
/// — and they retarget onto a 3D character later without re-authoring, because
/// joint rotations are exactly what a 3D rig consumes.
enum HumanoidRig {

    /// Bones are named for what they *are*, never for the joint at their far
    /// end. An earlier revision used distal-joint names (`elbowL` for the upper
    /// arm, `clavL` for the collarbone) and "raise the arm" then looked
    /// identical to "swing the collarbone" — which silently produced arms in
    /// the wrong plane. The naming is load-bearing.
    enum Bone: String, CaseIterable, Sendable {
        case pelvis                                   // root
        case spine, chest, neck, head
        case shoulderL, upperArmL, forearmL
        case shoulderR, upperArmR, forearmR
        case hipL, thighL, shinL, footL
        case hipR, thighR, shinR, footR
    }

    /// One rigid segment: where it hangs from, which way it points at rest, and
    /// how long it is. Lengths are in body units — the figure stands about 1.5
    /// tall with its feet near y = 0.
    struct Segment: Sendable {
        let bone: Bone
        let parent: Bone
        /// Unit direction in the parent's frame, before this bone's rotation.
        let rest: SIMD3<Float>
        let length: Float
    }

    /// Ordered parent-before-child, so one forward pass solves the whole rig.
    static let segments: [Segment] = [
        Segment(bone: .spine,     parent: .pelvis,    rest: [0, 1, 0],  length: 0.14),
        Segment(bone: .chest,     parent: .spine,     rest: [0, 1, 0],  length: 0.18),
        Segment(bone: .neck,      parent: .chest,     rest: [0, 1, 0],  length: 0.10),
        Segment(bone: .head,      parent: .neck,      rest: [0, 1, 0],  length: 0.13),

        Segment(bone: .shoulderL, parent: .chest,     rest: [1, 0, 0],  length: 0.17),
        Segment(bone: .upperArmL, parent: .shoulderL, rest: [0, -1, 0], length: 0.27),
        Segment(bone: .forearmL,  parent: .upperArmL, rest: [0, -1, 0], length: 0.24),
        Segment(bone: .shoulderR, parent: .chest,     rest: [-1, 0, 0], length: 0.17),
        Segment(bone: .upperArmR, parent: .shoulderR, rest: [0, -1, 0], length: 0.27),
        Segment(bone: .forearmR,  parent: .upperArmR, rest: [0, -1, 0], length: 0.24),

        Segment(bone: .hipL,      parent: .pelvis,    rest: [1, 0, 0],  length: 0.10),
        Segment(bone: .thighL,    parent: .hipL,      rest: [0, -1, 0], length: 0.44),
        Segment(bone: .shinL,     parent: .thighL,    rest: [0, -1, 0], length: 0.42),
        Segment(bone: .footL,     parent: .shinL,     rest: [0, 0, 1],  length: 0.16),
        Segment(bone: .hipR,      parent: .pelvis,    rest: [-1, 0, 0], length: 0.10),
        Segment(bone: .thighR,    parent: .hipR,      rest: [0, -1, 0], length: 0.44),
        Segment(bone: .shinR,     parent: .thighR,    rest: [0, -1, 0], length: 0.42),
        Segment(bone: .footR,     parent: .shinR,     rest: [0, 0, 1],  length: 0.16),
    ]

    /// Solves world-space joint positions for a pose.
    ///
    /// Rotations compose down the chain, so bone lengths are preserved exactly
    /// — a figure posed this way cannot stretch a forearm or detach a limb, no
    /// matter what angles it is given. That guarantee is the reason to animate
    /// a skeleton rather than generate frames: a video model has no such
    /// constraint, and a morphing elbow teaches the wrong thing.
    static func solve(_ pose: HumanoidPose) -> [Bone: SIMD3<Float>] {
        var rotation: [Bone: simd_float3x3] = [.pelvis: rotationMatrix(pose.rootRotation)]
        var position: [Bone: SIMD3<Float>] = [.pelvis: pose.rootPosition]

        for segment in segments {
            guard let parentRotation = rotation[segment.parent],
                  let parentPosition = position[segment.parent]
            else { continue }
            let local = rotationMatrix(pose.angles[segment.bone] ?? .zero)
            let world = parentRotation * local
            rotation[segment.bone] = world
            position[segment.bone] = parentPosition + world * (segment.rest * segment.length)
        }
        return position
    }

    /// Intrinsic X→Y→Z Euler angles, in degrees.
    ///
    /// Degrees rather than radians because these numbers are hand-authored and
    /// read back by a human checking a pose; the conversion is free.
    static func rotationMatrix(_ degrees: SIMD3<Float>) -> simd_float3x3 {
        let r = degrees * (.pi / 180)
        let (cx, sx) = (cos(r.x), sin(r.x))
        let (cy, sy) = (cos(r.y), sin(r.y))
        let (cz, sz) = (cos(r.z), sin(r.z))

        // Columns, per simd's column-major convention.
        let rx = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, cx, sx), SIMD3(0, -sx, cx))
        let ry = simd_float3x3(SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy))
        let rz = simd_float3x3(SIMD3(cz, sz, 0), SIMD3(-sz, cz, 0), SIMD3(0, 0, 1))
        return rx * ry * rz
    }
}

/// One keyframe: where the body is, which way it faces, and every joint angle.
///
/// Joint angles are always authored in the *upright* body frame. Lying and
/// hanging come from `rootRotation` and `rootPosition` alone, so a pressing arm
/// is written as "straight out in front" whether the lifter is standing or on a
/// bench. Without that rule every supine movement has to be re-derived in a
/// rotated frame by hand, which is where pose authoring goes wrong.
struct HumanoidPose: Sendable {
    var rootPosition: SIMD3<Float> = [0, 0.9, 0]
    var rootRotation: SIMD3<Float> = .zero
    var angles: [HumanoidRig.Bone: SIMD3<Float>] = [:]

    /// Blends two keyframes. Interpolating angles (rather than joint positions)
    /// is what keeps limbs rigid through the middle of a rep — position lerp
    /// shortens a bone at mid-travel, which reads as a limb telescoping.
    static func interpolate(_ a: HumanoidPose, _ b: HumanoidPose, _ t: Float) -> HumanoidPose {
        var result = HumanoidPose(
            rootPosition: mix(a.rootPosition, b.rootPosition, t: t),
            rootRotation: mix(a.rootRotation, b.rootRotation, t: t)
        )
        for bone in Set(a.angles.keys).union(b.angles.keys) {
            result.angles[bone] = mix(a.angles[bone] ?? .zero, b.angles[bone] ?? .zero, t: t)
        }
        return result
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}

//
//  ExerciseMotionTests.swift
//  LimitBreakTests
//
//  The animated-figure rig. The invariant worth guarding is rigidity: the whole
//  argument for animating a skeleton rather than generating frames is that a
//  limb cannot stretch or detach, whatever angles it is handed. A video model
//  offers no such guarantee, and a morphing elbow teaches the wrong thing.
//

import Foundation
import Testing
import SwiftData
import simd
@testable import LimitBreak

struct HumanoidRigTests {

    /// Every bone keeps its authored length in any pose. This is the property
    /// the approach is sold on, so it is checked against deliberately extreme
    /// angles rather than the tame ones the catalog happens to use.
    @Test func boneLengthsSurviveAnyPose() {
        let extremes: [SIMD3<Float>] = [
            [0, 0, 0], [180, 0, 0], [-170, 45, 90], [90, 90, 90], [-45, -135, 22],
        ]
        for (index, angle) in extremes.enumerated() {
            var pose = HumanoidPose(rootRotation: angle)
            for bone in HumanoidRig.Bone.allCases where bone != .pelvis {
                // Fan the angles out so no two bones share a rotation.
                pose.angles[bone] = angle + SIMD3(Float(index) * 13, 7, -11)
            }
            let joints = HumanoidRig.solve(pose)

            for segment in HumanoidRig.segments {
                guard let a = joints[segment.parent], let b = joints[segment.bone] else {
                    Issue.record("\(segment.bone) did not solve")
                    continue
                }
                #expect(
                    abs(simd_length(b - a) - segment.length) < 0.0005,
                    "\(segment.bone) measured \(simd_length(b - a)), authored \(segment.length)"
                )
            }
        }
    }

    /// Mid-rep is where a naive implementation gives itself away: interpolating
    /// joint *positions* shortens a bone at the midpoint, so the limb appears to
    /// telescope. Interpolating angles cannot.
    @Test func limbsStayRigidMidRep() {
        let start = HumanoidPose(angles: [.upperArmL: [0, 0, 0], .forearmL: [0, 0, 0]])
        let end = HumanoidPose(angles: [.upperArmL: [0, 0, -170], .forearmL: [-150, 0, 0]])
        let upperArm = HumanoidRig.segments.first { $0.bone == .upperArmL }!

        for step in 0...10 {
            let pose = HumanoidPose.interpolate(start, end, Float(step) / 10)
            let joints = HumanoidRig.solve(pose)
            let measured = simd_length(joints[.upperArmL]! - joints[.shoulderL]!)
            #expect(abs(measured - upperArm.length) < 0.0005,
                    "upper arm telescoped to \(measured) at step \(step)")
        }
    }

    /// The root places and orients the whole figure, so a supine clip is
    /// authored upright and laid down here. If this drifts, every lying
    /// movement in the catalog is posed in the wrong frame.
    @Test func rootRotationLaysTheFigureDown() {
        let upright = HumanoidRig.solve(HumanoidPose())
        let supine = HumanoidRig.solve(HumanoidPose(rootRotation: [-90, 0, 0]))

        // Standing: the head is well above the pelvis. Supine: level with it.
        #expect(upright[.head]!.y - upright[.pelvis]!.y > 0.5)
        #expect(abs(supine[.head]!.y - supine[.pelvis]!.y) < 0.001)
        // ...and displaced along the depth axis instead.
        #expect(abs(supine[.head]!.z - supine[.pelvis]!.z) > 0.5)
    }
}

struct ExerciseClipTests {

    /// Lookup ignores punctuation and casing so "Pull-Up" in the catalog
    /// matches "pull up" from anywhere else.
    @Test func lookupNormalizesNames() {
        #expect(ExerciseMotion.clip(for: "Pull-Up") != nil)
        #expect(ExerciseMotion.clip(for: "pull up") != nil)
        #expect(ExerciseMotion.clip(for: "PULLUP") != nil)
        #expect(ExerciseMotion.clip(for: "Zercher Squat") == nil)
    }

    /// Every authored clip names a movement that actually exists in the
    /// library — a clip keyed to a name nobody has can never render.
    @MainActor
    @Test func authoredClipsMatchRealMovements() throws {
        let schema = Schema([Exercise.self, WorkoutSession.self, ExerciseSet.self,
                             PRRecord.self, Walk.self, Activity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        ExerciseCatalog.seedIfNeeded(context: context)
        let names = Set(
            ((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map(\.name)
        )
        #expect(ExerciseMotion.authoredCount > 0, "no clips loaded from the bundle")
        for name in ExerciseMotion.authoredNames {
            // A clip keyed to a name no movement has can never render, and
            // nothing else would ever surface it.
            #expect(names.contains(name), "\(name) is authored but not in the library")
        }
    }

    /// No limb crosses the midline of the body.
    ///
    /// This is the one class of error the rendered contact sheet cannot catch:
    /// a symmetric wireframe looks identical whether the arms are extended or
    /// crossed through the torso, so an inverted abduction sign passes visual
    /// review and ships with the weights on the wrong sides. Caught exactly
    /// that way once already.
    @Test func limbsNeverCrossTheMidline() throws {
        for name in ExerciseMotion.authoredNames {
            let clip = try #require(ExerciseMotion.clip(for: name))
            for step in 0...4 {
                let joints = HumanoidRig.solve(clip.pose(at: Float(step) / 4))
                guard let handL = joints[.forearmL], let handR = joints[.forearmR],
                      let footL = joints[.footL], let footR = joints[.footR]
                else { continue }
                // The left side stays left of the right side. A generous margin,
                // because a few movements legitimately bring the hands close
                // together in front of the chest.
                #expect(handL.x > handR.x - 0.02, "\(name): hands crossed at step \(step)")
                #expect(footL.x > footR.x - 0.02, "\(name): feet crossed at step \(step)")
            }
        }
    }

    /// A movement that raises the arms puts the hands *outside* the shoulders.
    /// Sign-inverted abduction still produces a plausible-looking horizontal
    /// line; it just produces one half the width, on the wrong sides.
    @Test func raisedArmsReachOutsideTheShoulders() throws {
        let clip = try #require(ExerciseMotion.clip(for: "Lateral Raise"))
        let joints = HumanoidRig.solve(clip.pose(at: 1))
        let shoulder = try #require(joints[.shoulderL]).x
        let hand = try #require(joints[.forearmL]).x
        #expect(hand > shoulder, "lateral raise hand (\(hand)) is inboard of the shoulder (\(shoulder))")
    }

    /// The ends of the rep are the authored keyframes exactly — easing shapes
    /// the travel between them, it must not soften the lockout or the bottom.
    @Test func keyframesAreReachedExactly() throws {
        let clip = try #require(ExerciseMotion.clip(for: "Barbell Curl"))
        let start = clip.pose(at: 0).angles[.forearmL]
        let end = clip.pose(at: 1).angles[.forearmL]
        #expect(start?.x == clip.keyframes.first?.angles[.forearmL]?.x)
        #expect(end?.x == clip.keyframes.last?.angles[.forearmL]?.x)
    }

    /// Easing is symmetric and monotonic: the figure slows at both ends the way
    /// a controlled rep does, without ever reversing mid-travel.
    @Test func easingIsMonotonicAndSlowsAtBothEnds() throws {
        let clip = try #require(ExerciseMotion.clip(for: "Barbell Curl"))
        let samples = stride(from: Float(0), through: 1, by: 0.05)
            .map { clip.pose(at: $0).angles[.forearmL]!.x }

        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(b <= a + 0.0001, "curl reversed mid-rep")
        }
        // First and last tenth cover less ground than the middle tenth.
        let head = abs(samples[1] - samples[0])
        let middle = abs(samples[10] - samples[9])
        let tail = abs(samples[samples.count - 1] - samples[samples.count - 2])
        #expect(head < middle)
        #expect(tail < middle)
    }
}

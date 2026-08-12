import SwiftUI
import simd

/// A movement, animated as a holographic figure.
///
/// Stylised rather than photoreal on purpose. A neon wireframe is cheaper to
/// produce, tints to whichever accent the lifter chose, and — the part that
/// matters — is forgiving of a joint angle that is a few degrees off, where a
/// photoreal human would land in the uncanny valley for the same error. It also
/// suits an obsidian-and-neon RPG app better than a rendered person would.
struct ExerciseFigureView: View {
    let clip: ExerciseClip
    /// Seconds for one full rep, down and back up.
    var period: Double = 2.6
    /// Whether the camera drifts. Off for thumbnails, on where the figure is
    /// the focus and the parallax sells the depth.
    var orbits: Bool = true

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time)
            }
        }
        .accessibilityHidden(true)
    }

    /// How far the camera drifts either side of the clip's base angle.
    private static let driftDegrees: Float = 9

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // Triangle wave: down on the way out, back on the way in, so one period
        // is a whole rep rather than a snap back to the start.
        let phase = (time.truncatingRemainder(dividingBy: period)) / period
        let progress = Float(phase < 0.5 ? phase * 2 : (1 - phase) * 2)
        let pose = clip.pose(at: progress)
        let joints = HumanoidRig.solve(pose)

        // A slow drift, not a spin: enough parallax to read as three-dimensional
        // without turning the movement into a turntable.
        let drift = orbits ? Float(sin(time * 0.28)) * Self.driftDegrees : 0
        let camera = Camera(azimuth: clip.azimuth + drift)
        let frame = framing(in: size)

        if let ground = clip.ground {
            drawGround(&context, camera: camera, frame: frame, height: ground)
        }
        drawEquipment(&context, camera: camera, frame: frame, joints: joints)
        drawSkeleton(&context, camera: camera, frame: frame, joints: joints)
    }

    // MARK: - Projection

    /// Perspective projection about the vertical axis, in scale-free units.
    /// Fitting to the view is `Framing`'s job, so the same camera can be
    /// measured before it is drawn with.
    private struct Camera {
        var azimuth: Float
        var distance: Float = 4.0
        var focal: Float = 2.6

        func normalized(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let a = azimuth * (.pi / 180)
            let x = p.x * cos(a) - p.z * sin(a)
            let z = p.x * sin(a) + p.z * cos(a)
            // Clamped so a joint that swings toward the camera can't divide
            // through zero and fling the figure off screen.
            let denom = max(0.2, distance - z)
            return SIMD2(x * focal / denom, p.y * focal / denom)
        }
    }

    /// Where the figure sits in the view, and how big.
    private struct Framing {
        var scale: Float
        var origin: CGPoint
    }

    /// Fits the movement to the view from its own bounds.
    ///
    /// A fixed origin and scale only ever suits one body orientation — tuned
    /// for a standing figure with its feet at the floor, a supine bench press
    /// renders small and adrift in the lower third. Measuring the pose instead
    /// means a clip frames itself correctly whatever its orientation, and a
    /// newly authored movement needs no layout tuning at all.
    ///
    /// The bounds cover both ends of the rep *and* both extremes of the camera
    /// drift, so the framing is constant while the figure moves. Measuring
    /// per-frame would rescale continuously and make the figure appear to
    /// breathe.
    private func framing(in size: CGSize) -> Framing {
        var minimum = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)

        let sweep: [Float] = orbits ? [-Self.driftDegrees, 0, Self.driftDegrees] : [0]
        for offset in sweep {
            let camera = Camera(azimuth: clip.azimuth + offset)
            // Ends and midpoint: an arcing limb can reach past both keyframes.
            for progress in [Float(0), 0.5, 1] {
                for point in extents(of: clip.pose(at: progress)) {
                    let projected = camera.normalized(point)
                    minimum = simd_min(minimum, projected)
                    maximum = simd_max(maximum, projected)
                }
            }
        }

        let span = simd_max(maximum - minimum, SIMD2(0.001, 0.001))
        let scale = min(Float(size.width) / span.x, Float(size.height) / span.y) * 0.86
        let centre = (minimum + maximum) / 2
        return Framing(
            scale: scale,
            origin: CGPoint(
                x: size.width / 2 - CGFloat(centre.x * scale),
                y: size.height / 2 + CGFloat(centre.y * scale)
            )
        )
    }

    /// Every point that has to stay on screen: the skeleton, plus whatever
    /// equipment and floor the clip draws. Leaving the props out lets a
    /// pull-up bar or a barbell hang off the edge of the view.
    private func extents(of pose: HumanoidPose) -> [SIMD3<Float>] {
        var points = Array(HumanoidRig.solve(pose).values)

        switch clip.equipment {
        case .none, .dumbbells:
            break
        case .barbell:
            let joints = HumanoidRig.solve(pose)
            if let left = joints[.forearmL], let right = joints[.forearmR] {
                let axis = right - left
                points.append(left - axis * 0.55)
                points.append(right + axis * 0.55)
            }
        case .barbellOnBack:
            if let neck = HumanoidRig.solve(pose)[.neck] {
                points.append(neck + SIMD3(-0.55, 0, -0.04))
                points.append(neck + SIMD3(0.55, 0, -0.04))
            }
        case .fixedBar(let height):
            points.append(SIMD3(-0.55, height, 0))
            points.append(SIMD3(0.55, height, 0))
        }

        if let ground = clip.ground {
            points.append(SIMD3(-0.55, ground, 0))
            points.append(SIMD3(0.55, ground, 0))
        }
        return points
    }

    private func place(_ point: SIMD3<Float>, _ camera: Camera, _ frame: Framing) -> CGPoint {
        let n = camera.normalized(point)
        return CGPoint(
            x: frame.origin.x + CGFloat(n.x * frame.scale),
            y: frame.origin.y - CGFloat(n.y * frame.scale)
        )
    }

    // MARK: - Drawing

    private func drawSkeleton(
        _ context: inout GraphicsContext,
        camera: Camera,
        frame: Framing,
        joints: [HumanoidRig.Bone: SIMD3<Float>]
    ) {
        var bones = Path()
        for segment in HumanoidRig.segments {
            guard let a = joints[segment.parent], let b = joints[segment.bone] else { continue }
            bones.move(to: place(a, camera, frame))
            bones.addLine(to: place(b, camera, frame))
        }

        // Wide, faint pass under the crisp one: a cheap bloom that reads as
        // emitted light rather than a drawn outline.
        context.stroke(bones, with: .color(Theme.teal.opacity(0.20)),
                       style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        context.stroke(bones, with: .color(Theme.teal.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

        for (bone, position) in joints where bone != .head {
            let point = place(position, camera, frame)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                with: .color(Theme.emerald)
            )
        }
        if let head = joints[.head] {
            let point = place(head, camera, frame)
            let radius = max(9, CGFloat(frame.scale) * 0.055)
            let box = CGRect(x: point.x - radius, y: point.y - radius,
                             width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: box.insetBy(dx: -5, dy: -5)),
                         with: .color(Theme.emerald.opacity(0.22)))
            context.fill(Path(ellipseIn: box), with: .color(Theme.emerald))
        }
    }

    private func drawEquipment(
        _ context: inout GraphicsContext,
        camera: Camera,
        frame: Framing,
        joints: [HumanoidRig.Bone: SIMD3<Float>]
    ) {
        let stroke = StrokeStyle(lineWidth: 5, lineCap: .round)
        let gold = GraphicsContext.Shading.color(Theme.gold.opacity(0.95))

        switch clip.equipment {
        case .none:
            break

        case .barbell:
            // Spans the grip and overhangs it, so the bar tracks the hands
            // through the rep instead of floating at a fixed height.
            guard let left = joints[.forearmL], let right = joints[.forearmR] else { return }
            let axis = right - left
            var path = Path()
            path.move(to: place(left - axis * 0.55, camera, frame))
            path.addLine(to: place(right + axis * 0.55, camera, frame))
            context.stroke(path, with: gold, style: stroke)

        case .barbellOnBack:
            // Racked on the traps: anchored to the neck, not the hands, or it
            // would swing with the arms during a squat.
            guard let neck = joints[.neck] else { return }
            var path = Path()
            path.move(to: place(neck + SIMD3(-0.55, 0, -0.04), camera, frame))
            path.addLine(to: place(neck + SIMD3(0.55, 0, -0.04), camera, frame))
            context.stroke(path, with: gold, style: stroke)

        case .dumbbells:
            for bone in [HumanoidRig.Bone.forearmL, .forearmR] {
                guard let hand = joints[bone] else { continue }
                let point = place(hand, camera, frame)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)),
                    with: gold
                )
            }

        case .fixedBar(let height):
            // World-anchored. The body travels to it, which is the whole point
            // of a pull-up and the thing a hand-attached prop gets wrong.
            var path = Path()
            path.move(to: place(SIMD3(-0.55, height, 0), camera, frame))
            path.addLine(to: place(SIMD3(0.55, height, 0), camera, frame))
            context.stroke(path, with: gold, style: stroke)
        }
    }

    private func drawGround(
        _ context: inout GraphicsContext,
        camera: Camera,
        frame: Framing,
        height: Float
    ) {
        // Drawn as a cross: a single line along one axis vanishes to a dot when
        // the camera looks down it, which is exactly the side-on view a bench
        // press uses.
        var path = Path()
        path.move(to: place(SIMD3(-0.55, height, 0), camera, frame))
        path.addLine(to: place(SIMD3(0.55, height, 0), camera, frame))
        path.move(to: place(SIMD3(0, height, -0.75), camera, frame))
        path.addLine(to: place(SIMD3(0, height, 0.75), camera, frame))
        context.stroke(path, with: .color(Theme.cobalt.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

// MARK: - Banner integration

/// The movement's illustration: the animated figure when one has been authored,
/// the bundled photo when it hasn't, and the muscle-group symbol when there is
/// neither. Adding a tier at the top means the catalog can fill in one movement
/// at a time without any screen needing to know.
struct ExerciseVisual: View {
    let exercise: Exercise
    var height: CGFloat
    var blendsIntoBackground: Bool = false

    var body: some View {
        if let clip = ExerciseMotion.clip(for: exercise.name) {
            ExerciseFigureView(clip: clip)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Theme.surface.opacity(0.35))
                .modifier(FigureBlend(isOn: blendsIntoBackground))
        } else {
            ExerciseImageBanner(
                exercise: exercise,
                height: height,
                blendsIntoBackground: blendsIntoBackground
            )
        }
    }
}

/// Matches `ExerciseImageBanner`'s bottom fade so swapping tiers doesn't change
/// how the banner meets the screen behind it.
private struct FigureBlend: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.55),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            content
        }
    }
}

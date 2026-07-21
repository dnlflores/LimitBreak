import SwiftUI

/// Animated launch screen recreating the app icon: a diamond of smoky glass
/// cubes assembling around a glowing gold-violet core, mirrored on an obsidian
/// floor. Plays once at cold start, then dissolves into the app.
struct LaunchSplashView: View {
    let onFinished: () -> Void

    @State private var assembled = false
    @State private var ignited = false
    @State private var showWordmark = false

    var body: some View {
        ZStack {
            Theme.canvas
                .ignoresSafeArea()

            Starfield()
                .opacity(assembled ? 1 : 0)
                .animation(.easeIn(duration: 1.2), value: assembled)

            VStack(spacing: 36) {
                cubeCluster
                    .frame(width: 280, height: 280)

                VStack(spacing: 10) {
                    Text("LIMITBREAK")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .kerning(5)
                        .foregroundStyle(Theme.limitBreakGradient)
                        .shadow(color: Theme.violet.opacity(0.6), radius: 14)

                    Text("BREAK YOUR CEILING")
                        .font(.caption.weight(.semibold))
                        .kerning(3)
                        .foregroundStyle(Theme.textDim)
                }
                .opacity(showWordmark ? 1 : 0)
                .offset(y: showWordmark ? 0 : 18)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: showWordmark)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onFinished() } // impatient lifters can skip
        .onAppear { assembled = true }
        .task {
            try? await Task.sleep(for: .milliseconds(950))
            ignited = true
            Haptics.shared.tick()
            try? await Task.sleep(for: .milliseconds(350))
            showWordmark = true
            try? await Task.sleep(for: .milliseconds(1500))
            onFinished()
        }
    }

    // MARK: - Cube cluster

    /// 3×3 isometric diamond, rendered back-to-front; the center cube is the core.
    private var cubeCluster: some View {
        let cubeWidth: CGFloat = 72
        let spacing: CGFloat = 1.32

        return ZStack {
            // Core bloom behind everything once ignited.
            RadialGradient(
                colors: [Theme.gold.opacity(0.55), Theme.violet.opacity(0.35), .clear],
                center: .center, startRadius: 4, endRadius: 150
            )
            .opacity(ignited ? 1 : 0)
            .scaleEffect(ignited ? 1 : 0.4)
            .animation(.easeOut(duration: 0.7), value: ignited)

            ForEach(cubePositions, id: \.order) { cube in
                IsoCubeView(width: cubeWidth, isCore: cube.isCore, ignited: ignited)
                    .offset(
                        x: cube.x * cubeWidth / 2 * spacing,
                        y: cube.y * cubeWidth / 4 * spacing - 20
                    )
                    .opacity(assembled ? 1 : 0)
                    .scaleEffect(assembled ? 1 : 0.6, anchor: .center)
                    .offset(y: assembled ? 0 : -46)
                    .animation(
                        .spring(response: 0.55, dampingFraction: 0.72)
                            .delay(0.12 + cube.depth * 0.13),
                        value: assembled
                    )
            }
        }
        // Glossy floor: a soft mirrored glow pooling beneath the cluster.
        .background(alignment: .bottom) {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Theme.violet.opacity(0.30), Theme.gold.opacity(0.12), .clear],
                        center: .center, startRadius: 2, endRadius: 130
                    )
                )
                .frame(width: 260, height: 70)
                .blur(radius: 12)
                .offset(y: 46)
                .opacity(ignited ? 1 : 0)
                .animation(.easeIn(duration: 0.8), value: ignited)
        }
    }

    /// Grid coordinates → screen-space diamond. `depth` staggers the entrance
    /// so the cluster builds from the back corner forward.
    private struct CubeSlot {
        let order: Int
        let x: CGFloat   // (col - row)
        let y: CGFloat   // (col + row), centered
        let depth: Double
        let isCore: Bool
    }

    private var cubePositions: [CubeSlot] {
        var slots: [CubeSlot] = []
        var order = 0
        for row in 0..<3 {
            for col in 0..<3 {
                // Draw order: back-to-front so nearer cubes overlap farther ones.
                slots.append(CubeSlot(
                    order: order,
                    x: CGFloat(col - row),
                    y: CGFloat(col + row) - 2,
                    depth: Double(col + row) * 0.5,
                    isCore: col == 1 && row == 1
                ))
                order += 1
            }
        }
        return slots.sorted { $0.depth < $1.depth }
    }
}

// MARK: - Isometric cube

/// One glass cube in dimetric projection: a top rhombus and two visible faces.
/// The core cube ignites with the gold-violet LimitBreak energy.
private struct IsoCubeView: View {
    let width: CGFloat
    let isCore: Bool
    let ignited: Bool

    @State private var pulsing = false

    private var height: CGFloat { width / 2 + width * 0.55 }

    var body: some View {
        ZStack {
            CubeFaceShape(face: .left)
                .fill(leftFill)
                .overlay(CubeFaceShape(face: .left).stroke(edgeColor, lineWidth: 1))
            CubeFaceShape(face: .right)
                .fill(rightFill)
                .overlay(CubeFaceShape(face: .right).stroke(edgeColor, lineWidth: 1))
            CubeFaceShape(face: .top)
                .fill(topFill)
                .overlay(CubeFaceShape(face: .top).stroke(edgeColor.opacity(1.4), lineWidth: 1))
        }
        .frame(width: width, height: height)
        .shadow(
            color: isCore && ignited ? Theme.gold.opacity(pulsing ? 0.9 : 0.45) : .clear,
            radius: pulsing ? 26 : 12
        )
        .onChange(of: ignited) { _, nowIgnited in
            guard isCore, nowIgnited else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    // MARK: Face materials

    private var edgeColor: Color {
        isCore && ignited ? Theme.gold.opacity(0.55) : .white.opacity(0.28)
    }

    private var topFill: LinearGradient {
        if isCore && ignited {
            return LinearGradient(
                colors: [Color.white.opacity(0.85), Theme.gold.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var leftFill: LinearGradient {
        if isCore && ignited {
            return LinearGradient(
                colors: [Theme.violet.opacity(0.95), Theme.violet.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.09, blue: 0.16).opacity(0.92),
                Theme.violet.opacity(0.22),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var rightFill: LinearGradient {
        if isCore && ignited {
            return LinearGradient(
                colors: [Theme.gold.opacity(0.9), Color(red: 0.85, green: 0.45, blue: 0.15).opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.13, green: 0.11, blue: 0.10).opacity(0.92),
                Theme.gold.opacity(0.18),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Dimetric cube faces. The bounding rect is (w, w/2 + cubeHeight); the top
/// rhombus occupies the first w/2, the side faces hang below it.
private struct CubeFaceShape: Shape {
    enum Face { case top, left, right }
    let face: Face

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let topH = w / 2
        let sideH = rect.height - topH

        let top = CGPoint(x: rect.midX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.minY + topH / 2)
        let bottom = CGPoint(x: rect.midX, y: rect.minY + topH)
        let left = CGPoint(x: rect.minX, y: rect.minY + topH / 2)

        var path = Path()
        switch face {
        case .top:
            path.move(to: top)
            path.addLine(to: right)
            path.addLine(to: bottom)
            path.addLine(to: left)
        case .left:
            path.move(to: left)
            path.addLine(to: bottom)
            path.addLine(to: CGPoint(x: bottom.x, y: bottom.y + sideH))
            path.addLine(to: CGPoint(x: left.x, y: left.y + sideH))
        case .right:
            path.move(to: bottom)
            path.addLine(to: right)
            path.addLine(to: CGPoint(x: right.x, y: right.y + sideH))
            path.addLine(to: CGPoint(x: bottom.x, y: bottom.y + sideH))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Starfield

/// Sparse drifting specks, like the bokeh dust in the icon background.
private struct Starfield: View {
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let brightness: Double
    }

    private static func makeStars() -> [Star] {
        var stars: [Star] = []
        for index in 0..<22 {
            stars.append(Star(
                x: CGFloat((index * 47) % 100) / 100,
                y: CGFloat((index * 31 + 13) % 100) / 100,
                size: 1.5 + CGFloat((index * 7) % 4),
                brightness: 0.15 + Double((index * 11) % 30) / 100
            ))
        }
        return stars
    }

    private let stars: [Star] = Starfield.makeStars()

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(stars.enumerated()), id: \.offset) { _, star in
                Circle()
                    .fill(Color.white.opacity(star.brightness))
                    .frame(width: star.size, height: star.size)
                    .blur(radius: star.size > 3 ? 1.5 : 0.5)
                    .position(x: star.x * geo.size.width, y: star.y * geo.size.height)
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    LaunchSplashView {}
}

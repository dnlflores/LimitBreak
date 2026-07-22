import SwiftUI

/// LimitBreak's visual language: "Obsidian Liquid Glass".
/// A deep obsidian mesh canvas, floating glass surfaces with light-refracting
/// borders, and neon accent lighting for interactive states.
enum Theme {
    // MARK: - Canvas

    /// Deep obsidian. #0B0E14
    static let background = Color(red: 0.043, green: 0.055, blue: 0.078)
    /// Obsidian fading toward cobalt. #121824
    static let backgroundDeep = Color(red: 0.071, green: 0.094, blue: 0.141)

    /// The obsidian mesh the whole app floats on: dark glass with faint
    /// cobalt and violet blooms so the material surfaces have light to refract.
    static var canvas: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                background, backgroundDeep, background,
                backgroundDeep, Color(red: 0.075, green: 0.105, blue: 0.185), backgroundDeep,
                Color(red: 0.085, green: 0.075, blue: 0.150), backgroundDeep, background,
            ]
        )
    }

    // MARK: - Glass tones

    /// Deep cobalt: neutral glass / inactive state.
    static let cobalt = Color(red: 0.18, green: 0.28, blue: 0.55)
    static let surface = Color(red: 0.082, green: 0.102, blue: 0.141)
    /// Raised glass tone for inset chips and fields (cobalt-tinted).
    static let surfaceRaised = Color(red: 0.13, green: 0.17, blue: 0.28).opacity(0.85)
    static let stroke = Color.white.opacity(0.10)

    /// 1px light-refracting border for floating glass surfaces.
    static let glassBorder = LinearGradient(
        colors: [Color.white.opacity(0.15), Color.clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Interactive accents

    /// Cyber teal: fully rested / target muscle ready.
    static let teal = Color(red: 0.16, green: 0.86, blue: 0.82)
    /// Emerald: activity, go-states.
    static let emerald = Color(red: 0.20, green: 0.84, blue: 0.50)
    /// Solar violet: LimitBreak energy.
    static let violet = Color(red: 0.58, green: 0.40, blue: 1.0)
    /// Electric gold: PR breakthrough.
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.20)
    /// Muted crimson: high muscle fatigue.
    static let crimson = Color(red: 0.83, green: 0.30, blue: 0.32)
    /// Coral: active recovery period.
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.42)
    static let textDim = Color.white.opacity(0.55)

    static let limitBreakGradient = LinearGradient(
        colors: [gold, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    /// The obsidian mesh canvas behind every screen.
    func obsidianBackground() -> some View {
        background { Theme.canvas.ignoresSafeArea() }
    }

    /// A floating glass card: dynamic blur material framed by a
    /// light-refracting gradient border.
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    /// A prominent call-to-action rendered in tinted, interactive Liquid Glass.
    func glassCTA(tint: Color, cornerRadius: CGFloat = 16) -> some View {
        glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
    }

    /// An untinted interactive Liquid Glass surface for secondary controls.
    func glassControl(cornerRadius: CGFloat = 14) -> some View {
        glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }

    /// A circular interactive Liquid Glass surface for icon buttons in headers.
    func glassCircle(diameter: CGFloat = 44) -> some View {
        self
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    func statNumberStyle() -> some View {
        self
            .font(.system(.title2, design: .rounded, weight: .bold))
            .monospacedDigit()
    }
}

extension MuscleGroup {
    /// SF Symbol used wherever a movement is shown as a card.
    var iconName: String {
        switch self {
        case .chest: "figure.arms.open"
        case .lats: "figure.rower"
        case .quads, .hamstrings: "figure.strengthtraining.functional"
        case .deltoids: "figure.arms.open"
        case .triceps, .biceps, .forearms: "dumbbell.fill"
        case .core: "figure.core.training"
        case .calves: "figure.walk"
        case .glutes: "figure.squat"
        }
    }
}

extension Double {
    /// "225" or "227.5" — drops the trailing .0 for whole numbers.
    var cleanWeight: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", self)
            : String(format: "%.1f", self)
    }
}

extension TimeInterval {
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

import SwiftUI
import UIKit

/// A user-selectable accent theme. Recolors the app's primary interactive
/// accent, the brand "LimitBreak" energy, and the obsidian canvas glow.
/// The semantic status colors (rested / recovering / fatigued / PR) stay fixed
/// across every theme so the recovery diagrams and charts remain readable.
enum AppTheme: String, CaseIterable, Identifiable {
    case emerald
    case violet
    case teal
    case gold
    case coral
    case crimson

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emerald: "Emerald"
        case .violet:  "Solar Violet"
        case .teal:    "Cyber Teal"
        case .gold:    "Solar Gold"
        case .coral:   "Coral"
        case .crimson: "Crimson"
        }
    }

    /// Primary interactive accent: tab bar, CTAs, and selection highlights.
    /// (`Emerald` reproduces the app's original accent exactly.)
    var accent: Color {
        switch self {
        case .emerald: Color(red: 0.20, green: 0.84, blue: 0.50)
        case .violet:  Color(red: 0.58, green: 0.40, blue: 1.0)
        case .teal:    Color(red: 0.16, green: 0.86, blue: 0.82)
        case .gold:    Color(red: 1.0,  green: 0.78, blue: 0.28)
        case .coral:   Color(red: 1.0,  green: 0.52, blue: 0.42)
        case .crimson: Color(red: 0.92, green: 0.34, blue: 0.40)
        }
    }

    /// Brand "LimitBreak energy": the second stop of the limit-break gradient
    /// and other high-energy accents. Paired to complement `accent`.
    var energy: Color {
        switch self {
        case .emerald: Color(red: 0.58, green: 0.40, blue: 1.0)
        case .violet:  Color(red: 0.90, green: 0.42, blue: 0.95)
        case .teal:    Color(red: 0.34, green: 0.62, blue: 1.0)
        case .gold:    Color(red: 1.0,  green: 0.48, blue: 0.30)
        case .coral:   Color(red: 1.0,  green: 0.36, blue: 0.66)
        case .crimson: Color(red: 0.74, green: 0.24, blue: 0.86)
        }
    }

    /// Two blooms tinted into the obsidian mesh so the glass has themed light to
    /// refract. Kept deliberately dark so the canvas stays obsidian, not vivid.
    var canvasBlooms: (center: Color, corner: Color) {
        switch self {
        case .emerald: (Color(red: 0.075, green: 0.105, blue: 0.185), Color(red: 0.085, green: 0.075, blue: 0.150))
        case .violet:  (Color(red: 0.095, green: 0.075, blue: 0.170), Color(red: 0.110, green: 0.070, blue: 0.150))
        case .teal:    (Color(red: 0.055, green: 0.115, blue: 0.150), Color(red: 0.060, green: 0.095, blue: 0.150))
        case .gold:    (Color(red: 0.120, green: 0.095, blue: 0.070), Color(red: 0.110, green: 0.070, blue: 0.075))
        case .coral:   (Color(red: 0.130, green: 0.080, blue: 0.080), Color(red: 0.110, green: 0.070, blue: 0.095))
        case .crimson: (Color(red: 0.130, green: 0.070, blue: 0.080), Color(red: 0.105, green: 0.065, blue: 0.105))
        }
    }
}

/// Holds the selected accent theme and persists it. Because `Theme`'s themed
/// colors read `ThemeManager.shared.theme` during view `body` evaluation,
/// SwiftUI's observation invalidates exactly the views that use those colors —
/// so changing the theme recolors the whole app live, without a tree rebuild.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private static let storageKey = "appAccentTheme"

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        theme = raw.flatMap(AppTheme.init(rawValue:)) ?? .emerald
    }
}

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
    /// accent blooms (themed) so the material surfaces have light to refract.
    static var canvas: some View {
        let blooms = ThemeManager.shared.theme.canvasBlooms
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                background, backgroundDeep, background,
                backgroundDeep, blooms.center, backgroundDeep,
                blooms.corner, backgroundDeep, background,
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
    /// Primary interactive accent (tab bar, CTAs, selection). Themed — follows
    /// the accent chosen in Settings; `Emerald` is the original app color.
    static var emerald: Color { ThemeManager.shared.theme.accent }
    /// Brand "LimitBreak energy". Themed — the second stop of the limit-break
    /// gradient and other energy accents; `Emerald`'s pairing is solar violet.
    static var violet: Color { ThemeManager.shared.theme.energy }
    /// Electric gold: PR breakthrough.
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.20)
    /// Muted crimson: high muscle fatigue.
    static let crimson = Color(red: 0.83, green: 0.30, blue: 0.32)
    /// Coral: active recovery period.
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.42)
    static let textDim = Color.white.opacity(0.55)

    static var limitBreakGradient: LinearGradient {
        LinearGradient(
            colors: [gold, violet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
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
        case .traps: "figure.strengthtraining.traditional"
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

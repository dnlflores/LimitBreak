import SwiftUI

/// Metrics and shared chrome for LimitBreak's iPad layouts.
///
/// The iPad build isn't a stretched phone: every tab has a purpose-built
/// regular-width layout that spreads the same data across columns instead of
/// one long scroll. These are the constants and containers those layouts share
/// so the whole app reads as one dashboard system.
enum PadLayout {
    /// Gap between dashboard panels.
    static let gutter: CGFloat = 20
    /// Width of the fixed right-hand rail on the dashboard-style tabs.
    static let railWidth: CGFloat = 360
    /// Below this a two-column layout folds into one, so Split View, Stage
    /// Manager and iPad mini portrait still read as a dashboard rather than a
    /// squeeze.
    static let twoColumnMinWidth: CGFloat = 980
    /// Outer margin around a full-screen iPad layout.
    static let screenPadding: CGFloat = 24
    /// Breathing room under the last panel in a scrolling column.
    static let scrollBottomInset: CGFloat = 32
}

// MARK: - Size-class gate

extension EnvironmentValues {
    /// True when the app has iPad-class room to work with. Reads the horizontal
    /// size class rather than the idiom so a narrow Split View window correctly
    /// falls back to the phone layout.
    var hasRegularWidth: Bool { horizontalSizeClass == .regular }
}

/// Applies `.sidebarAdaptable` only on regular width — the floating tab bar
/// expands into a sidebar on iPad while the phone keeps its bottom tab bar.
struct AdaptiveTabViewStyle: ViewModifier {
    let isRegular: Bool

    func body(content: Content) -> some View {
        if isRegular {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

// MARK: - Panel

/// A dashboard panel: a titled sheet of glass with an optional trailing
/// accessory. The iPad counterpart to `cardStyle()`, sized for a screen that
/// shows several at once.
struct PadPanel<Content: View, Accessory: View>: View {
    private let title: String?
    private let content: Content
    private let accessory: Accessory

    init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .kerning(1.6)
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

extension PadPanel where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Screen header

/// The title bar every iPad tab wears: an oversized title, a one-line
/// orientation subtitle, and room for controls on the right.
struct PadScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 2)
    }
}

/// A circular glass control for a screen header.
struct PadIconButton: View {
    let systemName: String
    var tint: Color = Theme.textDim
    var accessibilityName: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.tick()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(tint)
                .glassCircle(diameter: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
    }
}

// MARK: - Stat tile

/// One number in a dashboard's headline band.
struct PadStatTile: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color
    var action: (() -> Void)?

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(1.1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(tint.opacity(0.22), lineWidth: 1))

        if let action {
            Button {
                Haptics.shared.tick()
                action()
            } label: {
                tile.contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        } else {
            tile
        }
    }
}

// MARK: - Empty pane

/// The placeholder a split view's detail column shows before anything is
/// picked — an invitation rather than a blank slab.
struct PadEmptyPane: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 68))
                .foregroundStyle(Theme.limitBreakGradient)
            Text(title)
                .font(.title2.weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search field

/// The glass search field shared by the iPad list columns.
struct PadSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }
}

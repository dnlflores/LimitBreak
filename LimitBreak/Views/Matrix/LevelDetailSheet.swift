import SwiftUI

// MARK: - Shared level visuals

/// The level emblem: a star-edged seal in LimitBreak energy with the level
/// number stamped on it. One badge, no progress ring — the XP bar owns that.
struct LevelSealBadge: View {
    let level: Int
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            Image(systemName: "seal.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.limitBreakGradient)
                .shadow(color: Theme.gold.opacity(0.35), radius: 10)
            VStack(spacing: -2) {
                Text("LV")
                    .font(.system(size: size * 0.16, weight: .black))
                    .foregroundStyle(.black.opacity(0.6))
                Text("\(level)")
                    .font(.system(size: size * 0.38, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
            }
        }
    }
}

/// The one true XP progress bar.
struct XPProgressBar: View {
    let progress: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Theme.limitBreakGradient)
                    .frame(width: max(height, geo.size.width * progress))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Hero sheet

/// The character sheet: name, level seal, rank, XP bar, and the road to the
/// next title.
struct LevelDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("heroName") private var heroName = ""
    @FocusState private var nameFocused: Bool

    let info: XPEngine.LevelInfo

    private var nextRank: (title: String, level: Int)? {
        XPEngine.nextRank(after: info.level)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                }

                LevelSealBadge(level: info.level, size: 96)

                TextField("Name your hero", text: $heroName)
                    .focused($nameFocused)
                    .multilineTextAlignment(.center)
                    .font(.title2.bold())
                    .submitLabel(.done)
                    .padding(.vertical, 6)
                    .overlay(alignment: .trailing) {
                        if !nameFocused && heroName.isEmpty {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    }

                Text(XPEngine.rankTitle(for: info.level).uppercased())
                    .font(.headline.weight(.black))
                    .kerning(2)
                    .foregroundStyle(Theme.limitBreakGradient)

                VStack(spacing: 8) {
                    XPProgressBar(progress: info.progress, height: 10)
                    Text("\(info.xpIntoLevel.formatted()) / \(info.xpForNext.formatted()) XP to LV \(info.level + 1)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }
                .cardStyle()

                statRow(
                    icon: "star.circle.fill",
                    tint: Theme.gold,
                    label: "Total XP earned",
                    value: info.totalXP.formatted()
                )

                if let nextRank {
                    statRow(
                        icon: "crown.fill",
                        tint: Theme.violet,
                        label: "Next title",
                        value: "\(nextRank.title) \u{00B7} LV \(nextRank.level)"
                    )
                } else {
                    statRow(
                        icon: "crown.fill",
                        tint: Theme.gold,
                        label: "Next title",
                        value: "Max rank \u{2014} you ARE the raid boss"
                    )
                }
            }
            .padding()
        }
        .obsidianBackground()
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func statRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
        }
        .cardStyle()
    }
}

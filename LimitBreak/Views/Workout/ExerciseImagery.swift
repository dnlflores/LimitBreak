import SwiftUI

// MARK: - Exercise imagery

/// Bundled illustration lookup for a movement, plus reusable image views.
///
/// Art ships as asset-catalog images named after the movement's `imageAssetName`
/// slug (e.g. "Barbell Bench Press" → `exercise-barbell-bench-press`). Any
/// movement without a matching asset — custom exercises, or anything not yet
/// illustrated — falls back to its muscle-group SF Symbol, so the UI is always
/// populated and photos simply light up as assets are added.
extension Exercise {
    /// Asset-catalog name an artist can target for this movement's illustration.
    /// Stable, derived only from the name: lowercased, `&` spelled out, and every
    /// run of non-alphanumeric characters collapsed to a single hyphen.
    var imageAssetName: String {
        let lowered = name.lowercased().replacingOccurrences(of: "&", with: " and ")
        var slug = ""
        var lastWasHyphen = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "exercise-\(slug)"
    }

    /// The bundled illustration for this movement, or nil when none is shipped.
    var exampleImage: Image? {
        UIImage(named: imageAssetName).map { Image(uiImage: $0) }
    }
}

/// A full-width illustration banner for a movement, filling its height and
/// falling back to the muscle-group symbol. When `blendsIntoBackground` is set,
/// the image fades out along its bottom edge so it dissolves into the screen
/// canvas behind it — used at the very top of the log sheet.
struct ExerciseImageBanner: View {
    let exercise: Exercise
    var height: CGFloat
    var blendsIntoBackground: Bool = false

    var body: some View {
        image
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .modifier(BackgroundBlend(isOn: blendsIntoBackground))
    }

    @ViewBuilder
    private var image: some View {
        if let image = exercise.exampleImage {
            image
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Theme.surfaceRaised
                Image(systemName: exercise.muscleGroup.iconName)
                    .font(.system(size: height * 0.3, weight: .semibold))
                    .foregroundStyle(Theme.teal.opacity(0.7))
            }
        }
    }
}

/// Fades a view's lower portion to transparent so it dissolves into whatever is
/// behind it (the obsidian canvas), rather than ending on a hard edge.
private struct BackgroundBlend: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.55),
                        .init(color: .clear, location: 1.0)
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

/// Compact, tinted capsule naming the muscle a movement targets — text only.
struct MuscleBadge: View {
    let exercise: Exercise

    var body: some View {
        Text(exercise.muscleGroupDisplay.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Theme.teal)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.teal.opacity(0.4), lineWidth: 1))
    }
}

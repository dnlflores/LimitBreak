import SwiftUI

/// The "are you training with someone?" question, as a two-option choice rather
/// than a switch — a session is explicitly solo or explicitly partnered, and the
/// answer changes what the AI is willing to load on the bar.
struct PartnerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            option(label: "Solo", icon: "person.fill", selected: !isOn) { isOn = false }
            option(label: "With Partner", icon: "person.2.fill", selected: isOn) { isOn = true }
        }
    }

    private func option(
        label: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.shared.tick()
        } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(selected ? .black : .white)
                .background(
                    selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Read-only "trained with a partner" marker for history rows and battle
/// reports. Renders nothing for solo sessions so the common case stays quiet.
struct PartnerBadge: View {
    let trainedWithPartner: Bool
    var compact = false

    var body: some View {
        if trainedWithPartner {
            if compact {
                Image(systemName: "person.2.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.teal)
                    .accessibilityLabel("Trained with a partner")
            } else {
                Label("With partner", systemImage: "person.2.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.teal.opacity(0.12), in: Capsule())
            }
        }
    }
}

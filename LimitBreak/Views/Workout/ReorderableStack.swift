import SwiftUI
import Observation

/// A vertical stack whose rows can be dragged into a new order by a grip handle.
///
/// SwiftUI only offers `.onMove` on `List`, but the training screens are custom
/// glass cards inside a `ScrollView` — dropping them into a `List` would cost
/// the whole look. This reorders in place instead: rows swap live as you drag
/// past their midpoints, so the stack always shows the order you'd get if you
/// let go right now.
///
/// The caller decides where the grip sits, so it can slot into each card's
/// existing header rather than forcing a gutter:
///
///     ReorderableVStack($entries, spacing: 14) { $entry, grip in
///         card($entry, grip: grip)
///     }
///
/// ## Performance
///
/// A finger drag fires `onChanged` on every frame, and the rows here are heavy
/// glass cards (`ExerciseLogCard` observes the whole workout, recomputes 1RM,
/// blurs its background). Two things keep that smooth:
///
/// 1. **The live drag values live on an `@Observable` `ReorderCoordinator`.**
///    SwiftUI tracks `@Observable` reads per view *and* per property, so a
///    resting `ReorderableRow` reads only `draggingID` and short-circuits the
///    `isDragging` ternary before it ever touches `translation`. Only the single
///    lifted row re-runs each frame; the parent `body` reads none of it.
/// 2. **The grip carries only stable values — the coordinator reference and the
///    row's id, never a fresh closure.** If the grip held per-frame closures,
///    SwiftUI would see the card's `grip` property change every frame and
///    re-run the entire card body. With a stable grip the card's value is
///    identical frame-to-frame, so SwiftUI skips its body and merely slides the
///    already-rendered layer with the new `.offset`.
struct ReorderableVStack<Item: Identifiable, Row: View>: View {
    @Binding var items: [Item]
    var spacing: CGFloat
    @ViewBuilder var row: (Binding<Item>, ReorderGrip) -> Row

    init(
        _ items: Binding<[Item]>,
        spacing: CGFloat = 14,
        @ViewBuilder row: @escaping (Binding<Item>, ReorderGrip) -> Row
    ) {
        self._items = items
        self.spacing = spacing
        self.row = row
    }

    @State private var coordinator = ReorderCoordinator()

    var body: some View {
        VStack(spacing: spacing) {
            ForEach($items) { $item in
                ReorderableRow(
                    id: AnyHashable(item.id),
                    coordinator: coordinator
                ) { grip in
                    row($item, grip)
                }
            }
        }
        // Install the typed reorder logic once. The closures capture the items
        // binding by value (it routes to the same source of truth for the view's
        // lifetime) and the coordinator weakly, so there's no `self` capture and
        // no reference cycle with the coordinator that stores them.
        .onAppear { installHandlers() }
    }

    private func installHandlers() {
        let items = $items
        let spacing = spacing
        coordinator.spacing = spacing

        coordinator.updateHandler = { [weak coordinator] id, newTranslation in
            guard let coordinator else { return }
            if coordinator.draggingID != id {
                coordinator.draggingID = id
                coordinator.absorbed = 0
                Haptics.shared.tick()
            }
            coordinator.translation = newTranslation
            settleSwaps(id: id, items: items, spacing: spacing, coordinator: coordinator)
        }

        coordinator.endHandler = { [weak coordinator] in
            guard let coordinator else { return }
            withAnimation(.spring(duration: 0.3)) {
                coordinator.draggingID = nil
                coordinator.translation = 0
                coordinator.absorbed = 0
            }
        }
    }
}

/// Swaps the dragged row past any neighbour whose midpoint it has crossed.
/// Loops rather than swapping once, so a fast flick doesn't get left behind.
/// Each pass either exits or moves `absorbed` closer to `translation`, so it
/// always terminates. Free function so the coordinator's stored handler needn't
/// capture the view (`self`) and risk a reference cycle.
private func settleSwaps<Item: Identifiable>(
    id: AnyHashable,
    items: Binding<[Item]>,
    spacing: CGFloat,
    coordinator: ReorderCoordinator
) {
    while let index = items.wrappedValue.firstIndex(where: { AnyHashable($0.id) == id }) {
        let visual = coordinator.translation - coordinator.absorbed
        let neighbour = visual > 0 ? index + 1 : index - 1
        guard items.wrappedValue.indices.contains(neighbour) else { return }
        // A row that hasn't been measured yet has no known midpoint to cross —
        // better to sit still than to swap on a guessed distance.
        guard let neighbourHeight = coordinator.heights[AnyHashable(items.wrappedValue[neighbour].id)] else { return }

        let step = neighbourHeight + spacing
        guard abs(visual) > step / 2 else { return }

        withAnimation(.snappy(duration: 0.22)) { items.wrappedValue.swapAt(index, neighbour) }
        coordinator.absorbed += visual > 0 ? step : -step
        Haptics.shared.logSet()
    }
}

/// Shared, reference-typed state for an in-progress reorder. Living on one
/// `@Observable` object (rather than the view's `@State`) is what lets the grip
/// stay closure-free and lets per-frame property writes invalidate only the
/// single row that reads them.
@Observable
final class ReorderCoordinator {
    /// The row currently under the finger, or `nil` when nothing is dragging.
    var draggingID: AnyHashable?
    /// Raw finger travel for the active drag.
    var translation: CGFloat = 0
    /// How much of that travel has already been "spent" swapping rows — the
    /// dragged card is offset by the remainder, so it stays under the finger.
    var absorbed: CGFloat = 0

    /// Measured row heights, keyed by id. Read only while settling swaps, never
    /// in a view `body`, so its layout-time writes never invalidate a row.
    @ObservationIgnored var heights: [AnyHashable: CGFloat] = [:]
    @ObservationIgnored var spacing: CGFloat = 14

    /// Typed reorder logic installed by the owning `ReorderableVStack`. Kept on
    /// the coordinator so the grip can trigger a drag by calling through a
    /// stable reference instead of storing a closure that would churn card diffs.
    @ObservationIgnored fileprivate var updateHandler: ((AnyHashable, CGFloat) -> Void)?
    @ObservationIgnored fileprivate var endHandler: (() -> Void)?

    fileprivate func update(id: AnyHashable, to translation: CGFloat) { updateHandler?(id, translation) }
    fileprivate func end() { endHandler?() }
}

/// One row of a `ReorderableVStack`. Extracted into its own view so the lift
/// transform (`offset`/`scale`/`shadow`/`zIndex`) reads the coordinator at row
/// granularity: a resting row never evaluates `translation`, so a per-frame
/// drag only re-renders the lifted row — and even that skips the heavy card
/// body, because the grip it hands down is unchanged.
private struct ReorderableRow<Content: View>: View {
    let id: AnyHashable
    let coordinator: ReorderCoordinator
    @ViewBuilder var content: (ReorderGrip) -> Content

    var body: some View {
        let isDragging = coordinator.draggingID == id
        content(ReorderGrip(coordinator: coordinator, id: id))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { coordinator.heights[id] = $0 }
            .offset(y: isDragging ? coordinator.translation - coordinator.absorbed : 0)
            .scaleEffect(isDragging ? 1.02 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.4 : 0), radius: 14, y: 8)
            // Keep the lifted card above its neighbours as it travels.
            .zIndex(isDragging ? 1 : 0)
    }
}

/// The handle that starts a reorder drag. Rendered by `ReorderableVStack` and
/// handed to the row builder to place wherever it fits that card's layout.
///
/// It stores only a coordinator reference and its row id — both stable across a
/// drag — so embedding it in a heavy card does not force that card to re-render
/// each frame. The gesture's per-frame closures live inside `body`, where they
/// never become part of the card's identity.
struct ReorderGrip: View {
    fileprivate let coordinator: ReorderCoordinator
    fileprivate let id: AnyHashable

    var body: some View {
        let isActive = coordinator.draggingID == id
        Image(systemName: "line.3.horizontal")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(isActive ? Theme.emerald : Theme.textDim)
            .frame(width: 34, height: 34)
            // Generous hit area — the icon itself is a small target.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { coordinator.update(id: id, to: $0.translation.height) }
                    .onEnded { _ in coordinator.end() }
            )
            .accessibilityLabel("Reorder")
            .accessibilityHint("Drag up or down to move this exercise")
    }
}

import SwiftUI
import Observation

/// A vertical stack whose rows can be dragged into a new order by a grip handle.
///
/// SwiftUI only offers `.onMove` on `List`, but the training screens are custom
/// glass cards inside a `ScrollView` — dropping them into a `List` would cost the
/// whole look. This reorders them in place instead.
///
/// The caller decides where the grip sits, so it can slot into each card's
/// existing header rather than forcing a gutter:
///
///     ReorderableVStack($entries, spacing: 14) { $entry, grip in
///         card($entry, grip: grip)
///     }
///
/// ## Two implementations
///
/// - **iOS 27+** uses the native `reorderable()` / `reorderContainer(for:)` API.
///   The drag runs at the compositor level: the system lifts a *snapshot* of the
///   card and reflows the rest natively, so it stays fluid even with heavy glass
///   cards. This is the Apple-Music-style reorder and the path we want everyone on.
/// - **iOS 26** falls back to a hand-rolled drag (`LegacyReorderableVStack` below).
///   SwiftUI on 26 has no reorder API for custom containers, so we track the finger
///   ourselves. It's serviceable but can't match the native compositor path.
///
/// The public surface is identical for both, so call sites never branch.
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

    var body: some View {
        if #available(iOS 27.0, *) {
            NativeReorderableVStack(items: $items, spacing: spacing, row: row)
        } else {
            LegacyReorderableVStack(items: $items, spacing: spacing, row: row)
        }
    }
}

// MARK: - Native (iOS 27+)

/// Wraps the system `reorderable()` API. `.reorderable()` marks each `ForEach`
/// child as draggable through the container; `.reorderContainer(for:)` acts as both
/// drag source and drop destination and hands us a `ReorderDifference` on drop,
/// which we apply to the bound array.
@available(iOS 27.0, *)
private struct NativeReorderableVStack<Item: Identifiable, Row: View>: View {
    @Binding var items: [Item]
    var spacing: CGFloat
    @ViewBuilder var row: (Binding<Item>, ReorderGrip) -> Row

    var body: some View {
        VStack(spacing: spacing) {
            ForEach($items) { $item in
                row($item, ReorderGrip(backing: .native))
            }
            .reorderable()
        }
        .reorderContainer(for: Item.self) { difference in
            difference.apply(to: &items)
        }
    }
}

/// Applies a single-collection `ReorderDifference` to a bound array in one in-place
/// pass. Lifted verbatim from Apple's `reorderable()` reference.
@available(iOS 27.0, *)
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    func apply<C>(to collection: inout C)
        where C: RangeReplaceableCollection,
              C.Element: Identifiable,
              C.Element.ID == ItemID
    {
        let moving = Set(sources)
        guard !moving.isEmpty else { return }

        var moved: [C.Element] = []
        moved.reserveCapacity(moving.count)
        collection.removeAll { element in
            guard moving.contains(element.id) else { return false }
            moved.append(element)
            return true
        }

        switch destination.position {
        case .before(let id):
            let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
            collection.insert(contentsOf: moved, at: index)
        case .end:
            collection.append(contentsOf: moved)
        }
    }
}

// MARK: - Legacy fallback (iOS 26)

/// Hand-rolled reorder for iOS 26, where SwiftUI has no reorder API for custom
/// containers. Finger tracking and the heavy card body are deliberately kept in
/// separate views: reading `dragOffset` invalidates whatever reads it, so the
/// per-frame offset lives in a leaf `DragTransform` modifier while the card body is
/// built once. The array is reordered a single time, on release.
private struct LegacyReorderableVStack<Item: Identifiable, Row: View>: View {
    @Binding var items: [Item]
    var spacing: CGFloat
    @ViewBuilder var row: (Binding<Item>, ReorderGrip) -> Row

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
        // Reinstall on every `body` so the captured items binding always routes to
        // the current source of truth, and keep the coordinator's spacing in sync.
        // The closures capture the binding by value and the coordinator weakly, so
        // there's no `self` capture and no retain cycle.
        .onAppear { installHandlers() }
        .onChange(of: spacing) { installHandlers() }
    }

    private func installHandlers() {
        let items = $items
        let spacing = spacing
        coordinator.spacing = spacing

        coordinator.updateHandler = { [weak coordinator] id, translation in
            guard let coordinator else { return }

            // First frame of a new drag: snapshot the order and lock in which card
            // is lifted and how tall the gap it leaves behind should be.
            if coordinator.draggingID != id {
                let order = items.wrappedValue.map { AnyHashable($0.id) }
                guard let from = order.firstIndex(of: id) else { return }
                coordinator.orderedIDs = order
                coordinator.fromIndex = from
                coordinator.liftedStep = (coordinator.heights[id] ?? 0) + spacing
                withAnimation(.easeOut(duration: 0.16)) {
                    coordinator.draggingID = id
                }
                Haptics.shared.tick()
            }

            // Pure animation: the lifted card follows the finger 1:1, nothing else.
            coordinator.dragOffset = translation
        }

        coordinator.endHandler = { [weak coordinator] in
            guard let coordinator, coordinator.draggingID != nil else { return }
            let from = coordinator.fromIndex
            let target = coordinator.resolvedTarget(for: coordinator.dragOffset)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                if from != target, items.wrappedValue.indices.contains(from) {
                    // `move(toOffset:)` indexes into the pre-removal array, so a
                    // downward move lands one slot further along.
                    let destination = target > from ? target + 1 : target
                    items.wrappedValue.move(fromOffsets: IndexSet(integer: from), toOffset: destination)
                }
                coordinator.draggingID = nil
                coordinator.dragOffset = 0
            }
            Haptics.shared.logSet()
        }
    }
}

/// Shared, reference-typed state for an in-progress legacy reorder. Living on one
/// `@Observable` object (rather than the view's `@State`) is what lets the grip
/// stay closure-free and lets per-frame writes invalidate only the lifted row.
@Observable
final class ReorderCoordinator {
    /// The row currently under the finger, or `nil` when nothing is dragging.
    var draggingID: AnyHashable?
    /// Raw finger travel for the active drag. Read only by the lifted row's
    /// `DragTransform`, so writing it each frame re-renders nothing else.
    var dragOffset: CGFloat = 0
    /// The lifted card's original index in `orderedIDs`.
    @ObservationIgnored var fromIndex: Int = 0
    /// Height (plus spacing) of the lifted card — used when resolving the drop slot.
    @ObservationIgnored var liftedStep: CGFloat = 0

    /// Measured row heights, keyed by id. Read only when resolving the drop slot on
    /// release and at drag start, never in a resting row's `body`, so its
    /// layout-time writes don't invalidate rows.
    @ObservationIgnored var heights: [AnyHashable: CGFloat] = [:]
    /// Snapshot of the row order taken at drag start. Stable for the whole drag
    /// because the array isn't mutated until drop.
    @ObservationIgnored var orderedIDs: [AnyHashable] = []
    @ObservationIgnored var spacing: CGFloat = 14

    @ObservationIgnored fileprivate var updateHandler: ((AnyHashable, CGFloat) -> Void)?
    @ObservationIgnored fileprivate var endHandler: (() -> Void)?

    fileprivate func update(id: AnyHashable, to translation: CGFloat) { updateHandler?(id, translation) }
    fileprivate func end() { endHandler?() }

    /// Walks outward from the origin in the drag direction, consuming each
    /// neighbour's height until the finger no longer clears that neighbour's
    /// midpoint. Handles variable row heights and fast flicks (it can cross
    /// several rows at once) and always terminates at the array bounds. Called
    /// exactly once, on release.
    func resolvedTarget(for translation: CGFloat) -> Int {
        guard !orderedIDs.isEmpty else { return fromIndex }
        var target = fromIndex

        if translation > 0 {
            var crossed: CGFloat = 0
            var i = fromIndex + 1
            while i < orderedIDs.count {
                let step = (heights[orderedIDs[i]] ?? liftedStep) + spacing
                if translation > crossed + step / 2 {
                    target = i
                    crossed += step
                    i += 1
                } else { break }
            }
        } else if translation < 0 {
            var crossed: CGFloat = 0
            var i = fromIndex - 1
            while i >= 0 {
                let step = (heights[orderedIDs[i]] ?? liftedStep) + spacing
                if -translation > crossed + step / 2 {
                    target = i
                    crossed += step
                    i -= 1
                } else { break }
            }
        }
        return target
    }
}

/// One row of a `LegacyReorderableVStack`. Its body reads only `draggingID` (which
/// flips at most twice per drag), so the heavy card it builds is *not* rebuilt on
/// finger moves. The per-frame offset lives in `DragTransform`, applied as a leaf
/// modifier that re-wraps the already-built card without re-evaluating it.
private struct ReorderableRow<Content: View>: View {
    let id: AnyHashable
    let coordinator: ReorderCoordinator
    @ViewBuilder var content: (ReorderGrip) -> Content

    var body: some View {
        let isDragging = coordinator.draggingID == id
        content(ReorderGrip(backing: .legacy(coordinator, id)))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { coordinator.heights[id] = $0 }
            .modifier(DragTransform(coordinator: coordinator, isDragging: isDragging))
    }
}

/// Leaf modifier that carries the lifted card's finger-following transform. It is
/// the *only* view that reads `dragOffset`, so a finger move re-renders just this
/// modifier — the card subtree it wraps is untouched.
private struct DragTransform: ViewModifier {
    let coordinator: ReorderCoordinator
    let isDragging: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isDragging ? coordinator.dragOffset : 0)
            .scaleEffect(isDragging ? 1.03 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.4 : 0), radius: 14, y: 8)
            // Keep the lifted card above its neighbours as it travels.
            .zIndex(isDragging ? 1 : 0)
    }
}

// MARK: - Grip

/// The handle that starts (or, on iOS 27, signals) a reorder drag. Rendered by the
/// stack and handed to the row builder to place wherever it fits that card's layout.
///
/// On iOS 27 the native container drives the drag, so the grip is a bare affordance.
/// On iOS 26 it carries the `DragGesture` that feeds the coordinator; storing only a
/// coordinator reference and row id (both stable across a drag) keeps it from
/// forcing the enclosing card to re-render each frame.
struct ReorderGrip: View {
    fileprivate enum Backing {
        case native
        case legacy(ReorderCoordinator, AnyHashable)
    }
    fileprivate let backing: Backing

    var body: some View {
        switch backing {
        case .native:
            handle(active: false)
                .accessibilityLabel("Reorder")
                .accessibilityHint("Drag up or down to move this exercise")
        case .legacy(let coordinator, let id):
            handle(active: coordinator.draggingID == id)
                // Generous hit area — the icon itself is a small target.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { coordinator.update(id: id, to: $0.translation.height) }
                        .onEnded { _ in coordinator.end() }
                )
                .accessibilityLabel("Reorder")
                .accessibilityHint("Drag up or down to move this exercise")
        }
    }

    private func handle(active: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(active ? Theme.emerald : Theme.textDim)
            .frame(width: 34, height: 34)
    }
}

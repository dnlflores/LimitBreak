import UIKit

/// App-wide tap-to-dismiss for the keyboard: one gesture recognizer installed
/// on the window, so any tap outside a text input drops focus — no keyboard
/// toolbars, no covered UI. It recognizes alongside every other gesture
/// (`cancelsTouchesInView = false`), so buttons, scrolling, and drags keep
/// working exactly as before; taps on text inputs are ignored so refocusing
/// a field never flickers.
@MainActor
enum KeyboardDismisser {
    private static var installed = false
    private static let delegate = DismissGestureDelegate()

    static func install() {
        guard !installed else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }

        let tap = UITapGestureRecognizer(target: delegate, action: #selector(DismissGestureDelegate.dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.requiresExclusiveTouchType = false
        tap.delegate = delegate
        window.addGestureRecognizer(tap)
        installed = true
    }
}

private final class DismissGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    @objc func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Leave taps on text inputs alone so tapping between fields just
        // moves focus instead of bouncing the keyboard down and back up.
        var view = touch.view
        while let current = view {
            if current is UITextInput { return false }
            view = current.superview
        }
        return true
    }
}

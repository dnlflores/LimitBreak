import SwiftUI
import UIKit

// MARK: - Swipe-back enabler

/// Restores the native left-edge swipe-to-go-back gesture on pushed screens that
/// hide the system navigation bar with `.toolbar(.hidden, for: .navigationBar)`.
///
/// Hiding the nav bar disables UIKit's `interactivePopGestureRecognizer`, which
/// is why our custom-header detail views (with a `chevron.left` back button) lose
/// the swipe-back gesture. This re-enables the recognizer and installs a delegate
/// that only fires the pop when there's actually a screen to go back to, so the
/// root of a stack never gets into a stuck navigation state.
///
/// Apply with `.enableSwipeBack()` on the pushed view.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enableSwipeBack()
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            enableSwipeBack()
        }

        func enableSwipeBack() {
            // Walk up to the nearest navigation controller and switch its
            // interactive pop recognizer back on, routing its delegate to us.
            var responder: UIViewController? = navigationController ?? parent
            while let current = responder {
                if let nav = current as? UINavigationController {
                    coordinator?.navigationController = nav
                    nav.interactivePopGestureRecognizer?.isEnabled = true
                    nav.interactivePopGestureRecognizer?.delegate = coordinator
                    return
                }
                responder = current.parent ?? current.navigationController
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        // Only begin the back-swipe when there's a screen to pop back to.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    /// Restores the native left-edge swipe-to-go-back gesture on a pushed screen
    /// that hides the system navigation bar and provides its own back button.
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

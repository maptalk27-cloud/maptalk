import SwiftUI
import UIKit

/// Pages stories horizontally while leaving vertical movement to the native
/// presentation transition. Rejecting an axis before recognition matters:
/// ignoring vertical updates after a SwiftUI drag begins still owns the touch.
@MainActor
struct POIStoryHorizontalGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ predicted: CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            onEnded(translation, translation + velocity * 0.18)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = recognizer.velocity(in: recognizer.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

import UIKit

/// Stock-style cross-dissolve between complete layouts. Capture the window, not
/// individual effect views: their material needs the background in the same image.
final class ConceptProfileEditTransition {
    private var overlay: UIView?
    private var animator: UIViewPropertyAnimator?
    private var generation = 0
    private(set) var isApplyingChanges = false

    func perform(in view: UIView, animated: Bool = true, changes: () -> Void) {
        precondition(Thread.isMainThread)
        self.generation += 1
        let generation = self.generation

        var snapshot: UIView?
        let window = view.window
        if animated, !UIAccessibility.isReduceMotionEnabled, let window,
           view.bounds.width > 0.0, view.bounds.height > 0.0 {
            snapshot = window.snapshotView(afterScreenUpdates: false)
        }

        // Capture the visible presentation before interrupting an earlier fade.
        self.animator?.stopAnimation(true)
        self.animator = nil
        self.overlay?.removeFromSuperview()
        self.overlay = nil

        let overlay: UIView?
        if let snapshot, let window {
            let container = UIView(frame: view.bounds)
            container.isUserInteractionEnabled = false
            container.accessibilityElementsHidden = true
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.clipsToBounds = true
            let imageView = snapshot
            imageView.frame = view.convert(window.bounds, from: window)
            container.addSubview(imageView)
            view.addSubview(container)
            self.overlay = container
            overlay = container
        } else {
            overlay = nil
        }

        self.isApplyingChanges = true
        UIView.performWithoutAnimation {
            changes()
            view.layoutIfNeeded()
        }
        self.isApplyingChanges = false
        guard let overlay else { return }
        view.bringSubviewToFront(overlay)

        // The target hierarchy gets a layout/render turn behind the complete old
        // frame. Only its opacity changes; rows and rounded corners never travel.
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self, let overlay, self.generation == generation else { return }
            let animator = UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) {
                overlay.alpha = 0.0
            }
            animator.addCompletion { [weak self, weak overlay] _ in
                overlay?.removeFromSuperview()
                guard let self, self.generation == generation else { return }
                self.overlay = nil
                self.animator = nil
            }
            self.animator = animator
            animator.startAnimation()
        }
    }

    deinit {
        self.animator?.stopAnimation(true)
        self.overlay?.removeFromSuperview()
    }
}

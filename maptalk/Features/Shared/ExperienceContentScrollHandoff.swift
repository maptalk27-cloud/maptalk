import SwiftUI
import UIKit

/// SwiftUI's scrollDisabled environment also disables nested media galleries.
/// Restrict this policy to the panel's own vertical scroll view instead, keeping
/// its content (and video player) mounted throughout interactive sheet resizing.
struct ExperienceContentScrollHandoff: UIViewRepresentable {
    let isScrollable: Bool

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.isScrollable = isScrollable
        uiView.refreshAncestor()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.detach()
    }

    final class ProbeView: UIView {
        var isScrollable = false
        private weak var scrollView: UIScrollView?
        private var originalScrollEnabled = true
        private var isDetached = false

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshAncestor()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            refreshAncestor()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshAncestor()
        }

        func refreshAncestor() {
            guard !isDetached, window != nil else { releaseScrollView(); return }
            var ancestor = superview
            var candidate: UIScrollView?
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    // Never apply this policy to the horizontal page collection.
                    if !(scroll is UICollectionView) { candidate = scroll }
                    break
                }
                ancestor = view.superview
            }
            if scrollView !== candidate {
                releaseScrollView()
                if let candidate {
                    originalScrollEnabled = candidate.isScrollEnabled
                    scrollView = candidate
                }
            }
            scrollView?.isScrollEnabled = originalScrollEnabled && isScrollable
        }

        func detach() {
            isDetached = true
            releaseScrollView()
        }

        private func releaseScrollView() {
            scrollView?.isScrollEnabled = originalScrollEnabled
            scrollView = nil
        }
    }
}

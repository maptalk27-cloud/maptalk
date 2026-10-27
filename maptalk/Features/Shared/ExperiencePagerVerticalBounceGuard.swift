import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

/// PageTabView can bounce vertically even though it pages horizontally. Keep
/// that off-axis bounce from competing with the sheet and the page's own scroll.
/// Only public properties on the enclosing horizontal collection are changed.
struct ExperiencePagerVerticalBounceGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.refreshAncestor()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.detach()
    }

    final class ProbeView: UIView {
        private final class Lease {
            let bouncesVertically: Bool
            let alwaysBounceVertical: Bool
            var owners = 1

            init(_ collection: UICollectionView) {
                bouncesVertically = collection.bouncesVertically
                alwaysBounceVertical = collection.alwaysBounceVertical
            }
        }

        // Adjacent pages may coexist. Restore only when the last page detaches,
        // so a disappearing page cannot undo the visible page's configuration.
        private static let leases = NSMapTable<UICollectionView, Lease>(
            keyOptions: .weakMemory, valueOptions: .strongMemory
        )
#if DEBUG
        private static let logger = Logger(subsystem: "com.chengsi.maptalk", category: "ExperiencePager")
#endif
        private weak var pager: UICollectionView?
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
            guard !isDetached, window != nil else {
                releasePager()
                return
            }
            var ancestor = superview
            var candidate: UICollectionView?
            while let view = ancestor {
                if let collection = view as? UICollectionView {
                    // The page's vertical ScrollView is deliberately untouched.
                    // Never bind a vertically scrolling collection either.
                    let inset = collection.adjustedContentInset
                    if collection.bounds.width > 0,
                       collection.contentSize.width > collection.bounds.width + 1,
                       collection.contentSize.height <= collection.bounds.height + inset.top + inset.bottom + 1 {
                        candidate = collection
                    }
                    break
                }
                ancestor = view.superview
            }
            if pager !== candidate {
                releasePager()
                if let candidate {
                    if let lease = Self.leases.object(forKey: candidate) {
                        lease.owners += 1
                    } else {
                        Self.leases.setObject(Lease(candidate), forKey: candidate)
#if DEBUG
                        Self.logger.notice("vertical bounce guard attached")
#endif
                    }
                    pager = candidate
                }
            }
            pager?.alwaysBounceVertical = false
            pager?.bouncesVertically = false
        }

        func detach() {
            isDetached = true
            releasePager()
        }

        private func releasePager() {
            guard let pager else { return }
            if let lease = Self.leases.object(forKey: pager) {
                lease.owners -= 1
                if lease.owners == 0 {
                    pager.bouncesVertically = lease.bouncesVertically
                    pager.alwaysBounceVertical = lease.alwaysBounceVertical
                    Self.leases.removeObject(forKey: pager)
                }
            }
            self.pager = nil
        }
    }
}

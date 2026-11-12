import SwiftUI
import UIKit

/// The identity remains a separate floating surface. Its lifecycle follows
/// the native card without changing the card's content canvas or outline.
struct FriendStoryCardHeader<Header: View>: ViewModifier {
    let isEnabled: Bool
    let isVisible: Bool
    @ViewBuilder let header: () -> Header

    func body(content: Content) -> some View {
        content.background {
            if isEnabled {
                FriendStoryFloatingAccessory(isVisible: isVisible) {
                    header().background(.regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 22))
                        .environment(\.colorScheme, .dark)
                }
            }
        }
    }
}

/// An accessory to the native presentation, not part of its glass platter.
/// Keep the real card/scroll/drag machinery unchanged and place only the
/// identity in the presentation container's uncovered map area.
struct FriendStoryFloatingAccessory<Content: View>: UIViewControllerRepresentable {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> FriendStoryAccessoryController<Content> {
        FriendStoryAccessoryController(content: content())
    }

    func updateUIViewController(_ controller: FriendStoryAccessoryController<Content>, context: Context) {
        controller.updateContent(content())
        controller.isAccessoryVisible = isVisible
        controller.attachIfNeeded()
    }

    static func dismantleUIViewController(_ controller: FriendStoryAccessoryController<Content>, coordinator: ()) {
        controller.detach()
    }
}

final class FriendStoryAccessoryController<Content: View>: UIViewController {
    private let accessory: UIView & UIContentView
    // Geometry follows the card; the inner view's opacity belongs exclusively
    // to UIKit's presentation transition, not our per-frame layout updates.
    private let accessoryContainer = UIView()
    var isAccessoryVisible = true {
        didSet {
            guard isViewLoaded else { return }
            coordinateVisibilityTransition()
            updateVisibility()
        }
    }
    private weak var sheet: UISheetPresentationController?
    private weak var coordinatedTransition: (any UIViewControllerTransitionCoordinator)?
    private var displayLink: CADisplayLink?
    private var isDismantled = false
    private var isFollowingTransition = false
    private var hasAppeared = false
    private var keepsVisibleForDismissal = false

    init(content: Content) {
        accessory = UIHostingConfiguration { content }.margins(.all, 0).makeContentView()
        super.init(nibName: nil, bundle: nil)
    }

    func updateContent(_ content: Content) {
        accessory.configuration = UIHostingConfiguration { content }.margins(.all, 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        accessory.backgroundColor = .clear
        accessory.alpha = 0
        accessory.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessoryContainer.backgroundColor = .clear
        accessoryContainer.addSubview(accessory)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachIfNeeded()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { attachIfNeeded() }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        attachIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        attachIfNeeded()
        if !isFollowingTransition { accessory.alpha = 1 }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinateVisibilityTransition()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard !isDismantled else { return }
        var ancestor = parent
        while let current = ancestor {
            if let presentation = current.presentationController as? UISheetPresentationController,
               let container = presentation.containerView {
                loadViewIfNeeded()
                sheet = presentation
                if accessoryContainer.superview !== container {
                    container.addSubview(accessoryContainer)
                }
                if displayLink == nil {
                    let link = CADisplayLink(target: WeakDisplayLinkTarget(self), selector: #selector(WeakDisplayLinkTarget.tick))
                    link.add(to: .main, forMode: .common)
                    link.isPaused = !isAccessoryVisible
                    displayLink = link
                }
                updatePosition()
                // POI/Bubble can replace content inside an already open sheet.
                // There is no opening transition to wait for in that case.
                let owner = presentation.presentedViewController
                if !owner.isBeingPresented, !owner.isBeingDismissed,
                   owner.viewIfLoaded?.window != nil, !isFollowingTransition {
                    accessory.alpha = 1
                }
                return
            }
            ancestor = current.parent
        }
    }

    fileprivate func updatePosition() {
        guard let sheet, let container = sheet.containerView, let card = sheet.presentedView,
              accessoryContainer.superview === container else { return }
        coordinateVisibilityTransition()
        // Presentation layers follow UIKit's interactive drag and spring in
        // the same display frame, without publishing per-frame SwiftUI state
        // or recalculating the map/its annotations.
        let frame: CGRect
        if let layer = card.layer.presentation(), let containerLayer = container.layer.presentation() {
            frame = layer.convert(layer.bounds, to: containerLayer)
        } else {
            frame = card.convert(card.bounds, to: container)
        }
        guard card.bounds.width > 0, frame.width > 0 else { return }
        // Measure in the card's unscaled space, then apply the same zoom. A
        // fixed-height bar above a shrinking card looks like a detached overlay.
        let scale = frame.width / card.bounds.width
        let width = max(0, card.bounds.width - 20)
        let height = FriendStoryLayout.headerHeight
        UIView.performWithoutAnimation {
            accessoryContainer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            accessory.frame = accessoryContainer.bounds
            accessoryContainer.center = CGPoint(x: frame.midX,
                y: frame.minY - (FriendStoryLayout.headerGap + height / 2) * scale)
            accessoryContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
            accessoryContainer.alpha = FriendStoryLayout.accessoryOpacity(
                cardTop: frame.minY, containerBottom: container.bounds.maxY)
        }
        updateVisibility(isOffscreen: frame.minY >= container.bounds.maxY)
    }

    private func updateVisibility(isOffscreen: Bool = false) {
        let visible = isAccessoryVisible || keepsVisibleForDismissal
        accessoryContainer.isHidden = !visible || isOffscreen
        accessoryContainer.isUserInteractionEnabled = isAccessoryVisible && !keepsVisibleForDismissal
        displayLink?.isPaused = !visible
    }

    private func coordinateVisibilityTransition() {
        guard let owner = sheet?.presentedViewController,
              owner.isBeingPresented || owner.isBeingDismissed,
              let coordinator = owner.transitionCoordinator,
              coordinatedTransition !== coordinator else { return }
        coordinatedTransition = coordinator
        let isDismissing = owner.isBeingDismissed
        isFollowingTransition = true
        keepsVisibleForDismissal = isDismissing && !accessoryContainer.isHidden
        if !isDismissing { accessory.alpha = 0 }
        let registered = coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.accessory.alpha = isDismissing ? 0 : 1
        }, completion: { [weak self] context in
            guard let self, self.coordinatedTransition === coordinator else { return }
            self.isFollowingTransition = false
            self.keepsVisibleForDismissal = false
            self.accessory.alpha = context.isCancelled
                ? (isDismissing ? 1 : 0) : (isDismissing ? 0 : 1)
            self.updateVisibility()
        })
        if !registered {
            isFollowingTransition = false
            keepsVisibleForDismissal = false
            accessory.alpha = hasAppeared ? 1 : 0
            updateVisibility()
        }
    }

    func detach() {
        isDismantled = true
        displayLink?.invalidate()
        displayLink = nil
        // SwiftUI can dismantle the representable before native dismissal has
        // finished. Let the already-running fade finish instead of popping out.
        let remainingAccessory = accessoryContainer
        if let coordinator = coordinatedTransition, isFollowingTransition,
           sheet?.presentedViewController.isBeingDismissed == true {
            if !coordinator.animate(alongsideTransition: nil, completion: { _ in
                remainingAccessory.removeFromSuperview()
            }) {
                remainingAccessory.removeFromSuperview()
            }
        } else {
            remainingAccessory.removeFromSuperview()
        }
        sheet = nil
    }

    deinit { displayLink?.invalidate() }
}

/// CADisplayLink retains its target; the target must not keep the presentation
/// alive after SwiftUI dismantles it.
private final class WeakDisplayLinkTarget: NSObject {
    private let action: () -> Void

    init<Content: View>(_ controller: FriendStoryAccessoryController<Content>) {
        action = { [weak controller] in controller?.updatePosition() }
    }

    @objc func tick() { action() }
}

import SwiftUI
import UIKit

/// Measures the native card, not the SwiftUI content's independent hosting
/// coordinate space. This is layout-only: no display link or map updates.
struct MapTalkSheetFrameReader: UIViewControllerRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIViewController(context: Context) -> MapTalkSheetFrameController {
        MapTalkSheetFrameController(onChange: onChange)
    }

    func updateUIViewController(_ controller: MapTalkSheetFrameController, context: Context) {
        controller.onChange = onChange
        controller.reportFrame()
    }
}

final class MapTalkSheetFrameController: UIViewController {
    var onChange: (CGRect) -> Void
    private var lastFrame = CGRect.null

    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportFrame()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportFrame()
    }

    func reportFrame() {
        guard let window = viewIfLoaded?.window else { return }
        var ancestor = parent
        while let current = ancestor {
            if let sheet = current.presentationController as? UISheetPresentationController,
               let card = sheet.presentedView {
                let frame = card.convert(card.bounds, to: window)
                guard frame.height > 0, frame != lastFrame else { return }
                lastFrame = frame
                // Don't publish SwiftUI state during UIKit's layout pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.viewIfLoaded?.window != nil else { return }
                    self.onChange(frame)
                }
                return
            }
            ancestor = current.parent
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
    var isAccessoryVisible = true {
        didSet {
            accessory.isHidden = !isAccessoryVisible
            displayLink?.isPaused = !isAccessoryVisible
        }
    }
    private weak var sheet: UISheetPresentationController?
    private var displayLink: CADisplayLink?
    private var isDismantled = false

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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard !isDismantled, viewIfLoaded?.window != nil else { return }
        var ancestor = parent
        while let current = ancestor {
            if let presentation = current.presentationController as? UISheetPresentationController,
               let container = presentation.containerView {
                sheet = presentation
                if accessory.superview !== container {
                    container.addSubview(accessory)
                }
                if displayLink == nil {
                    let link = CADisplayLink(target: WeakDisplayLinkTarget(self), selector: #selector(WeakDisplayLinkTarget.tick))
                    link.add(to: .main, forMode: .common)
                    link.isPaused = !isAccessoryVisible
                    displayLink = link
                }
                updatePosition()
                return
            }
            ancestor = current.parent
        }
    }

    fileprivate func updatePosition() {
        guard let sheet, let container = sheet.containerView, let card = sheet.presentedView,
              accessory.superview === container else { return }
        // Presentation layers follow UIKit's interactive drag and spring in
        // the same display frame, without publishing per-frame SwiftUI state
        // or recalculating the map/its annotations.
        let frame: CGRect
        if let layer = card.layer.presentation(), let containerLayer = container.layer.presentation() {
            frame = layer.convert(layer.bounds, to: containerLayer)
        } else {
            frame = card.convert(card.bounds, to: container)
        }
        let target = FriendStoryLayout.accessoryFrame(above: frame)
        UIView.performWithoutAnimation {
            if accessory.frame != target { accessory.frame = target }
            accessory.alpha = FriendStoryLayout.accessoryOpacity(
                cardTop: frame.minY, containerBottom: container.bounds.maxY)
        }
        accessory.isHidden = !isAccessoryVisible || frame.minY >= container.bounds.maxY
    }

    func detach() {
        isDismantled = true
        displayLink?.invalidate()
        displayLink = nil
        accessory.removeFromSuperview()
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

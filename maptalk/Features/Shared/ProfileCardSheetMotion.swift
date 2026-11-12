import Combine
import SwiftUI
import UIKit

private struct CanControlCardMotionKey: EnvironmentKey {
    static let defaultValue: () -> Bool = { true }
}

extension EnvironmentValues {
    /// Evaluate at callback time, not when a departing page was rendered.
    var canControlCardMotion: () -> Bool {
        get { self[CanControlCardMotionKey.self] }
        set { self[CanControlCardMotionKey.self] = newValue }
    }
}

/// Both map browsers consume the same pager progress; each retains ownership
/// of its native presentation and dismissal lifecycle.
@MainActor
protocol CardSheetHeightDriver: AnyObject {
    var allowsLayoutUpdates: Bool { get }
    func compactHeightChanged(animated: Bool)
}

/// The horizontal pager drives one stable native compact detent. The
/// fraction is intentionally not published: finger movement must not rebuild
/// the map or its annotations on every frame.
@MainActor
final class ProfileCardSheetMotion: ObservableObject {
    @Published private(set) var maximumDetentHeight: CGFloat = 0
    @Published private(set) var bottomSafeArea: CGFloat = 0
    private(set) var compactFraction: CGFloat = 0.35
    var isPaging = false

    private weak var controller: (any CardSheetHeightDriver)?
    private var pendingGeometry: (maximumHeight: CGFloat, bottom: CGFloat)?
    private var hasQueuedGeometry = false

    init(compactFraction: CGFloat = 0.35) {
        self.compactFraction = compactFraction.isFinite
            ? min(0.9, max(0.15, compactFraction)) : 0.35
    }

    func setCompactFraction(_ fraction: CGFloat, animated: Bool = false) {
        guard controller?.allowsLayoutUpdates != false else { return }
        guard updateCompactFraction(fraction) else { return }
        controller?.compactHeightChanged(animated: animated && !isPaging)
    }

    /// The bridge batches fraction, owner and expanded inset into one native
    /// resize. Pager-driven updates still use setCompactFraction above.
    func updateCompactFraction(_ fraction: CGFloat) -> Bool {
        guard fraction.isFinite else { return false }
        let fraction = min(0.9, max(0.15, fraction))
        guard abs(compactFraction - fraction) > 0.0001 else { return false }
        compactFraction = fraction
        return true
    }

    func attach(_ controller: any CardSheetHeightDriver) {
        self.controller = controller
    }

    func detach(_ controller: any CardSheetHeightDriver) {
        guard self.controller === controller else { return }
        self.controller = nil
        isPaging = false
    }

    /// A custom detent resolver runs during UIKit layout. Only publish changed
    /// geometry after that pass, once, rather than mutating SwiftUI in a resolver.
    fileprivate func reportGeometry(maximumHeight: CGFloat, bottom: CGFloat) {
        guard controller?.allowsLayoutUpdates == true else { return }
        enqueueGeometry(maximumHeight: maximumHeight, bottom: bottom) { [weak self] in
            self?.controller?.allowsLayoutUpdates == true
        }
    }

    /// A presenter can measure its opening canvas before horizontal paging is
    /// enabled. Keep its lifecycle guard when publishing outside UIKit layout.
    func reportGeometry(maximumHeight: CGFloat, bottom: CGFloat,
                        allowsUpdates: @escaping () -> Bool) {
        guard allowsUpdates() else { return }
        enqueueGeometry(maximumHeight: maximumHeight, bottom: bottom, allowsUpdates: allowsUpdates)
    }

    private func enqueueGeometry(maximumHeight: CGFloat, bottom: CGFloat,
                                 allowsUpdates: @escaping () -> Bool) {
        guard maximumHeight.isFinite, maximumHeight > 0, bottom.isFinite else { return }
        let bottom = max(0, bottom)
        guard abs(maximumDetentHeight - maximumHeight) > 0.5
                || abs(bottomSafeArea - bottom) > 0.5 else { return }
        pendingGeometry = (maximumHeight, bottom)
        guard !hasQueuedGeometry else { return }
        hasQueuedGeometry = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasQueuedGeometry = false
            let geometry = self.pendingGeometry
            self.pendingGeometry = nil
            guard allowsUpdates(), let geometry else { return }
            if abs(self.maximumDetentHeight - geometry.maximumHeight) > 0.5 {
                self.maximumDetentHeight = geometry.maximumHeight
            }
            if abs(self.bottomSafeArea - geometry.bottom) > 0.5 {
                self.bottomSafeArea = geometry.bottom
            }
        }
    }
}

/// A mixed-content browser can reuse the same native height interpolation.
/// UIKit still owns vertical dragging, stops, dismissal and scroll handoff.
struct ProfileCardSheetChrome: ViewModifier {
    @ObservedObject var presentation: MapExperiencePresentation
    @ObservedObject var motion: ProfileCardSheetMotion
    var expandedTopInset: CGFloat = 0
    var compactFraction: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .background(ProfileCardSheetBridge(presentation: presentation, motion: motion,
                                               expandedTopInset: expandedTopInset,
                                               compactFraction: compactFraction))
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(presentation.isExpanded)
            .presentationBackground(.thinMaterial)
            .presentationCompactAdaptation(.none)
            .presentationBackgroundInteraction(.enabled)
    }
}

private struct ProfileCardSheetBridge: UIViewControllerRepresentable {
    let presentation: MapExperiencePresentation
    let motion: ProfileCardSheetMotion
    var expandedTopInset: CGFloat = 0
    var compactFraction: CGFloat? = nil

    func makeUIViewController(context: Context) -> ProfileCardSheetController {
        ProfileCardSheetController(presentation: presentation, motion: motion,
                                   expandedTopInset: expandedTopInset,
                                   compactFraction: compactFraction)
    }

    func updateUIViewController(_ controller: ProfileCardSheetController, context: Context) {
        controller.update(presentation: presentation, motion: motion,
                          expandedTopInset: expandedTopInset,
                          compactFraction: compactFraction)
    }

    static func dismantleUIViewController(_ controller: ProfileCardSheetController, coordinator: ()) {
        controller.detach()
    }
}

@MainActor
private final class ProfileCardSheetController: UIViewController, CardSheetHeightDriver {
    private static let compactID = UISheetPresentationController.Detent.Identifier("maptalk.profile.compact")
    private static let insetExpandedID = UISheetPresentationController.Detent.Identifier("maptalk.browser.expanded")
    private var presentation: MapExperiencePresentation
    private var motion: ProfileCardSheetMotion
    private var expandedTopInset: CGFloat
    private var installedExpandedTopInset: CGFloat?
    private weak var sheet: UISheetPresentationController?
    private let delegateProxy = ProfileCardSheetDelegate()
    private var compactDetent: UISheetPresentationController.Detent?
    private var isDetached = false
    private var isInvalidatingHeight = false
    private var isApplyingSelection = false
    private var pendingNativeExpanded: Bool?
    private var selectionRevision = 0
    private var presentationRevision: Int
    private var needsHeightInvalidation = false

    // Closing belongs to UIKit alone. A final SwiftUI update must not pull
    // the disappearing sheet back to a detent before it can leave.
    var allowsLayoutUpdates: Bool {
        !isDetached && presentation.isPresented
            && sheet?.presentedViewController.isBeingDismissed != true
    }

    init(presentation: MapExperiencePresentation, motion: ProfileCardSheetMotion,
         expandedTopInset: CGFloat = 0, compactFraction: CGFloat? = nil) {
        self.presentation = presentation
        self.presentationRevision = presentation.contentRevision
        self.motion = motion
        self.expandedTopInset = Self.validInset(expandedTopInset)
        if presentation.isPresented, let compactFraction {
            _ = motion.updateCompactFraction(compactFraction)
        }
        super.init(nibName: nil, bundle: nil)
        delegateProxy.onSelectionChanged = { [weak self] sheet in
            self?.nativeSelectionChanged(sheet)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { attachIfNeeded() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachIfNeeded()
    }

    func update(presentation: MapExperiencePresentation, motion: ProfileCardSheetMotion,
                expandedTopInset: CGFloat = 0, compactFraction: CGFloat? = nil) {
        if self.presentation !== presentation || presentationRevision != presentation.contentRevision {
            // An async callback from the outgoing POI must never mark the
            // incoming Post expanded (or vice versa), despite sharing a shell.
            selectionRevision &+= 1
            pendingNativeExpanded = nil
            motion.isPaging = false
        }
        self.presentation = presentation
        self.presentationRevision = presentation.contentRevision
        guard allowsLayoutUpdates else {
            selectionRevision &+= 1
            pendingNativeExpanded = nil
            return
        }
        self.expandedTopInset = Self.validInset(expandedTopInset)
        if self.motion !== motion {
            self.motion.detach(self)
            self.motion = motion
            compactDetent = nil
        }
        if let compactFraction, !motion.isPaging,
           motion.updateCompactFraction(compactFraction) {
            needsHeightInvalidation = true
        }
        attachIfNeeded()
        synchronizeSelection(animated: viewIfLoaded?.window != nil)
    }

    private func attachIfNeeded() {
        guard allowsLayoutUpdates else { return }
        var ancestor = parent
        while let current = ancestor {
            if let candidate = current.presentationController as? UISheetPresentationController {
                guard !candidate.presentedViewController.isBeingDismissed else { return }
                if sheet !== candidate {
                    restoreDelegate()
                    sheet = candidate
                    compactDetent = nil
                    installedExpandedTopInset = nil
                }
                motion.attach(self)
                installDelegate(on: candidate)
                if compactDetent == nil {
                    let detent = UISheetPresentationController.Detent.custom(identifier: Self.compactID) {
                        [weak self] context in
                        guard let self else { return context.maximumDetentValue * 0.35 }
                        self.motion.reportGeometry(
                            maximumHeight: context.maximumDetentValue,
                            bottom: self.sheet?.containerView?.safeAreaInsets.bottom
                                ?? self.viewIfLoaded?.window?.safeAreaInsets.bottom ?? 0
                        )
                        return context.maximumDetentValue * self.motion.compactFraction
                    }
                    compactDetent = detent
                    installedExpandedTopInset = nil
                }
                if installedExpandedTopInset != expandedTopInset || needsHeightInvalidation {
                    configureDetents(on: candidate, animated: installedExpandedTopInset != nil)
                }
                return
            }
            ancestor = current.parent
        }
    }

    private static func validInset(_ inset: CGFloat) -> CGFloat {
        inset.isFinite ? max(0, inset) : 0
    }

    private var expandedID: UISheetPresentationController.Detent.Identifier {
        expandedTopInset > 0 ? Self.insetExpandedID : .large
    }

    private func isExpandedIdentifier(_ identifier: UISheetPresentationController.Detent.Identifier?) -> Bool {
        identifier == expandedID
    }

    /// Switching into/out of a Bubble can add/remove its floating title space.
    /// Keep the model's expanded state and the compact identifier unchanged.
    private func configureDetents(on sheet: UISheetPresentationController, animated: Bool) {
        guard allowsLayoutUpdates, let compactDetent, !isApplyingSelection else { return }
        let expanded: UISheetPresentationController.Detent
        if expandedTopInset > 0 {
            expanded = .custom(identifier: Self.insetExpandedID) { [weak self] context in
                max(1, context.maximumDetentValue - (self?.expandedTopInset ?? 0))
            }
        } else {
            expanded = .large()
        }
        let wasExpanded = pendingNativeExpanded ?? presentation.isExpanded
        let target = wasExpanded ? expandedID : Self.compactID
        installedExpandedTopInset = expandedTopInset
        needsHeightInvalidation = false
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        let apply = {
            sheet.detents = [compactDetent, expanded]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.largestUndimmedDetentIdentifier = self.expandedID
            sheet.selectedDetentIdentifier = target
            sheet.invalidateDetents()
        }
        if animated, !UIAccessibility.isReduceMotionEnabled, viewIfLoaded?.window != nil,
           !sheet.presentedViewController.isBeingPresented,
           !sheet.presentedViewController.isBeingDismissed {
            sheet.animateChanges(apply)
        } else {
            apply()
        }
    }

    /// The pager keeps a fixed layout canvas. Only the native clipping window
    /// changes, using the same detent identity throughout an interactive swipe.
    func compactHeightChanged(animated: Bool) {
        guard allowsLayoutUpdates, !isInvalidatingHeight, let sheet else { return }
        isInvalidatingHeight = true
        defer { isInvalidatingHeight = false }
        if animated, !UIAccessibility.isReduceMotionEnabled,
           !isExpandedIdentifier(sheet.selectedDetentIdentifier) {
            sheet.animateChanges { sheet.invalidateDetents() }
        } else {
            UIView.performWithoutAnimation {
                sheet.invalidateDetents()
                sheet.containerView?.layoutIfNeeded()
            }
        }
    }

    private func synchronizeSelection(animated: Bool) {
        guard allowsLayoutUpdates, pendingNativeExpanded == nil, !isApplyingSelection,
              let sheet, compactDetent != nil else { return }
        let target = presentation.isExpanded ? expandedID : Self.compactID
        guard sheet.selectedDetentIdentifier != target else { return }
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if animated, !UIAccessibility.isReduceMotionEnabled,
           !sheet.presentedViewController.isBeingPresented,
           !sheet.presentedViewController.isBeingDismissed {
            sheet.animateChanges { sheet.selectedDetentIdentifier = target }
        } else {
            sheet.selectedDetentIdentifier = target
        }
    }

    private func nativeSelectionChanged(_ sheet: UISheetPresentationController) {
        guard allowsLayoutUpdates, !isApplyingSelection,
              sheet.selectedDetentIdentifier == Self.compactID
                || isExpandedIdentifier(sheet.selectedDetentIdentifier) else { return }
        let expanded = isExpandedIdentifier(sheet.selectedDetentIdentifier)
        pendingNativeExpanded = expanded
        selectionRevision &+= 1
        let revision = selectionRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDetached, self.selectionRevision == revision else { return }
            self.pendingNativeExpanded = nil
            guard self.allowsLayoutUpdates else { return }
            let target: PresentationDetent = expanded ? .large : self.presentation.compactDetent
            if self.presentation.detent != target { self.presentation.detent = target }
        }
    }

    private func installDelegate(on sheet: UISheetPresentationController) {
        guard sheet.delegate !== delegateProxy else { return }
        // SwiftUI still receives its dismissal/adaptation callbacks. This proxy
        // intercepts only selected-detent changes that it must mirror locally.
        delegateProxy.forwardedDelegate = sheet.delegate
        sheet.delegate = delegateProxy
    }

    private func restoreDelegate() {
        if sheet?.delegate === delegateProxy { sheet?.delegate = delegateProxy.forwardedDelegate }
        delegateProxy.forwardedDelegate = nil
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        selectionRevision &+= 1
        pendingNativeExpanded = nil
        restoreDelegate()
        motion.detach(self)
        sheet = nil
        compactDetent = nil
        installedExpandedTopInset = nil
    }
}

/// Don't replace SwiftUI's presentation lifecycle with a second dismissal
/// implementation. Unhandled optional delegate messages retain their recipient.
@MainActor
private final class ProfileCardSheetDelegate: NSObject, UISheetPresentationControllerDelegate {
    weak var forwardedDelegate: (any UISheetPresentationControllerDelegate)?
    var onSelectionChanged: ((UISheetPresentationController) -> Void)?

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheetPresentationController: UISheetPresentationController) {
        forwardedDelegate?.sheetPresentationControllerDidChangeSelectedDetentIdentifier?(sheetPresentationController)
        onSelectionChanged?(sheetPresentationController)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
    }
}

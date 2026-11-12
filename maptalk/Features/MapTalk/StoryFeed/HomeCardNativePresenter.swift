import SwiftUI
import UIKit

/// Home owns one native presentation. Its two feeds replace content inside
/// that controller; they do not replace the controller or its detent IDs.
struct HomeCardNativePresenter: UIViewControllerRepresentable {
    @ObservedObject var presentation: MapTalkCardPresentation
    let compactFraction: CGFloat
    let expandedTopInset: CGFloat
    let selectedSource: MapTalkCardTransitionID?
    let backgroundColor: UIColor
    let content: AnyView
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(presentation: presentation, compactFraction: compactFraction,
                   expandedTopInset: expandedTopInset, selectedSource: selectedSource,
                   backgroundColor: backgroundColor,
                   content: AnyView(content.environment(\.self, context.environment)), onDismiss: onDismiss)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(compactFraction: compactFraction, expandedTopInset: expandedTopInset,
                          selectedSource: selectedSource,
                          backgroundColor: backgroundColor,
                          content: AnyView(content.environment(\.self, context.environment)), onDismiss: onDismiss)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detach()
    }

    @MainActor
    final class Controller: UIViewController, UISheetPresentationControllerDelegate, CardSheetHeightDriver {
        private static let compactID = UISheetPresentationController.Detent.Identifier("maptalk.home.compact")
        private static let expandedID = UISheetPresentationController.Detent.Identifier("maptalk.home.expanded")

        private enum Phase { case idle, presenting, presented, dismissing }
        private let presentation: MapTalkCardPresentation
        private var compactFraction: CGFloat
        private var expandedTopInset: CGFloat
        private var selectedSource: MapTalkCardTransitionID?
        private var backgroundColor: UIColor
        private var content: AnyView
        private var onDismiss: () -> Void
        private var host: CardHostingController?
        private var phase: Phase = .idle
        private var installedIdentity: MapTalkCardContentIdentity?
        private var installedFraction: CGFloat?
        private var installedExpandedTopInset: CGFloat?
        private var isApplyingNativeState = false
        private var isInvalidatingHeight = false
        private var pendingNativeSelection: Bool?
        private var selectionRevision = 0
        private var isDetached = false

        private var identity: MapTalkCardContentIdentity {
            .init(flow: presentation.activeFlow, revision: presentation.current.contentRevision)
        }

        init(presentation: MapTalkCardPresentation, compactFraction: CGFloat,
             expandedTopInset: CGFloat, selectedSource: MapTalkCardTransitionID?,
             backgroundColor: UIColor = .clear,
             content: AnyView, onDismiss: @escaping () -> Void) {
            self.presentation = presentation
            self.compactFraction = Self.validFraction(compactFraction)
            self.expandedTopInset = Self.validExpandedTopInset(expandedTopInset)
            self.selectedSource = selectedSource
            self.backgroundColor = backgroundColor
            self.content = content
            self.onDismiss = onDismiss
            super.init(nibName: nil, bundle: nil)
            presentation.motion.attach(self)
            presentation.deferSelectionForNativeTransition = { [weak self] in
                guard let self, !self.isDetached, let host = self.host else { return false }
                if host.isBeingDismissed { self.beginDismissal(of: host) }
                return self.phase == .presenting || self.phase == .dismissing
                    || host.isBeingPresented || host.isBeingDismissed
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

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if phase == .idle { synchronize() }
        }

        func update(compactFraction: CGFloat, expandedTopInset: CGFloat,
                    selectedSource: MapTalkCardTransitionID?, backgroundColor: UIColor = .clear,
                    content: AnyView,
                    onDismiss: @escaping () -> Void) {
            self.compactFraction = Self.validFraction(compactFraction)
            self.expandedTopInset = Self.validExpandedTopInset(expandedTopInset)
            self.selectedSource = selectedSource
            self.backgroundColor = backgroundColor
            self.content = content
            self.onDismiss = onDismiss
            synchronize()
        }

        private func synchronize() {
            guard !isDetached else { return }
            // A retained controller is not proof that UIKit still presents it.
            // Full-screen children may hide its view, but keep this relationship.
            if let host, phase == .presented,
               host.presentingViewController == nil,
               !host.isBeingPresented, !host.isBeingDismissed {
                finishDismissal(of: host)
                return
            }
            if !presentation.isPresented {
                guard let host, phase == .presented, !host.isBeingDismissed else { return }
                beginDismissal(of: host)
                host.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak host] in
                    guard let self, let host else { return }
                    self.finishDismissal(of: host)
                }
                return
            }

            if host == nil {
                guard phase == .idle, viewIfLoaded?.window != nil,
                      presentedViewController == nil else { return }
                presentCard()
                return
            }
            guard let host, phase == .presented, !host.isBeingDismissed,
                  let sheet = host.sheetPresentationController else { return }
            presentation.sources.selectedID = selectedSource

            let rootChanged = installedIdentity != identity
            if rootChanged {
                selectionRevision &+= 1
                pendingNativeSelection = nil
                presentation.motion.isPaging = false
            }
            // A swipe owns the intermediate height until its cursor commits.
            // Other SwiftUI updates still contain the previous page's fraction.
            if !presentation.motion.isPaging {
                _ = presentation.motion.updateCompactFraction(compactFraction)
            }
            let resolvedFraction = presentation.motion.compactFraction
            let sizeChanged = installedFraction != resolvedFraction || installedExpandedTopInset != expandedTopInset
            let target = (pendingNativeSelection ?? presentation.current.isExpanded)
                ? Self.expandedID : Self.compactID

            // Content uses its own settled canvas; it must not interpolate its
            // text or photo layout. Only UIKit animates the surrounding sheet.
            UIView.performWithoutAnimation {
                // The native sheet can still be tall while the fixed compact
                // content is already short. Fill that entire moving canvas;
                // never expose the system's white/material backing underneath.
                host.view.backgroundColor = self.backgroundColor
                self.installedIdentity = self.identity
                self.installedFraction = resolvedFraction
                self.installedExpandedTopInset = self.expandedTopInset
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { host.rootView = self.content }
            }

            if sizeChanged || (pendingNativeSelection == nil && sheet.selectedDetentIdentifier != target) {
                isApplyingNativeState = true
                let apply = {
                    sheet.selectedDetentIdentifier = target
                    if sizeChanged { sheet.invalidateDetents() }
                }
                if UIAccessibility.isReduceMotionEnabled { apply() }
                else { sheet.animateChanges(apply) }
                isApplyingNativeState = false
            }
            host.isModalInPresentation = target == Self.expandedID
            sheet.prefersGrabberVisible = true
        }

        private func presentCard() {
            installedIdentity = identity
            installedFraction = compactFraction
            installedExpandedTopInset = expandedTopInset
            presentation.sources.selectedID = selectedSource
            presentation.motion.isPaging = false
            _ = presentation.motion.updateCompactFraction(compactFraction)
            let host = CardHostingController(rootView: content)
            host.onAppeared = { [weak self, weak host] in
                guard let self, let host, self.host === host, !self.isDetached else { return }
                // viewDidAppear precedes the initial present completion. Only
                // that completion may unlock an opening/queued close. Later
                // appearances also reconcile cancelled gestures/child covers.
                guard self.phase != .presenting, !host.isBeingPresented,
                      !host.isBeingDismissed, host.presentingViewController != nil else { return }
                self.phase = .presented
                self.presentation.nativeTransitionEnded()
                if !self.presentation.resumePendingPresentation() { self.synchronize() }
            }
            host.onDismissalBegan = { [weak self, weak host] in
                guard let self, let host else { return }
                self.beginDismissal(of: host)
            }
            host.onDismissed = { [weak self, weak host] in
                guard let self, let host else { return }
                self.finishDismissal(of: host)
            }
            host.modalPresentationStyle = .pageSheet
            host.view.backgroundColor = backgroundColor
            host.preferredTransition = .zoom { [weak self] _ in
                self?.presentation.sources.sourceView()
            }
            self.host = host
            guard let sheet = host.sheetPresentationController else {
                self.host = nil
                return
            }
            sheet.delegate = self
            sheet.detents = [
                .custom(identifier: Self.compactID) { [weak self] context in
                    guard let self else { return context.maximumDetentValue * 0.35 }
                    self.reportGeometry(maximum: context.maximumDetentValue)
                    return context.maximumDetentValue * (self.installedFraction ?? 0.35)
                },
                .custom(identifier: Self.expandedID) { [weak self] context in
                    max(1, context.maximumDetentValue - (self?.installedExpandedTopInset ?? 0))
                }
            ]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.largestUndimmedDetentIdentifier = Self.expandedID
            sheet.selectedDetentIdentifier = presentation.current.isExpanded ? Self.expandedID : Self.compactID
            host.isModalInPresentation = presentation.current.isExpanded
            phase = .presenting
            presentation.nativePresentationBegan()
            present(host, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak host] in
                // Zoom's completion can run before the sheet clears its own
                // transition bookkeeping. Drain intents on the next run loop,
                // never dismiss/re-present from inside that UIKit callback.
                DispatchQueue.main.async {
                    guard let self, let host, self.host === host, !self.isDetached,
                          self.phase == .presenting else { return }
                    self.phase = .presented
                    self.presentation.nativeTransitionEnded()
                    if !self.presentation.resumePendingPresentation() { self.synchronize() }
                }
            }
            // Rejected presentations don't deliver an appearance/completion.
            // Check the actual relationship next run loop, not an animation timer.
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, self.host === host, !self.isDetached,
                      self.phase == .presenting, host.presentingViewController == nil,
                      !host.isBeingPresented else { return }
                self.finishDismissal(of: host)
            }
        }

        private func reportGeometry(maximum: CGFloat) {
            guard let host, !isDetached, phase != .dismissing, !host.isBeingDismissed else { return }
            let bottom = host.sheetPresentationController?.containerView?.safeAreaInsets.bottom
                ?? viewIfLoaded?.window?.safeAreaInsets.bottom ?? 0
            presentation.motion.reportGeometry(maximumHeight: maximum, bottom: bottom) { [weak self, weak host] in
                guard let self, let host else { return false }
                return !self.isDetached && self.host === host && self.presentation.isPresented
                    && self.phase != .dismissing && !host.isBeingDismissed
            }
        }

        var allowsLayoutUpdates: Bool {
            !isDetached && phase == .presented && presentation.isPresented
                && installedIdentity == identity && host?.isBeingDismissed == false
        }

        /// The same live detent update used by Profile's mixed pager. Keep the
        /// original page canvases fixed; only the native sheet edge follows
        /// horizontal progress. No second animation when selection commits.
        func compactHeightChanged(animated: Bool) {
            guard allowsLayoutUpdates, !isInvalidatingHeight,
                  let sheet = host?.sheetPresentationController else { return }
            installedFraction = presentation.motion.compactFraction
            isInvalidatingHeight = true
            defer { isInvalidatingHeight = false }
            if animated, !UIAccessibility.isReduceMotionEnabled,
               sheet.selectedDetentIdentifier == Self.compactID {
                sheet.animateChanges { sheet.invalidateDetents() }
            } else {
                UIView.performWithoutAnimation {
                    sheet.invalidateDetents()
                    sheet.containerView?.layoutIfNeeded()
                }
            }
        }

        func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
            guard !isDetached, !isApplyingNativeState, phase == .presented,
                  let host, sheet === host.sheetPresentationController, !host.isBeingDismissed,
                  let installedIdentity, installedIdentity == identity,
                  sheet.selectedDetentIdentifier == Self.compactID
                    || sheet.selectedDetentIdentifier == Self.expandedID else { return }
            let expanded = sheet.selectedDetentIdentifier == Self.expandedID
            pendingNativeSelection = expanded
            selectionRevision &+= 1
            let revision = selectionRevision
            let selectedIdentity = installedIdentity
            host.isModalInPresentation = expanded
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDetached, self.selectionRevision == revision,
                      self.identity == selectedIdentity, self.installedIdentity == selectedIdentity,
                      self.presentation.isPresented,
                      self.phase == .presented else { return }
                self.pendingNativeSelection = nil
                let owner = self.presentation.current
                let target: PresentationDetent = expanded ? .large : owner.compactDetent
                if owner.detent != target { owner.detent = target }
            }
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            host?.sheetPresentationController?.selectedDetentIdentifier != Self.expandedID
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            guard let host, presentationController.presentedViewController === host else { return }
            beginDismissal(of: host)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let host, presentationController.presentedViewController === host else { return }
            finishDismissal(of: host)
        }

        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle {
            .none
        }

        private func beginDismissal(of closingHost: CardHostingController) {
            guard host === closingHost, !isDetached, phase != .dismissing else { return }
            phase = .dismissing
            presentation.nativeDismissalBegan(of: installedIdentity ?? identity)
            selectionRevision &+= 1
            pendingNativeSelection = nil
        }

        private func finishDismissal(of dismissedHost: CardHostingController) {
            guard host === dismissedHost else { return }
            let dismissedIdentity = presentation.closingContent ?? installedIdentity
            dismissedHost.onAppeared = nil
            dismissedHost.onDismissalBegan = nil
            dismissedHost.onDismissed = nil
            dismissedHost.sheetPresentationController?.delegate = nil
            host = nil
            phase = .idle
            installedIdentity = nil
            installedFraction = nil
            installedExpandedTopInset = nil
            presentation.nativeTransitionEnded()
            selectionRevision &+= 1
            pendingNativeSelection = nil
            if dismissedIdentity == identity {
                presentation.nativePresentationChanged(false)
            }
            onDismiss()
            // A tap received while closing is handled at the native completion,
            // not by a delay or a second simultaneous modal presentation.
            if !isDetached {
                // A resumed selection publishes fresh SwiftUI content. Its
                // update supplies the new root/size/source together; don't
                // present the previous cached root under the new identity.
                if !presentation.resumePendingPresentation() { synchronize() }
            }
        }

        func detach() {
            isDetached = true
            presentation.motion.detach(self)
            presentation.discardPendingPresentation()
            selectionRevision &+= 1
            pendingNativeSelection = nil
            if let host {
                host.dismiss(animated: false)
                finishDismissal(of: host)
            }
        }

        private static func validFraction(_ value: CGFloat) -> CGFloat {
            value.isFinite ? min(0.9, max(0.15, value)) : 0.35
        }

        private static func validExpandedTopInset(_ value: CGFloat) -> CGFloat {
            value.isFinite ? max(0, value) : 0
        }
    }
}

/// Sheet delegates do not cover every native/programmatic dismissal (including
/// zoom). Observe the presented controller itself, without treating a photo or
/// profile's full-screen cover as dismissal of the card underneath it.
@MainActor
private final class CardHostingController: UIHostingController<AnyView> {
    var onAppeared: (() -> Void)?
    var onDismissalBegan: (() -> Void)?
    var onDismissed: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { [weak self] in self?.onAppeared?() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController?.isBeingDismissed == true {
            onDismissalBegan?()
            transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled {
                    DispatchQueue.main.async { [weak self] in self?.onAppeared?() }
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil
                || presentingViewController?.isBeingDismissed == true else { return }
        // UIKit severs its presentation relationship after this callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController == nil,
                  !self.isBeingPresented else { return }
            self.onDismissed?()
        }
    }
}

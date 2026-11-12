import SwiftUI
import Testing
import UIKit
@testable import maptalk

/// These exercise UIKit's actual presentation lifecycle. In particular, an
/// external dismiss must work without the test supplying a delegate callback.
@Suite(.serialized)
@MainActor
struct HomeCardNativePresenterTests {
    @Test
    func externalNativeDismissRestoresEntryAndAllowsAnotherOpen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let first = try #require(fixture.card)
        #expect(fixture.model.isMounted)

        // UIAdaptivePresentationControllerDelegate does not receive DidDismiss
        // for this path. The hosting controller must reconcile its own removal.
        first.dismiss(animated: false)
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        #expect(fixture.events.completedDismissals == 1)

        // Reopening resolves the control at its new position, not the source
        // frame used for the first card.
        let movedCenter = CGPoint(x: 240, y: 310)
        fixture.postSource.center = movedCenter
        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let second = try #require(fixture.card)
        #expect(second !== first)
        #expect(fixture.model.isPresented)
        #expect(fixture.model.isMounted)
        #expect(fixture.model.sources.sourceView() === fixture.postSource)
        #expect(fixture.model.sources.sourceView()?.center == movedCenter)
    }

    @Test
    func returningPostEntryBecomesHittableAfterActualNativeClose() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }
        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let card = try #require(fixture.card)
        let probe = NativeSourceHitProbe(window: fixture.window, source: fixture.postSource, card: card)
        probe.start()
        defer { probe.stop() }

        card.dismiss(animated: true)
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        #expect(try await waitFor { probe.sourceIsHittable })
        probe.stop()
        print("[NativeSourceHit] completed frames=\(probe.sampleCount) sourceHittable=\(probe.sourceIsHittable)")
        #expect(probe.sampleCount > 0,
                "Sample the real native return animation rather than only a directly reopened model")
        #expect(fixture.events.completedDismissals == 1)
    }

    @Test
    func fullscreenContentDoesNotDismissItsUnderlyingCard() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let card = try #require(fixture.card)
        let photo = UIViewController()
        photo.view.backgroundColor = .black
        photo.modalPresentationStyle = .fullScreen
        card.present(photo, animated: false)
        #expect(try await waitFor { photo.presentingViewController != nil && !photo.isBeingPresented })

        // A full-screen photo can make the card disappear from its window,
        // but the native presenting relationship still owns that card.
        fixture.synchronize()
        #expect(fixture.model.isPresented)
        #expect(fixture.model.isMounted)
        #expect(fixture.events.completedDismissals == 0)
        #expect(fixture.card === card)

        photo.dismiss(animated: false)
        #expect(try await waitFor { card.presentedViewController == nil && card.viewIfLoaded?.window != nil })
        fixture.synchronize()
        #expect(fixture.card === card)
        #expect(fixture.model.isPresented)
        #expect(fixture.events.completedDismissals == 0)
    }

    @Test
    func poiAndPostReplaceContentAndSizeInsideTheSameNativeCard() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.personStory)
        #expect(try await waitFor { fixture.hasSettledCard })
        let card = try #require(fixture.card)
        let poiHeight = card.view.bounds.height
        #expect(poiHeight > 0)

        fixture.open(.posts)
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.48) })
        #expect(fixture.card === card)
        #expect(fixture.model.activeFlow == .posts)
        #expect(fixture.model.posts.detent == .fraction(0.48))

        fixture.open(.personStory)
        #expect(try await waitFor { abs(card.view.bounds.height - poiHeight) < 2 })
        #expect(fixture.card === card)
        #expect(fixture.model.poi.detent == .fraction(0.35))
        #expect(fixture.events.completedDismissals == 0)
    }

    @Test
    func newerRequestSurvivesAnActualAnimatedDismissal() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let outgoing = try #require(fixture.card)
        let previousPOIRevision = fixture.model.poi.contentRevision

        outgoing.dismiss(animated: true)
        #expect(outgoing.isBeingDismissed,
                "The new request must arrive while the old native card is actually closing")
        fixture.open(.posts) // Superseded by the latest request below.
        fixture.open(.personStory)
        #expect(fixture.events.appliedFlows == [.posts],
                "Queued taps must not mutate the shared content observed by the departing card")
        #expect(fixture.model.poi.contentRevision == previousPOIRevision)
        #expect(fixture.model.activeFlow == .posts)
        #expect(fixture.model.mountedFlow == .posts,
                "The closing Post still owns its source artwork and placement")
        #expect(fixture.model.sources.sourceView() === fixture.postSource,
                "A pending POI cannot replace the Post's return source mid-dismissal")
        #expect(try await waitFor {
            fixture.hasSettledCard && fixture.card !== outgoing
        })

        #expect(fixture.model.isPresented)
        #expect(fixture.model.isMounted)
        #expect(fixture.model.activeFlow == .personStory)
        #expect(fixture.model.poi.contentRevision == previousPOIRevision + 1)
        #expect(fixture.events.appliedFlows == [.posts, .personStory],
                "Only the latest pending request should run after the old card is cleaned up")
        #expect(fixture.model.poi.detent == .fraction(0.35))
        #expect(fixture.model.sources.sourceView() === fixture.poiSource)
        #expect(fixture.model.closingContent == nil)
        #expect(fixture.events.completedDismissals == 1,
                "The old card closes once before the queued flow is installed")
    }

    @Test
    func sameFlowNewRequestSurvivesThePreviousCardsDismissal() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let outgoing = try #require(fixture.card)
        let previousRevision = fixture.model.posts.contentRevision

        outgoing.dismiss(animated: true)
        #expect(outgoing.isBeingDismissed)
        fixture.open(.posts)
        #expect(fixture.model.posts.contentRevision == previousRevision)
        #expect(fixture.events.appliedFlows == [.posts],
                "Even a same-flow request must leave the closing content unchanged")
        #expect(try await waitFor { fixture.hasSettledCard && fixture.card !== outgoing })

        #expect(fixture.model.isPresented)
        #expect(fixture.model.isMounted)
        #expect(fixture.model.posts.contentRevision == previousRevision + 1)
        #expect(fixture.events.appliedFlows == [.posts, .posts])
        #expect(fixture.model.posts.detent == .fraction(0.48))
        #expect(fixture.model.closingContent == nil)
        #expect(fixture.events.completedDismissals == 1,
                "The previous Post must finish cleanup before its replacement opens")
    }

    @Test
    func closeRequestedDuringOpeningCompletesAndCanReopen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        let opening = try #require(fixture.card)
        #expect(opening.isBeingPresented,
                "Exercise a close during the actual opening transition, not after it")
        fixture.close()
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        #expect(fixture.model.closingContent == nil)
        #expect(fixture.events.completedDismissals == 1)

        fixture.open(.personStory)
        #expect(try await waitFor { fixture.hasSettledCard })
        #expect(fixture.model.activeFlow == .personStory)
        #expect(fixture.model.poi.detent == .fraction(0.35))
    }

    @Test
    func explicitCloseDuringOpeningDiscardsAnOlderQueuedPOIRequest() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        let opening = try #require(fixture.card)
        #expect(opening.isBeingPresented)
        fixture.open(.personStory)
        #expect(fixture.events.appliedFlows == [.posts])
        #expect(fixture.model.activeFlow == .posts)

        // The latest explicit intent is now "close", not the earlier POI tap.
        fixture.close()
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        // Also allow the completion's next-run-loop work to execute, so a late
        // queued reopen cannot make an initially closed result look successful.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(fixture.card == nil)
        #expect(!fixture.model.isPresented)
        #expect(!fixture.model.isMounted)
        #expect(fixture.model.closingContent == nil)
        #expect(fixture.events.appliedFlows == [.posts],
                "Closing must discard the queued POI action instead of reopening it later")
        #expect(fixture.events.completedDismissals == 1)
    }

    @Test
    func repeatedMixedCardCyclesKeepNativeSizeAndLifecycleConsistent() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        for cycle in 0..<2 {
            fixture.open(.personStory)
            #expect(try await waitFor { fixture.hasSettledCard })
            let card = try #require(fixture.card)
            let poiHeight = card.view.bounds.height

            fixture.open(.posts)
            #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.48) })
            let postHeight = card.view.bounds.height
            fixture.setExpanded(true)
            #expect(try await waitFor { card.view.bounds.height > postHeight + 20 })
            #expect(fixture.model.posts.isExpanded)
            fixture.setExpanded(false)
            #expect(try await waitFor { abs(card.view.bounds.height - postHeight) < 2 })
            #expect(fixture.card === card,
                    "Expanded-to-compact must not dismiss and recreate the card")

            fixture.open(.personStory)
            #expect(try await waitFor { abs(card.view.bounds.height - poiHeight) < 2 })
            #expect(fixture.card === card)
            #expect(!fixture.model.poi.isExpanded)
            fixture.close()
            #expect(try await waitFor {
                fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
            })
            #expect(fixture.model.closingContent == nil)
            #expect(fixture.events.completedDismissals == cycle + 1)
        }
    }

    @Test
    func outgoingPOIDetentCallbacksCannotExpandTheIncomingPost() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // Cover both a late callback and a callback accepted just before the
        // selection changes whose deferred model write arrives afterward.
        for callbackBeforeSelection in [false, true] {
            let fixture = NativeHomeCardFixture(scene: scene)
            defer { fixture.dispose() }
            fixture.open(.personStory)
            #expect(try await waitFor { fixture.hasSettledCard })
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            let card = try #require(fixture.card)
            let sheet = try #require(card.sheetPresentationController)
            let expandedID = try #require(sheet.detents.last?.identifier)

            if callbackBeforeSelection {
                sheet.selectedDetentIdentifier = expandedID
                fixture.presenter.sheetPresentationControllerDidChangeSelectedDetentIdentifier(sheet)
            }
            // Intentionally do not update the native presenter yet: the
            // controller still contains POI while the logical selection is Post.
            fixture.model.perform(in: .posts) { fixture.model.posts.presentNewContent() }
            #expect(fixture.model.activeFlow == .posts)
            if !callbackBeforeSelection {
                sheet.selectedDetentIdentifier = expandedID
                fixture.presenter.sheetPresentationControllerDidChangeSelectedDetentIdentifier(sheet)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(!fixture.model.posts.isExpanded,
                    "The departing POI's detent must not become the new Post's detent")
            #expect(fixture.model.posts.detent == .fraction(0.48))

            fixture.synchronize()
            #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.48) })
            #expect(fixture.card === card)
            #expect(!fixture.model.posts.isExpanded)
            #expect(sheet.selectedDetentIdentifier == sheet.detents.first?.identifier)
        }
    }

    @Test
    func defaultCloseKeepsExpandedDetentUntilNativeRemovalCompletes() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let card = try #require(fixture.card)
        let sheet = try #require(card.sheetPresentationController)
        let compactHeight = card.view.bounds.height
        fixture.setExpanded(true)
        #expect(try await waitFor { card.view.bounds.height > compactHeight + 20 })
        let expandedID = try #require(sheet.selectedDetentIdentifier)
        #expect(fixture.model.posts.isExpanded)

        fixture.model.dismiss() // Exercise the default, not preservingDetent: true.
        #expect(!fixture.model.isPresented)
        #expect(fixture.model.posts.isExpanded,
                "Closing must not first relayout the departing card to compact")
        fixture.synchronize()
        #expect(card.isBeingDismissed)
        #expect(fixture.model.posts.isExpanded)
        #expect(sheet.selectedDetentIdentifier == expandedID)
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        #expect(fixture.model.posts.detent == .fraction(0.48),
                "Reset the next opening's detent only after the native card is gone")
        #expect(fixture.events.completedDismissals == 1)
    }

    @Test
    func postBackdropSurvivesResizingAndRestoresPOICanvasWhenSwitching() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }

        fixture.postBackgroundColor = .black
        fixture.open(.posts)
        #expect(try await waitFor { fixture.hasSettledCard })
        let card = try #require(fixture.card)
        let compactHeight = card.view.bounds.height
        let originalStyle = card.overrideUserInterfaceStyle
        #expect(card.view.backgroundColor == UIColor.black,
                "The first native frame must have the Post's backdrop, not clear glass")

        for color in [UIColor.black, UIColor.white] {
            // The second pass also exercises a palette update without replacing
            // the content identity or changing the underlying map's UI traits.
            fixture.postBackgroundColor = color
            fixture.synchronize()
            #expect(card.view.backgroundColor == color)
            fixture.setExpanded(true)
            #expect(try await waitFor { card.view.bounds.height > compactHeight + 20 })
            #expect(card.view.backgroundColor == color)
            fixture.setExpanded(false)
            #expect(try await waitFor { abs(card.view.bounds.height - compactHeight) < 2 })
            #expect(card.view.backgroundColor == color)
            #expect(card.overrideUserInterfaceStyle == originalStyle)
            #expect(fixture.card === card)
        }

        fixture.open(.personStory)
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.35) })
        #expect(card.view.backgroundColor == UIColor.clear,
                "POI must regain its own translucent canvas rather than inherit Post color")
        #expect(card.overrideUserInterfaceStyle == originalStyle)
        #expect(fixture.card === card)
    }

    @Test
    func floatingPOIHeaderReservesOnlyExpandedTopSpace() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }
        fixture.open(.personStory)
        #expect(try await waitFor {
            fixture.hasSettledCard && fixture.matchesCompactHeight(fraction: 0.35)
        })
        let card = try #require(fixture.card)
        let sheet = try #require(card.sheetPresentationController)
        let maximum = fixture.model.motion.maximumDetentHeight
        let bottom = fixture.model.motion.bottomSafeArea
        let expandedHeight = maximum - 80 + bottom
        #expect(sheet.prefersGrabberVisible,
                "The floating identity bar must keep the normal native card grabber")
        let surface = try #require(sheet.presentedView)

        func expectPOICanvas() {
            #expect(card.view.backgroundColor == UIColor.clear,
                    "The floating POI bar must not require an opaque host backdrop")
            #expect(fixture.card === card)
        }
        expectPOICanvas()

        fixture.setExpanded(true)
        #expect(try await waitFor { abs(card.view.bounds.height - expandedHeight) < 2 })
        expectPOICanvas()

        fixture.setExpanded(false)
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.35) })
        expectPOICanvas()

        fixture.postBackgroundColor = .white
        fixture.open(.posts)
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.48) })
        #expect(sheet.prefersGrabberVisible)
        #expect(card.view.backgroundColor == UIColor.white)
        #expect(fixture.card === card,
                "Switching to Posts must keep the same native host")
        fixture.setExpanded(true)
        #expect(try await waitFor { abs(card.view.bounds.height - (maximum + bottom)) < 2 },
                "Posts use the full expanded height without a floating POI header inset")

        // Validate the return direction after UIKit resizes the same native host.
        fixture.open(.personStory)
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.35) })
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(try await waitFor { nativeSurfaceHasSettled(surface) })
        expectPOICanvas()

        fixture.setExpanded(true)
        #expect(try await waitFor {
            abs(card.view.bounds.height - expandedHeight) < 2 && nativeSurfaceHasSettled(surface)
        })
        expectPOICanvas()

        // An interrupted resize must keep the POI canvas, never flash the
        // previous Post palette. Deliberately no wait between requests.
        fixture.setExpanded(false)
        fixture.setExpanded(true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(try await waitFor {
            abs(card.view.bounds.height - expandedHeight) < 2 && nativeSurfaceHasSettled(surface)
        })
        expectPOICanvas()
    }

    @Test
    func pagingFractionDrivesNativeHeightWithoutChangingSelectionOrRevivingClosedCard() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = NativeHomeCardFixture(scene: scene)
        defer { fixture.dispose() }
        fixture.open(.personStory)
        #expect(try await waitFor {
            fixture.hasSettledCard && fixture.presenter.allowsLayoutUpdates
                && fixture.matchesCompactHeight(fraction: 0.35)
        })
        let card = try #require(fixture.card)
        let sheet = try #require(card.sheetPresentationController)
        let compactID = sheet.selectedDetentIdentifier
        let revision = fixture.model.poi.contentRevision
        let motion = fixture.model.motion

        motion.isPaging = true
        for fraction in [CGFloat(0.40), CGFloat(0.48)] {
            motion.setCompactFraction(fraction)
            #expect(try await waitFor { fixture.matchesCompactHeight(fraction: fraction) })
            #expect(motion.compactFraction == fraction)
            #expect(fixture.model.activeFlow == .personStory)
            #expect(fixture.model.poi.contentRevision == revision)
            #expect(fixture.model.poi.detent == .fraction(0.35),
                    "Continuous page height is not a logical card selection or detent change")
            #expect(sheet.selectedDetentIdentifier == compactID)

            // SwiftUI may rebuild the old selected page mid-gesture. Its .35
            // input must not overwrite the pager's live interpolated fraction.
            fixture.synchronize()
            #expect(motion.isPaging)
            #expect(motion.compactFraction == fraction)
            #expect(try await waitFor { fixture.matchesCompactHeight(fraction: fraction) })
            #expect(fixture.card === card)
        }

        motion.setCompactFraction(0.35) // Cancel the page gesture.
        motion.isPaging = false
        fixture.synchronize()
        #expect(try await waitFor { fixture.matchesCompactHeight(fraction: 0.35) })
        #expect(fixture.model.poi.contentRevision == revision)

        fixture.setExpanded(true)
        let fullHeight = motion.maximumDetentHeight - 80 + motion.bottomSafeArea
        #expect(try await waitFor { abs(card.view.bounds.height - fullHeight) < 2 })
        let expandedID = sheet.selectedDetentIdentifier
        motion.isPaging = true
        motion.setCompactFraction(0.48)
        fixture.synchronize()
        #expect(motion.compactFraction == 0.48)
        #expect(fixture.model.poi.isExpanded)
        #expect(sheet.selectedDetentIdentifier == expandedID)
        #expect(abs(card.view.bounds.height - fullHeight) < 2,
                "Changing the compact stop must not resize an expanded native card")

        motion.isPaging = false
        fixture.close()
        let closingFraction = motion.compactFraction
        motion.setCompactFraction(0.60)
        #expect(motion.compactFraction == closingFraction,
                "A departing pager cannot update the native return animation")
        #expect(try await waitFor {
            fixture.card == nil && !fixture.model.isPresented && !fixture.model.isMounted
        })
        let closedFraction = motion.compactFraction
        motion.setCompactFraction(0.70)
        #expect(motion.compactFraction == closedFraction,
                "A stale page callback after native removal must also be ignored")
        #expect(fixture.card == nil)
        #expect(fixture.events.completedDismissals == 1)
    }

    private func nativeSurfaceHasSettled(_ surface: UIView) -> Bool {
        guard let presentation = surface.layer.presentation() else { return true }
        let actual = presentation.frame
        let target = surface.layer.frame
        return abs(actual.minX - target.minX) < 1 && abs(actual.minY - target.minY) < 1
            && abs(actual.width - target.width) < 1 && abs(actual.height - target.height) < 1
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
private final class NativeHomeCardFixture {
    final class Events {
        var completedDismissals = 0
        var appliedFlows: [MapTalkFeedPresentation] = []
    }

    let model: MapTalkCardPresentation
    let events: Events
    let window: UIWindow
    let root: UIViewController
    let presenter: HomeCardNativePresenter.Controller
    let postSource: UIView
    let poiSource: UIView
    var postBackgroundColor: UIColor = .clear
    private let poiID = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!

    init(scene: UIWindowScene) {
        let model = MapTalkCardPresentation(poiCompactFraction: 0.35, postCompactFraction: 0.48)
        let events = Events()
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        self.model = model
        self.events = events
        self.window = window
        self.root = root
        postSource = UIView(frame: CGRect(x: 24, y: 440, width: 56, height: 66))
        poiSource = UIView(frame: CGRect(x: 40, y: 110, width: 56, height: 56))
        window.frame = scene.coordinateSpace.bounds
        // A real native hierarchy, kept behind the application. Never change
        // the app's key window, navigate its UI, or touch its actual feed.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        presenter = HomeCardNativePresenter.Controller(
            presentation: model, compactFraction: 0.35, expandedTopInset: 80,
            selectedSource: nil, backgroundColor: .clear,
            content: AnyView(Text("Native lifecycle fixture")),
            onDismiss: {
                if !model.didDismiss(model.activeFlow) { events.completedDismissals += 1 }
            })
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.addChild(presenter)
        presenter.view.frame = root.view.bounds
        presenter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(presenter.view)
        presenter.didMove(toParent: root)

        root.view.addSubview(postSource)
        root.view.addSubview(poiSource)
        model.sources.register(postSource, id: .posts)
        model.sources.register(poiSource, id: .poi(.author(poiID)))
        window.isHidden = false
        root.view.layoutIfNeeded()
    }

    var card: UIViewController? {
        presenter.presentedViewController ?? root.presentedViewController
    }

    var hasSettledCard: Bool {
        guard let card else { return false }
        return card.presentingViewController != nil && card.viewIfLoaded?.window != nil
            && !card.isBeingPresented && !card.isBeingDismissed
    }

    func matchesCompactHeight(fraction: CGFloat) -> Bool {
        guard let card, model.motion.maximumDetentHeight > 0 else { return false }
        let maximum = model.motion.maximumDetentHeight
        let expected = maximum * fraction + model.motion.bottomSafeArea
        return abs(card.view.bounds.height - expected) < 2
    }

    func open(_ flow: MapTalkFeedPresentation) {
        model.perform(in: flow) { [weak self] in
            guard let self else { return }
            // A shared selection probe: this must not change until the queued
            // action actually runs. Synchronize as the app's SwiftUI host would.
            self.events.appliedFlows.append(flow)
            self.model.current.presentNewContent()
            self.synchronize()
        }
    }

    func close() {
        model.dismiss(preservingDetent: true)
        synchronize()
    }

    func setExpanded(_ expanded: Bool) {
        if expanded { model.current.expand() }
        else { model.current.collapseToCompact() }
        synchronize()
    }

    func synchronize() {
        let model = model
        let events = events
        let isPost = model.activeFlow == .posts
        presenter.update(compactFraction: isPost ? 0.48 : 0.35,
                         expandedTopInset: isPost ? 0 : 80,
                         selectedSource: isPost ? .posts : .poi(.author(poiID)),
                         backgroundColor: isPost ? postBackgroundColor : .clear,
                         content: AnyView(Text(isPost ? "Post content" : "POI content")),
                         onDismiss: {
                             if !model.didDismiss(model.activeFlow) { events.completedDismissals += 1 }
                         })
    }

    func dispose() {
        presenter.detach()
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// A bounded diagnostic of actual window hit testing during UIKit's return.
/// Native target class names are logged, never used as pass/fail criteria.
@MainActor
private final class NativeSourceHitProbe: NSObject {
    private let window: UIWindow
    private let source: UIView
    private weak var card: UIViewController?
    private var displayLink: CADisplayLink?
    private(set) var sampleCount = 0

    init(window: UIWindow, source: UIView, card: UIViewController) {
        self.window = window
        self.source = source
        self.card = card
    }

    private var sourceCenter: CGPoint {
        source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: window)
    }

    var sourceIsHittable: Bool {
        guard let target = window.hitTest(sourceCenter, with: nil) else { return false }
        return target === source || target.isDescendant(of: source)
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func sample() {
        sampleCount += 1
        let target = window.hitTest(sourceCenter, with: nil)
        let targetName = target.map { String(describing: type(of: $0)) } ?? "nil"
        print("[NativeSourceHit] frame=\(sampleCount) time=\(CACurrentMediaTime()) closing=\(card?.isBeingDismissed == true) center=\(sourceCenter) target=\(targetName) sourceHittable=\(sourceIsHittable)")
    }
}

import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
@testable import maptalk

@MainActor
struct FriendStoryNavigationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func scopedHeaderRoomKeepsOriginalCardHeightAndRestoresOrdinaryDetent() {
        let base = PresentationDetent.fraction(0.35)
        let story = PresentationDetent.fraction(FriendStoryLayout.compactFraction(base: 0.35, availableHeight: 800))
        let presentation = MapExperiencePresentation(compactDetent: base)
        presentation.configureCompactDetent(story)
        #expect(presentation.compactDetent == story)
        #expect(presentation.detent == story)
        presentation.isPresented = true
        presentation.detent = .large
        presentation.configureCompactDetent(.fraction(0.45))
        #expect(presentation.detent == .large, "A geometry change must not collapse the story")
        presentation.dismiss(preservingDetent: true)
        #expect(!presentation.didDismiss())
        presentation.configureCompactDetent(base)
        #expect(presentation.compactDetent == base)
        #expect(presentation.detent == base, "Ordinary map cards retain their original height")
    }

    @Test
    func storyCompactAllowanceIsBoundedAndIndependentOfTheCurrentPage() {
        #expect(abs(FriendStoryLayout.compactFraction(base: 0.35, availableHeight: 800) * 800
            - (0.35 * 800 + FriendStoryLayout.navigationAllowance)) < 0.001)
        #expect(FriendStoryLayout.compactFraction(base: 0.35, availableHeight: 0) == 0.35)
        #expect(FriendStoryLayout.compactFraction(base: 0.35, availableHeight: 100) == 0.55)
    }

    @Test
    func viewportResizeReframesTheSamePlaceWithoutReflyingOrdinarySlices() {
        let nav = FriendStoryNavigation()
        let portrait = CGSize(width: 400, height: 800)
        let landscape = CGSize(width: 800, height: 400)
        #expect(nav.needsMapFocus(locationKey: "place:one", viewportSize: portrait))
        nav.lastLocationKey = "place:one"
        nav.lastViewportSize = portrait
        #expect(!nav.needsMapFocus(locationKey: "place:one", viewportSize: portrait))
        #expect(nav.needsMapFocus(locationKey: "place:one", viewportSize: landscape))
        #expect(nav.needsMapFocus(locationKey: "place:two", viewportSize: portrait))
        nav.clear()
        #expect(nav.lastViewportSize == nil)
        #expect(nav.needsMapFocus(locationKey: "place:one", viewportSize: portrait))
    }

    @Test
    func expandedPlaceEntrySynchronizesDeferredMapButCompactSamePlaceDoesNotFlyAgain() {
        #expect(FriendStoryFlow.shouldFocusPlace(isCurrentPlace: true, isExpanded: true))
        #expect(!FriendStoryFlow.shouldFocusPlace(isCurrentPlace: true, isExpanded: false))
        #expect(FriendStoryFlow.shouldFocusPlace(isCurrentPlace: false, isExpanded: true))
        #expect(FriendStoryFlow.shouldFocusPlace(isCurrentPlace: false, isExpanded: false))
    }

    @Test
    func storyCloseKeepsExpandedCardUntilNativeDismissalCompletes() {
        let presentation = MapExperiencePresentation(compactDetent: .fraction(0.35))
        presentation.isPresented = true
        presentation.detent = .large
        presentation.dismiss(preservingDetent: true)
        #expect(!presentation.isPresented)
        #expect(presentation.detent == .large)
        let reopened = presentation.didDismiss()
        #expect(!reopened)
        #expect(presentation.detent == .fraction(0.35))

        presentation.isPresented = true
        presentation.detent = .large
        presentation.dismiss()
        #expect(!presentation.isPresented)
        #expect(presentation.detent == .fraction(0.35))
    }

    @Test
    func beginningAnotherAuthorPreservesOriginalMapAndPerAuthorCursor() throws {
        let nav = FriendStoryNavigation()
        let groups = fixtures()
        let original = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: original)
        #expect(nav.isActive)
        #expect(nav.session?.movePage(by: 1) == true)
        let resumedID = nav.session?.currentPage?.id
        nav.begin(groups: groups, authorID: bob, viewedKeys: [], origin: snapshot(latitude: 1, longitude: 2))
        #expect(nav.session?.selectedAuthorID == bob)
        #expect(nav.origin?.region?.center.latitude == original.region?.center.latitude)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: snapshot(latitude: 3, longitude: 4))
        #expect(nav.session?.currentPage?.id == resumedID)
        #expect(nav.origin?.region?.center.longitude == original.region?.center.longitude)
    }

    @Test
    func explicitRailSelectionExitsNestedRouteWithoutDiscardingStoryCursor() throws {
        let nav = FriendStoryNavigation()
        let groups = fixtures()
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(nav.session?.movePage(by: 1) == true)
        let selectedID = nav.session?.currentPage?.id
        let child = reel(id: 900, author: bob, ago: 10)
        nav.routes.append(.init(content: .reel(child),
            returnCamera: snapshot(latitude: 38, longitude: -120), returnDetent: .large))
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: snapshot(latitude: 10, longitude: 20))
        #expect(nav.routes.isEmpty)
        #expect(nav.session?.currentPage?.id == selectedID)
        #expect(nav.session?.currentPageIndex == 1)
    }

    @Test
    func childRouteStoresExactParentCameraDetentAndDoesNotChangeStorySelection() throws {
        let nav = FriendStoryNavigation()
        nav.begin(groups: fixtures(), authorID: alice, viewedKeys: [], origin: snapshot(latitude: 47.6, longitude: -122.3))
        let selected = nav.session?.currentPage?.id
        let manuallyPanned = snapshot(latitude: 12.34, longitude: 56.78)
        nav.routes.append(.init(content: .reel(reel(id: 900, author: bob, ago: 10)),
            returnCamera: manuallyPanned, returnDetent: .large))
        nav.routes.append(.init(content: .reel(reel(id: 901, author: bob, ago: 9)),
            returnCamera: snapshot(latitude: -20, longitude: 130), returnDetent: .fraction(0.35)))
        let poppedNested = nav.routes.popLast()
        let nested = try #require(poppedNested)
        #expect(nested.returnDetent == .fraction(0.35))
        #expect(nav.routes.count == 1)
        let poppedParent = nav.routes.popLast()
        let parent = try #require(poppedParent)
        #expect(parent.returnCamera.region?.center.latitude == 12.34)
        #expect(parent.returnCamera.region?.center.longitude == 56.78)
        #expect(parent.returnDetent == .large)
        #expect(nav.session?.currentPage?.id == selected)
    }

    @Test
    func clearRemovesEveryAccountSpecificNavigationValue() throws {
        let nav = FriendStoryNavigation()
        nav.begin(groups: fixtures(), authorID: alice, viewedKeys: [], origin: snapshot(latitude: 47.6, longitude: -122.3))
        nav.lastLocationKey = "place:old-user"
        nav.routes.append(.init(content: .reel(reel(id: 900, author: bob, ago: 10)),
            returnCamera: snapshot(latitude: 12, longitude: 56), returnDetent: .large))
        nav.clear()
        #expect(!nav.isActive)
        #expect(nav.session == nil)
        #expect(nav.origin == nil)
        #expect(nav.routes.isEmpty)
        #expect(nav.lastLocationKey == nil)
    }

    @Test
    func invalidBeginDoesNotCaptureOriginOrDiscardCurrentNestedRoute() {
        let nav = FriendStoryNavigation()
        let target = snapshot(latitude: 12, longitude: 56)
        nav.begin(groups: [], authorID: alice, viewedKeys: [], origin: target)
        #expect(!nav.isActive)
        #expect(nav.origin == nil)
        nav.begin(groups: fixtures(), authorID: alice, viewedKeys: [], origin: target)
        nav.routes.append(.init(content: .reel(reel(id: 900, author: bob, ago: 10)),
            returnCamera: target, returnDetent: .large))
        let selected = nav.session?.currentPage?.id
        nav.begin(groups: [], authorID: UUID(), viewedKeys: [], origin: target)
        #expect(nav.routes.count == 1)
        #expect(nav.session?.currentPage?.id == selected)
    }

    private func fixtures() -> [FriendStoryGroup] {
        FriendStoryFeed.groups(reals: [reel(id: 201, author: alice, ago: 100),
            reel(id: 202, author: alice, ago: 50), reel(id: 203, author: bob, ago: 20)],
            ratedPOIs: [], userProvider: { _ in nil }, now: now)
    }

    private func reel(id: Int, author: UUID, ago: TimeInterval) -> RealPost {
        let created = now.addingTimeInterval(-ago)
        return .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            userId: author, center: .init(latitude: 47.6, longitude: -122.3), radiusMeters: 220,
            message: "Original card", attachments: [], likes: [], comments: [], visibility: .publicAll,
            createdAt: created, expiresAt: created.addingTimeInterval(StoryReadKeys.freshWindow))
    }

    private func snapshot(latitude: Double, longitude: Double) -> FriendStoryNavigation.MapSnapshot {
        .init(camera: nil, region: .init(center: .init(latitude: latitude, longitude: longitude),
            span: .init(latitudeDelta: 0.1, longitudeDelta: 0.2)))
    }
}

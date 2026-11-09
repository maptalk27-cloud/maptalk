import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

private struct NativeStoryExpandedTestDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        max(1, context.maxDetentValue - 80)
    }
}

@MainActor
struct FriendStoryNavigationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func progressTapSelectsTheExactUpdateAcrossSparseAndDenseStories() {
        for count in [1, 3, 12, 19, 90] {
            for index in 0..<count {
                let x = (CGFloat(index) + 0.5) / CGFloat(count) * 360
                #expect(FriendStoryProgressSelection.index(at: x, width: 360, count: count) == index)
            }
        }
        #expect(FriendStoryProgressSelection.index(at: 0, width: 300, count: 3) == 0)
        #expect(FriendStoryProgressSelection.index(at: 100, width: 300, count: 3) == 1)
        #expect(FriendStoryProgressSelection.index(at: 200, width: 300, count: 3) == 2)
        #expect(FriendStoryProgressSelection.index(at: 300, width: 300, count: 3) == 2)
    }

    @Test
    func progressTapClampsEdgesAndRejectsUnavailableGeometry() {
        #expect(FriendStoryProgressSelection.index(at: -20, width: 300, count: 3) == 0)
        #expect(FriendStoryProgressSelection.index(at: 320, width: 300, count: 3) == 2)
        #expect(FriendStoryProgressSelection.index(at: 10, width: 0, count: 3) == nil)
        #expect(FriendStoryProgressSelection.index(at: 10, width: -1, count: 3) == nil)
        #expect(FriendStoryProgressSelection.index(at: 10, width: 300, count: 0) == nil)
        #expect(FriendStoryProgressSelection.index(at: 10, width: 300, count: -1) == nil)
        #expect(FriendStoryProgressSelection.index(at: .nan, width: 300, count: 3) == nil)
        #expect(FriendStoryProgressSelection.index(at: 10, width: .infinity, count: 3) == nil)
    }

    @Test
    func staticPositionFillsOnlyTheCurrentAndEarlierSegments() {
        for count in [1, 3, 12, 19, 90] {
            for index in 0..<count {
                let fills = (0..<count).map { FriendStoryProgressSelection.fill(for: $0, index: index) }
                #expect(fills == (0..<count).map { $0 <= index ? CGFloat(1) : CGFloat(0) })
                #expect(fills.reduce(0, +) == CGFloat(index + 1))
            }
        }
    }

    @Test
    func staticPositionMovesBackWithSelectionAndRejectsNegativeIndices() {
        let forward = (0..<3).map { FriendStoryProgressSelection.fill(for: $0, index: 2) }
        let backward = (0..<3).map { FriendStoryProgressSelection.fill(for: $0, index: 0) }
        #expect(forward == [1, 1, 1])
        #expect(backward == [1, 0, 0],
                "Going back reflects the selected position, not a retained playback history")
        #expect(FriendStoryProgressSelection.fill(for: 0, index: -1) == 0)
        #expect(FriendStoryProgressSelection.fill(for: -1, index: 2) == 0)
        #expect(FriendStoryProgressSelection.fill(for: -1, index: -1) == 0)
    }

    @Test
    func progressControlsResolveOnlyPagesBelongingToTheirCurrentPerson() throws {
        let groups = fixtures()
        let ownGroup = try #require(groups.first { $0.authorID == alice })
        let otherPage = try #require(groups.first { $0.authorID == bob }?.pages.first)
        for (index, page) in ownGroup.pages.enumerated() {
            #expect(FriendStoryPageSelection.index(for: page.id, in: ownGroup) == index)
        }
        #expect(FriendStoryPageSelection.index(for: otherPage.id, in: ownGroup) == nil)
        #expect(FriendStoryPageSelection.index(for: "missing-page", in: ownGroup) == nil)
        let empty = FriendStoryGroup(authorID: alice, user: nil, pages: [])
        #expect(FriendStoryPageSelection.index(for: ownGroup.pages[0].id, in: empty) == nil)
    }

    @Test
    func nativeCardPagerKeepsTheSameFlattenedOrderAcrossAuthorSelections() throws {
        let groups = cardPagerFixtures()
        var session = try #require(FriendStorySession(groups: groups, authorID: alice))
        let expectedIDs = groups.flatMap(\.pages).map(\.id)
        #expect(FriendStoryPageSelection.pagerPages(in: session).map(\.id) == expectedIDs)
        for group in groups {
            session.selectAuthor(id: group.authorID)
            session.selectPage(id: group.pages.last!.id)
            #expect(FriendStoryPageSelection.pagerPages(in: session).map(\.id) == expectedIDs,
                    "Changing people must not reindex the mounted native pager during a swipe")
        }
        #expect(Set(expectedIDs).count == expectedIDs.count)
        session.end()
        #expect(FriendStoryPageSelection.pagerPages(in: session).isEmpty)
    }

    @Test
    func forwardCardBoundarySelectsNextAuthorsFirstPageInsteadOfItsSavedUnreadCursor() throws {
        let nav = FriendStoryNavigation()
        let groups = authorSequenceFixtures()
        let aliceGroup = try #require(groups.first)
        let bobGroup = try #require(groups.last)
        let origin = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: groups, authorID: bob, viewedKeys: [bobGroup.pages[0].readKey], origin: origin)
        #expect(nav.session?.currentPage?.id == bobGroup.pages[1].id)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: origin)
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.session?.selectedAuthorID == bob)
        #expect(nav.session?.currentPage?.id == bobGroup.pages[0].id,
                "A continuous forward swipe lands on the physically adjacent first card")
        #expect(nav.session?.resumePageIDs[bob] == bobGroup.pages[0].id)
        #expect(nav.session?.resumePageIDs[alice] == aliceGroup.pages[1].id)
        #expect(nav.origin?.region?.center.latitude == origin.region?.center.latitude)
        let selectedSession = try #require(nav.session)
        #expect(FriendStoryPageSelection.pagerPages(in: selectedSession).map(\.id)
                == groups.flatMap(\.pages).map(\.id))
    }

    @Test
    func backwardCardBoundarySelectsPreviousAuthorsLastPageAndCanReverseExactly() throws {
        let nav = FriendStoryNavigation()
        let groups = authorSequenceFixtures()
        let aliceGroup = try #require(groups.first)
        let bobGroup = try #require(groups.last)
        let origin = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: origin)
        #expect(nav.session?.currentPage?.id == aliceGroup.pages[0].id)
        nav.begin(groups: groups, authorID: bob, viewedKeys: [], origin: origin)
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.session?.selectedAuthorID == alice)
        #expect(nav.session?.currentPage?.id == aliceGroup.pages[1].id,
                "Backward swiping ignores the previous person's saved first-page cursor")
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.session?.currentPage?.id == bobGroup.pages[0].id)
    }

    @Test
    func cardPagerRejectsWrongEdgesSkippedAuthorsAndNonadjacentDestinationPages() throws {
        let nav = FriendStoryNavigation()
        let groups = cardPagerFixtures()
        let aliceGroup = groups[0]
        let bobGroup = groups[1]
        let thirdGroup = groups[2]
        nav.begin(groups: groups, authorID: alice, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(!nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id),
                "Only the current author's last page may cross forward")
        #expect(!nav.selectPagerPage(id: thirdGroup.pages.last!.id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id),
                "The first author cannot wrap backward to the final author")
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: thirdGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages.last!.id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id),
                "Only the current author's first page may cross backward")
        #expect(nav.selectPagerPage(id: thirdGroup.pages[0].id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: thirdGroup.pages[1].id, fromAuthorID: thirdGroup.authorID, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages[0].id, fromAuthorID: thirdGroup.authorID, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: thirdGroup.pages[1].id, fromAuthorID: thirdGroup.authorID, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: "missing-page", fromAuthorID: thirdGroup.authorID, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.session?.currentPage?.id == thirdGroup.pages[1].id)
    }

    @Test
    func sixSamePlaceSlicesRejectSkippedPageAndReverseExactlyOneAtATime() throws {
        let group = try samePlacePagerFixture()
        let pages = group.pages
        let nav = FriendStoryNavigation()
        nav.begin(groups: [group], authorID: alice, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(nav.session?.selectPage(id: pages[7].id) == true)
        #expect(nav.session?.currentPageIndex == 7)
        #expect(!nav.selectPagerPage(id: pages[3].id, fromAuthorID: alice, fromPageID: pages[7].id),
                "A stale native pager value must not skip from the sixth slice to the second")
        #expect(nav.session?.currentPageIndex == 7)

        for target in stride(from: 6, through: 2, by: -1) {
            #expect(nav.selectPagerPage(id: pages[target].id, fromAuthorID: alice,
                                       fromPageID: pages[target + 1].id))
            #expect(nav.session?.currentPageIndex == target,
                    "Each reverse swipe selects exactly one media slice, including 7 → 6")
            #expect(nav.session?.currentPage?.locationKey == pages[7].locationKey)
        }
        #expect(nav.selectPagerPage(id: pages[1].id, fromAuthorID: alice, fromPageID: pages[2].id),
                "The first slice still crosses backward into the immediately preceding post")
        #expect(nav.selectPagerPage(id: pages[2].id, fromAuthorID: alice, fromPageID: pages[1].id))
        #expect(nav.session?.currentPageIndex == 2)
        #expect(nav.session?.selectPage(id: pages[7].id) == true,
                "Explicit progress selection remains free to jump; adjacency belongs only to swipes")
    }

    @Test
    func staleSameAuthorRenderCannotSelectEvenAnAdjacentPage() throws {
        let group = try samePlacePagerFixture()
        let pages = group.pages
        let nav = FriendStoryNavigation()
        nav.begin(groups: [group], authorID: alice, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(nav.session?.selectPage(id: pages[7].id) == true)
        let departedPageID = pages[7].id
        #expect(nav.selectPagerPage(id: pages[6].id, fromAuthorID: alice, fromPageID: departedPageID))
        #expect(!nav.selectPagerPage(id: pages[5].id, fromAuthorID: alice, fromPageID: departedPageID),
                "Even an adjacent destination is invalid when its callback belongs to the previous render")
        #expect(!nav.selectPagerPage(id: pages[7].id, fromAuthorID: alice, fromPageID: departedPageID),
                "The old rendered page cannot pull the just-completed reverse swipe back forward")
        #expect(nav.session?.currentPageIndex == 6)
        #expect(nav.selectPagerPage(id: pages[5].id, fromAuthorID: alice, fromPageID: pages[6].id))
        #expect(nav.session?.currentPageIndex == 5)
    }

    @Test
    func queuedCardPagerCallbacksCannotChangeAnotherAuthorOrCoveredParent() throws {
        let nav = FriendStoryNavigation()
        let groups = authorSequenceFixtures()
        let aliceGroup = groups[0]
        let bobGroup = groups[1]
        let origin = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: origin)
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        nav.routes.append(.init(content: .reel(reel(id: 900, author: bob, ago: 10)),
                                returnCamera: origin, returnDetent: .large))
        #expect(!nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.session?.currentPage?.id == aliceGroup.pages[1].id)
        nav.routes.removeAll()
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id),
                "A delayed selection from the departed author's render cannot reverse the swipe")
        #expect(nav.session?.currentPage?.id == bobGroup.pages[0].id)
        nav.clear()
        #expect(!nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: bob, fromPageID: bobGroup.pages[0].id))
    }

    @Test
    func singlePageAuthorsSupportBothCardBoundariesWithoutWrapping() throws {
        let groups = cardPagerFixtures().map {
            FriendStoryGroup(authorID: $0.authorID, user: $0.user, pages: [$0.pages[0]])
        }
        let nav = FriendStoryNavigation()
        nav.begin(groups: groups, authorID: bob, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(nav.selectPagerPage(id: groups[0].pages[0].id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: groups[2].pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: groups[1].pages[0].id, fromAuthorID: alice, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: groups[2].pages[0].id, fromAuthorID: bob, fromPageID: nav.session!.currentPage!.id))
        #expect(!nav.selectPagerPage(id: groups[0].pages[0].id, fromAuthorID: groups[2].authorID, fromPageID: nav.session!.currentPage!.id))
        #expect(nav.selectPagerPage(id: groups[1].pages[0].id, fromAuthorID: groups[2].authorID, fromPageID: nav.session!.currentPage!.id))
    }

    @Test
    func ownSingleAuthorSequenceStillPagesForwardAndBackWithoutAnotherPerson() throws {
        for authorID in [PreviewData.currentUser.id, alice] {
            let groups = FriendStoryFeed.groups(
                reals: [reel(id: 201, author: authorID, ago: 100),
                        reel(id: 202, author: authorID, ago: 50)],
                ratedPOIs: [], userProvider: { _ in nil }, now: now
            )
            let group = try #require(groups.first)
            var session = try #require(FriendStorySession(groups: groups, authorID: authorID))
            let movedToAnotherAuthor = session.moveAuthor(by: 1)
            #expect(!movedToAnotherAuthor, "A one-person feed has no second author")
            let movedBeforeStart = session.movePage(by: -1)
            #expect(!movedBeforeStart)
            #expect(session.currentPageIndex == 0)

            let next = try #require(FriendStoryPageSelection.index(for: group.pages[1].id, in: group))
            let current = try #require(session.currentPageIndex)
            let movedForward = session.movePage(by: next - current)
            #expect(movedForward)
            #expect(session.currentPage?.id == group.pages[1].id)
            #expect(session.selectedAuthorID == authorID)
            let movedAfterEnd = session.movePage(by: 1)
            #expect(!movedAfterEnd, "The last post does not implicitly change people")
            #expect(session.currentPageIndex == 1)

            let previous = try #require(FriendStoryPageSelection.index(for: group.pages[0].id, in: group))
            let last = try #require(session.currentPageIndex)
            let movedBack = session.movePage(by: previous - last)
            #expect(movedBack)
            #expect(session.currentPage?.id == group.pages[0].id)
            #expect(session.selectedAuthorID == authorID)
            let movedToSamePage = session.movePage(by: 0)
            #expect(!movedToSamePage)
        }
    }

    @Test
    func ownAndOtherAuthorsUseTheSameLocationFocusRules() throws {
        let viewport = CGSize(width: 400, height: 800)
        for authorID in [PreviewData.currentUser.id, alice] {
            var distantReel = reel(id: 202, author: authorID, ago: 50)
            distantReel.center = .init(latitude: 21.28, longitude: -157.83)
            let groups = FriendStoryFeed.groups(
                reals: [reel(id: 201, author: authorID, ago: 100), distantReel],
                ratedPOIs: [], userProvider: { _ in nil }, now: now
            )
            let nav = FriendStoryNavigation()
            nav.begin(groups: groups, authorID: authorID, viewedKeys: [],
                      origin: snapshot(latitude: 47.6, longitude: -122.3))
            let firstKey = try #require(nav.session?.currentPage?.locationKey)
            #expect(nav.needsMapFocus(locationKey: firstKey, viewportSize: viewport))
            nav.lastLocationKey = firstKey
            nav.lastViewportSize = viewport
            #expect(nav.session?.movePage(by: 1) == true)
            let next = try #require(nav.session?.currentPage)
            let nextKey = try #require(next.locationKey)
            #expect(next.authorID == authorID)
            #expect(next.coordinate?.latitude == 21.28)
            #expect(nav.needsMapFocus(locationKey: nextKey, viewportSize: viewport),
                    "A new location must focus even when all posts belong to the current user")
        }
    }

    @Test
    func exactPOISlicesAvoidDuplicateFlightButAnotherAuthorRefocusesThePlace() throws {
        let currentUserID = PreviewData.currentUser.id
        let otherUserID = currentUserID == alice ? bob : alice
        let photo = URL(fileURLWithPath: "/tmp/friend-story-navigation-photo.jpg")
        let ownVisit = RatedPOI.CheckIn(
            id: UUID(), userId: currentUserID, createdAt: now.addingTimeInterval(-100),
            media: [.init(id: UUID(), kind: .photo(photo)), .init(id: UUID(), kind: .photo(photo))]
        )
        let friendVisit = RatedPOI.CheckIn(
            id: UUID(), userId: otherUserID, createdAt: now.addingTimeInterval(-50),
            media: [.init(id: UUID(), kind: .photo(photo))]
        )
        let place = RatedPOI(
            poi: .init(id: UUID(), name: "Shared place", coordinate: .init(latitude: 47.6, longitude: -122.3),
                       category: .coffee),
            highlight: nil, secondary: nil, media: ownVisit.media + friendVisit.media,
            checkIns: [ownVisit, friendVisit], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0
        )
        let groups = FriendStoryFeed.groups(reals: [], ratedPOIs: [place], userProvider: { _ in nil }, now: now)
        let nav = FriendStoryNavigation()
        nav.begin(groups: groups, authorID: currentUserID, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        let firstPageID = try #require(nav.session?.currentPage?.id)
        let sharedKey = try #require(nav.session?.currentPage?.locationKey)
        let viewport = CGSize(width: 400, height: 800)
        nav.lastLocationKey = sharedKey
        nav.lastViewportSize = viewport
        nav.lastFocusedAuthorID = currentUserID

        #expect(nav.session?.movePage(by: 1) == true)
        #expect(nav.session?.currentPage?.id != firstPageID)
        let secondKey = try #require(nav.session?.currentPage?.locationKey)
        #expect(secondKey == sharedKey)
        #expect(!nav.needsMapFocus(locationKey: secondKey, viewportSize: viewport, authorID: currentUserID))

        #expect(nav.session?.selectAuthor(id: otherUserID) == true)
        let friendKey = try #require(nav.session?.currentPage?.locationKey)
        #expect(friendKey == sharedKey)
        #expect(nav.needsMapFocus(locationKey: friendKey, viewportSize: viewport, authorID: otherUserID),
                "Changing people refocuses their selected place even after a manual pan")
    }

    @Test(arguments: [false, true])
    func childOpenedDuringFlightReturnsToPendingDestinationNotStaleDeparture(usesNeighborhood: Bool) throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 21.33147, longitude: -157.92001)
        let target = flightRegion(latitude: 19.73698, longitude: -156.04092)
        let viewport = MapCameraViewport(size: CGSize(width: 400, height: 800),
                                         topInset: 110, bottomInset: 380)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            viewport: viewport,
            browsingCoordinates: usesNeighborhood ? nearbyStops(around: target.center) : nil,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        let landing = try #require(controller.pendingLandingRegion)
        #expect(landing.center.distance(to: origin.center) > 200_000)
        #expect(abs(landing.center.longitude - target.center.longitude) < 0.000_001)
        #expect(controller.isTransitionInProgress)
        controller.observeCamera(region: origin)
        let stillPending = try #require(controller.pendingLandingRegion)
        #expect(stillPending.center.latitude == landing.center.latitude,
                "A live departure observation must not replace the selected post's return destination")
        #expect(stillPending.span.latitudeDelta == landing.span.latitudeDelta)
        controller.cancelActiveTransition()
        #expect(controller.pendingLandingRegion == nil)
        #expect(!controller.isTransitionInProgress)
    }

    @Test(arguments: [false, true])
    func nearbyBrowsingFramesDenseStopsWithoutLiftWhileOrdinarySelectionKeepsItsZoom(usesNeighborhood: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let target = flightRegion(latitude: 47.601, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            browsingCoordinates: usesNeighborhood ? nearbyStops(around: target.center) : nil,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        #expect(probe.writes.count == 1)
        #expect(probe.writes.first?.region != nil,
                "A nearby swipe uses the existing direct move, not a mandatory lift")
        try await waitForFlight { !probe.updates.isEmpty }
        let landing = try #require(probe.position.region)
        #expect(landing.center.latitude == target.center.latitude)
        #expect(landing.center.longitude == target.center.longitude)
        #expect(probe.writes.count == 1)
        #expect(probe.updates.count == 1)
        if usesNeighborhood {
            let expected = MKCoordinateRegion(center: target.center,
                latitudinalMeters: 800, longitudinalMeters: 800)
            #expect(abs(landing.span.latitudeDelta - expected.span.latitudeDelta) < 0.000_001)
            #expect(abs(landing.span.longitudeDelta - expected.span.longitudeDelta) < 0.000_001)
            #expect(landing.span.latitudeDelta < origin.span.latitudeDelta / 10)
        } else {
            #expect(landing.span.latitudeDelta == origin.span.latitudeDelta)
            #expect(landing.span.longitudeDelta == origin.span.longitudeDelta)
        }
    }

    @Test
    func denseBrowsingKeepsOneScaleWhenMovingForwardAndBack() async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let coordinates = nearbyStops(around: .init(latitude: 47.601, longitude: -122.3))
        var current = flightRegion(latitude: 47.6, longitude: -122.3)
        let probe = FlightProbe(position: .region(current))
        var firstSpan: MKCoordinateSpan?
        for index in [1, 2, 1, 0] {
            let target = flightRegion(latitude: coordinates[index].latitude,
                                      longitude: coordinates[index].longitude)
            let previousWrites = probe.writes.count
            let previousUpdates = probe.updates.count
            controller.observeCamera(region: current)
            controller.handleRegionChange(
                currentRegion: current, targetRegion: target, cause: .poi,
                browsingCoordinates: coordinates,
                cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
            )
            try await waitForFlight { probe.updates.count > previousUpdates }
            let landing = try #require(probe.position.region)
            #expect(probe.writes.count == previousWrites + 1, "Nearby browsing never adds a lift stage")
            #expect(landing.center.latitude == target.center.latitude)
            #expect(landing.center.longitude == target.center.longitude)
            if let firstSpan {
                #expect(abs(landing.span.latitudeDelta / firstSpan.latitudeDelta - 1) < 0.01)
                #expect(abs(landing.span.longitudeDelta / firstSpan.longitudeDelta - 1) < 0.01,
                        "Reversing within the same neighborhood must not pump the zoom")
            } else {
                firstSpan = landing.span
            }
            current = landing
        }
        #expect(probe.updates.count == 4)
    }

    @Test
    func distantBrowsingRetainsLegacyThreeStagesAndLandsAtNeighborhoodScale() async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let target = flightRegion(latitude: 48.45, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin), controller: controller)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            browsingCoordinates: nearbyStops(around: target.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(probe.writes.count == 1)
            #expect(probe.writes.first?.camera != nil)
            #expect(probe.updates.isEmpty)
        }
        try await waitForFlight { !probe.updates.isEmpty }
        let landing = try #require(probe.position.region)
        let expected = MKCoordinateRegion(center: target.center,
            latitudinalMeters: 800, longitudinalMeters: 800)
        #expect(landing.center.latitude == target.center.latitude)
        #expect(landing.center.longitude == target.center.longitude)
        #expect(abs(landing.span.latitudeDelta - expected.span.latitudeDelta) < 0.000_001)
        #expect(abs(landing.span.longitudeDelta - expected.span.longitudeDelta) < 0.000_001)
        #expect(probe.updates.count == 1)
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(probe.writes.count == 3, "Neighborhood framing changes landing scale, not legacy flight stages")
            let travel = try #require(probe.writes[1].camera)
            #expect(travel.centerCoordinate.latitude == target.center.latitude)
            #expect(travel.centerCoordinate.longitude == target.center.longitude)
        }
    }

    @Test
    func rapidReturnToNearbyDenseStopCancelsTheDistantLanding() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let oldTarget = flightRegion(latitude: 48.45, longitude: -122.3)
        let newTarget = flightRegion(latitude: 47.601, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin), controller: controller)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: oldTarget, cause: .real,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        // Reverse while the actual camera is still in the neighborhood.
        // The observed camera, not the obsolete destination, determines the path.
        controller.observeCamera(region: origin)
        let replacementStart = probe.writes.count
        controller.handleRegionChange(
            currentRegion: oldTarget, targetRegion: newTarget, cause: .poi,
            browsingCoordinates: nearbyStops(around: newTarget.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        try await waitForFlight { !probe.updates.isEmpty }
        try await Task.sleep(for: .seconds(1))
        let replacementWrites = Array(probe.writes.dropFirst(replacementStart))
        #expect(replacementWrites.count == 1)
        let landing = try #require(replacementWrites.first?.region)
        #expect(landing.center.latitude == newTarget.center.latitude)
        #expect(landing.center.longitude == newTarget.center.longitude)
        #expect(landing.span.latitudeDelta < origin.span.latitudeDelta / 10)
        #expect(probe.updates.count == 1, "Canceled lift/cruise callbacks cannot settle the old destination")
        controller.observeCameraEnd()
        #expect(controller.pendingLandingRegion == nil)
        #expect(!controller.isTransitionInProgress)
    }

    @Test(arguments: [false, true])
    func distantReelAndPOISelectionsLiftTravelAndLand(isPOI: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        // About 95 km: beyond the removed 80 km shortcut, but inside the
        // original controller's short staged-flight band for a fast test.
        let target = flightRegion(latitude: 48.45, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin), controller: controller)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: isPOI ? .poi : .real,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )

        if !UIAccessibility.isReduceMotionEnabled {
            #expect(probe.writes.count == 1)
            #expect(probe.writes.first?.camera != nil, "A remote selection must lift, not jump directly to a region")
            #expect(probe.updates.isEmpty, "Selection is not settled while the map is lifting")
        }
        try await waitForFlight { !probe.updates.isEmpty }
        let landed = try #require(probe.position.region)
        #expect(landed.center.latitude == target.center.latitude)
        #expect(landed.center.longitude == target.center.longitude)
        #expect(probe.updates.count == 1)
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(probe.writes.count == 3, "The shared flight is lift, travel, then landing")
            let travel = try #require(probe.writes.dropFirst().first?.camera)
            #expect(travel.centerCoordinate.latitude == target.center.latitude)
            #expect(travel.centerCoordinate.longitude == target.center.longitude)
            #expect(probe.writes.last?.region != nil)
        }
    }

    @Test(arguments: [30_000.0, 350_000.0, 700_000.0], [false, true])
    func honoluluLanaiBrowsingStillFliesWhenBothIslandsFitOnScreen(observedSpan: Double, reverse: Bool) async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // Rounded place coordinates from the reported route. "Lanai Air" is
        // on Oahu; Lanai Airport is on Lanai, about 116 km away.
        let honolulu = CLLocationCoordinate2D(latitude: 21.32272, longitude: -157.91080)
        let lanai = CLLocationCoordinate2D(latitude: 20.79060, longitude: -156.94978)
        let departure = reverse ? lanai : honolulu
        let destination = reverse ? honolulu : lanai
        let current = MKCoordinateRegion(center: departure,
            latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        let observed = MKCoordinateRegion(center: departure,
            latitudinalMeters: observedSpan * 2, longitudinalMeters: observedSpan)
        let target = MKCoordinateRegion(center: destination,
            latitudinalMeters: 3_600, longitudinalMeters: 3_600)
        let viewport = MapCameraViewport(size: CGSize(width: 390, height: 844),
            topInset: 140, bottomInset: 370)
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let probe = FlightProbe(position: .region(observed), controller: controller)
        // The live viewport, not the older selection region, owns the camera.
        controller.observeCamera(region: observed)
        controller.handleRegionChange(currentRegion: current, targetRegion: target,
            cause: reverse ? .real : .poi, viewport: viewport,
            browsingCoordinates: [departure, destination],
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })

        try #require(probe.position.camera != nil,
            "Being visible in a wide viewport must not turn an inter-island flight into a direct move")
        #expect(probe.updates.isEmpty)
        try await waitForFlight { !probe.updates.isEmpty }
        #expect(probe.writes.count == 3, "Keep the original lift, travel and landing")
        let cruise = try #require(probe.writes.dropFirst().first?.camera)
        #expect(cruise.centerCoordinate.latitude == destination.latitude)
        #expect(cruise.centerCoordinate.longitude == destination.longitude)
        let landing = try #require(probe.position.region)
        let expected = viewport.framed(.init(center: destination,
            latitudinalMeters: 20_000, longitudinalMeters: 20_000))
        #expect(abs(landing.center.latitude - expected.center.latitude) < 0.000_001)
        #expect(abs(landing.center.longitude - expected.center.longitude) < 0.000_001)
        #expect(abs(landing.span.latitudeDelta - expected.span.latitudeDelta) < 0.000_001,
            "Land at the destination's scale instead of keeping the island-wide overview")
    }

    @Test
    func broadRequestedRegionDoesNotTurnADistantFlightIntoATightZoomShortcut() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = MKCoordinateRegion(center: .init(latitude: 21.32272, longitude: -157.91080),
            latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        let target = MKCoordinateRegion(center: .init(latitude: 20.79060, longitude: -156.94978),
            latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        let probe = FlightProbe(position: .region(origin))
        controller.observeCamera(region: origin)
        controller.handleRegionChange(currentRegion: origin, targetRegion: target, cause: .poi,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        #expect(probe.position.camera != nil,
            "The second preserve-zoom shortcut must also respect the existing distant-flight plan")
    }

    @Test
    func rapidSelectionCancelsThePreviousFlightsPendingLanding() async throws {
        // The direct Reduce Motion path has no queued landing to cancel; the
        // parameterized test above still verifies its final region for both types.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let oldTarget = flightRegion(latitude: 48.45, longitude: -122.3)
        let newTarget = flightRegion(latitude: 47.6, longitude: -121.0)
        let probe = FlightProbe(position: .region(origin), controller: controller)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: oldTarget, cause: .real,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        try await waitForFlight { probe.writes.count >= 2 }
        #expect(probe.updates.isEmpty)
        let replacementStart = probe.writes.count

        controller.handleRegionChange(
            currentRegion: origin, targetRegion: newTarget, cause: .poi,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        try await waitForFlight { !probe.updates.isEmpty }
        let landings = probe.writes.dropFirst(replacementStart).compactMap(\.region)
        #expect(landings.count == 1, "The canceled flight must not write its old landing behind the new selection")
        #expect(probe.updates.count == 1, "Only the latest selection may commit its settled region")
        let landing = try #require(landings.first)
        #expect(landing.center.latitude == newTarget.center.latitude)
        #expect(landing.center.longitude == newTarget.center.longitude)
        let update = try #require(probe.updates.first)
        #expect(update.center.longitude == newTarget.center.longitude)
    }

    @Test
    func rapidSelectionDoesNotPreserveThePreviousFlightsLiftedWorldZoom() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let firstTarget = flightRegion(latitude: 21.28, longitude: -157.83)
        let nextTarget = flightRegion(latitude: 48.45, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin), controller: controller)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: firstTarget, cause: .real,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        #expect(probe.position.camera != nil)

        // MapKit reports intermediate zoom-out regions back to the host while
        // the staged flight is still active. A quick swipe must not interpret
        // this huge visible span as the user's chosen scale and preserve it.
        let liftedRegion = MKCoordinateRegion(
            center: origin.center, latitudinalMeters: 1_000_000, longitudinalMeters: 1_000_000
        )
        controller.handleRegionChange(
            currentRegion: liftedRegion, targetRegion: nextTarget, cause: .poi,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        try await waitForFlight { !probe.updates.isEmpty }
        let landed = try #require(probe.position.region)
        #expect(landed.center.latitude == nextTarget.center.latitude)
        #expect(landed.center.longitude == nextTarget.center.longitude)
        #expect(landed.span.latitudeDelta <= nextTarget.span.latitudeDelta * 1.15,
                "The latest post must land at city scale, not inherit the interrupted flight's zoom-out")
        #expect(landed.span.longitudeDelta <= nextTarget.span.longitudeDelta * 1.15)
        #expect(landed.span.latitudeDelta < liftedRegion.span.latitudeDelta / 10)
        #expect(probe.updates.count == 1)
    }

    @Test
    func expandedPostEntryCancelsPendingCompactReset() async {
        let presentation = MapExperiencePresentation(compactDetent: .fraction(0.35))
        presentation.collapseToCompact()
        presentation.presentExpandedContent()

        // Drain the reset queued by collapseToCompact before checking the result.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(presentation.isPresented)
        #expect(presentation.isExpanded)
        #expect(!presentation.isResettingPresentation)

        presentation.dismiss(preservingDetent: true)
        #expect(!presentation.didDismiss())
        presentation.presentNewContent()
        #expect(presentation.detent == .fraction(0.35), "POI entries still open compact")
    }

    @Test
    func largerPostPreviewDoesNotLeakIntoCompactPOIBrowsing() {
        let poi = PresentationDetent.fraction(0.35)
        let post = PresentationDetent.fraction(0.44)
        let presentation = MapExperiencePresentation(compactDetent: poi)
        presentation.isPresented = true
        for detent in [post, poi, post, poi] {
            presentation.configureCompactDetent(detent)
            #expect(presentation.compactDetent == detent)
            #expect(presentation.detent == detent)
            #expect(presentation.isPresented)
            #expect(!presentation.isResettingPresentation,
                    "Switching compact flows resizes the same native sheet")
        }
    }

    @Test
    func nativeCompactCallbacksCannotRestoreThePreviousFlowHeight() {
        let poi = PresentationDetent.fraction(0.35)
        let post = PresentationDetent.fraction(0.44)
        for (previous, target) in [(poi, post), (post, poi)] {
            let presentation = MapExperiencePresentation(compactDetent: previous)
            presentation.isPresented = true
            let outgoing = presentation.nativeDetentSelection()

            presentation.configureCompactDetent(target)
            presentation.presentNewContent()
            let incoming = presentation.nativeDetentSelection()

            // UIKit may finish the outgoing sheet's selection after SwiftUI
            // has already supplied the new compact height and content.
            outgoing.wrappedValue = previous
            outgoing.wrappedValue = .large
            incoming.wrappedValue = previous
            #expect(presentation.compactDetent == target)
            #expect(presentation.detent == target)
            #expect(incoming.wrappedValue == target)
            #expect(!presentation.isResettingPresentation)

            incoming.wrappedValue = .large
            #expect(presentation.isExpanded)
            incoming.wrappedValue = target
            #expect(presentation.detent == target)
        }
    }

    @Test
    func nativeCallbacksFromReplacedContentAreIgnoredEvenAtTheSameHeight() {
        let compact = PresentationDetent.fraction(0.35)
        let presentation = MapExperiencePresentation(compactDetent: compact)
        presentation.isPresented = true
        let outgoing = presentation.nativeDetentSelection()
        presentation.presentNewContent()

        outgoing.wrappedValue = .large
        #expect(presentation.detent == compact)
        let incoming = presentation.nativeDetentSelection()
        incoming.wrappedValue = .large
        #expect(presentation.isExpanded)
        incoming.wrappedValue = compact
        #expect(!presentation.isExpanded)
    }

    @Test
    func nativeDetentBindingMapsCustomExpansionAndRejectsUnknownValues() {
        let compact = PresentationDetent.fraction(0.35)
        let expanded = PresentationDetent.custom(NativeStoryExpandedTestDetent.self)
        let presentation = MapExperiencePresentation(compactDetent: compact)
        presentation.isPresented = true
        let story = presentation.nativeDetentSelection(expandedDetent: expanded)

        story.wrappedValue = .fraction(0.8)
        story.wrappedValue = .large
        #expect(presentation.detent == compact)
        story.wrappedValue = expanded
        #expect(presentation.detent == .large)
        #expect(story.wrappedValue == expanded)
        story.wrappedValue = compact
        #expect(story.wrappedValue == compact)

        let post = presentation.nativeDetentSelection()
        post.wrappedValue = expanded
        #expect(presentation.detent == compact)
        post.wrappedValue = .large
        #expect(post.wrappedValue == .large)
    }

    @Test
    func nativeDetentCallbacksCannotInterruptAnInternalPresentationReset() {
        let compact = PresentationDetent.fraction(0.35)
        let presentation = MapExperiencePresentation(compactDetent: compact)
        presentation.isPresented = true
        presentation.detent = .large
        presentation.presentNewContent()
        #expect(presentation.isResettingPresentation)

        let duringReset = presentation.nativeDetentSelection()
        duringReset.wrappedValue = .large
        #expect(presentation.detent == compact)
        #expect(presentation.isResettingPresentation)
    }

    @Test
    func compactGeometryChangesPreserveExpandedStateAndRestoreOrdinaryDetent() {
        let base = PresentationDetent.fraction(0.35)
        let story = PresentationDetent.fraction(0.4)
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
    func floatingIdentityKeepsMapGapDuringResizeAndDrag() {
        for width: CGFloat in [320, 402, 852] {
            for top: CGFloat in [144, 300, 600, 850] {
                let card = CGRect(x: 7, y: top, width: width, height: 300)
                let header = FriendStoryLayout.accessoryFrame(above: card)
                #expect(header.height == 68)
                #expect(card.minY - header.maxY == 12)
                #expect(header.midX == card.midX)
                #expect(header.width == card.width - 20)
            }
        }
    }

    @Test
    func floatingIdentityFadesWithDismissalAndRecoversOnCancellation() {
        #expect(FriendStoryLayout.accessoryOpacity(cardTop: 500, containerBottom: 850) == 1)
        #expect(FriendStoryLayout.accessoryOpacity(cardTop: 810, containerBottom: 850) == 0.5)
        #expect(FriendStoryLayout.accessoryOpacity(cardTop: 850, containerBottom: 850) == 0)
        #expect(FriendStoryLayout.accessoryOpacity(cardTop: 900, containerBottom: 850) == 0)
        #expect(FriendStoryLayout.accessoryOpacity(cardTop: 770, containerBottom: 850) == 1)
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
    func reopeningFullyReadOwnOrFriendStoryStartsAtBeginningButActiveReturnKeepsCursor() throws {
        for authorID in [PreviewData.currentUser.id, alice] {
            let groups = FriendStoryFeed.groups(
                reals: [reel(id: 201, author: authorID, ago: 100),
                        reel(id: 202, author: authorID, ago: 50)],
                ratedPOIs: [], userProvider: { _ in nil }, now: now
            )
            let pages = try #require(groups.first?.pages)
            let viewedKeys = Set(pages.map(\.readKey))
            let nav = FriendStoryNavigation()
            let origin = snapshot(latitude: 47.6, longitude: -122.3)
            nav.begin(groups: groups, authorID: authorID, viewedKeys: viewedKeys, origin: origin)
            #expect(nav.session?.currentPage?.id == pages[0].id,
                    "All-read stories replay from the start, including the current user's own posts")
            #expect(nav.session?.movePage(by: 1) == true)
            nav.begin(groups: groups, authorID: authorID, viewedKeys: viewedKeys, origin: origin)
            #expect(nav.session?.currentPage?.id == pages[1].id,
                    "Returning during the same browsing session must preserve the exact post")

            nav.clear()
            nav.begin(groups: groups, authorID: authorID, viewedKeys: viewedKeys, origin: origin)
            #expect(nav.session?.currentPage?.id == pages[0].id,
                    "Closing and opening an avatar again is a new visit, not a persistent last-post cursor")
        }
    }

    @Test
    func newlyOpenedOwnOrFriendStoryStillPrioritizesFirstUnreadPost() throws {
        for authorID in [PreviewData.currentUser.id, alice] {
            let groups = FriendStoryFeed.groups(
                reals: [reel(id: 201, author: authorID, ago: 100),
                        reel(id: 202, author: authorID, ago: 50),
                        reel(id: 203, author: authorID, ago: 20)],
                ratedPOIs: [], userProvider: { _ in nil }, now: now
            )
            let pages = try #require(groups.first?.pages)
            let nav = FriendStoryNavigation()
            nav.begin(groups: groups, authorID: authorID, viewedKeys: [pages[0].readKey],
                      origin: snapshot(latitude: 47.6, longitude: -122.3))
            #expect(nav.session?.currentPage?.id == pages[1].id)
        }
    }

    @Test
    func explicitAvatarReopenIncludesNewSamePlaceVisitWithoutResettingCurrentPage() throws {
        for authorID in [PreviewData.currentUser.id, alice] {
            let video = URL(fileURLWithPath: "/tmp/friend-story-visit.mp4")
            let first = RatedPOI.CheckIn(id: UUID(), userId: authorID,
                createdAt: now.addingTimeInterval(-100),
                media: [.init(id: UUID(), kind: .video(url: video, poster: nil))])
            let second = RatedPOI.CheckIn(id: UUID(), userId: authorID,
                createdAt: now.addingTimeInterval(-20),
                media: [.init(id: UUID(), kind: .video(url: video, poster: nil))])
            var place = RatedPOI(
                poi: .init(id: UUID(), name: "Four Seasons", coordinate: .init(latitude: 20.7, longitude: -156.9),
                           category: .other), highlight: nil, secondary: nil, media: [], checkIns: [first],
                comments: [], endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
                isFavoritedByCurrentUser: false, favoritesCount: 0)
            let initial = FriendStoryFeed.groups(reals: [], ratedPOIs: [place], userProvider: { _ in nil }, now: now)
            let nav = FriendStoryNavigation()
            let origin = snapshot(latitude: 47.6, longitude: -122.3)
            nav.begin(groups: initial, authorID: authorID, viewedKeys: [], origin: origin)
            let selected = try #require(nav.session?.currentPage?.id)

            place.checkIns.append(second)
            let refreshed = FriendStoryFeed.groups(reals: [], ratedPOIs: [place], userProvider: { _ in nil }, now: now)
            nav.session?.reconcile(with: refreshed, now: now)
            #expect(nav.session?.currentGroup?.pages.count == 1,
                    "Background updates must not insert a page during a swipe")
            nav.begin(groups: refreshed, authorID: authorID, viewedKeys: [],
                      origin: snapshot(latitude: 20.7, longitude: -156.9))
            #expect(nav.session?.currentGroup?.pages.count == 2)
            #expect(nav.session?.currentGroup?.moments.count == 1)
            #expect(nav.session?.currentPage?.id == selected)
            #expect(nav.origin?.region?.center.latitude == origin.region?.center.latitude)
            #expect(nav.session?.movePage(by: 1) == true)
            #expect(nav.session?.currentPage?.memoryID == second.id)

            nav.begin(groups: refreshed, authorID: authorID, viewedKeys: [], origin: origin)
            #expect(nav.session?.currentPage?.memoryID == second.id,
                    "Reopening an unchanged group preserves the active cursor")
        }
    }

    @Test
    func explicitAvatarRefreshDoesNotRestoreACursorForARemovedPost() throws {
        let first = reel(id: 201, author: alice, ago: 100)
        let removed = reel(id: 202, author: alice, ago: 50)
        let added = reel(id: 203, author: alice, ago: 10)
        let initial = FriendStoryFeed.groups(reals: [first, removed], ratedPOIs: [], userProvider: { _ in nil }, now: now)
        let nav = FriendStoryNavigation()
        let origin = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: initial, authorID: alice, viewedKeys: [], origin: origin)
        #expect(nav.session?.movePage(by: 1) == true)
        let firstReadKey = try #require(initial.first?.pages.first?.readKey)
        let refreshed = FriendStoryFeed.groups(reals: [first, added], ratedPOIs: [], userProvider: { _ in nil }, now: now)
        nav.begin(groups: refreshed, authorID: alice, viewedKeys: [firstReadKey], origin: origin)
        #expect(nav.session?.currentPage?.memoryID == added.id)
        #expect(nav.session?.groups.flatMap(\.pages).contains { $0.memoryID == removed.id } == false)
    }

    @Test
    func changingAuthorsRefocusesEvenAtTheSamePlaceButSameAuthorSlicesDoNot() {
        let nav = FriendStoryNavigation()
        let viewport = CGSize(width: 400, height: 800)
        nav.lastLocationKey = "place:shared"
        nav.lastViewportSize = viewport
        nav.lastFocusedAuthorID = alice
        #expect(!nav.needsMapFocus(locationKey: "place:shared", viewportSize: viewport, authorID: alice))
        #expect(nav.needsMapFocus(locationKey: "place:shared", viewportSize: viewport, authorID: bob),
                "A different person's entry must recover from a manually panned map")
        #expect(!nav.needsMapFocus(locationKey: "place:shared", viewportSize: viewport),
                "Existing callers without author context retain the original deduplication rule")
        nav.lastFocusedAuthorID = bob
        #expect(!nav.needsMapFocus(locationKey: "place:shared", viewportSize: viewport, authorID: bob))
        nav.clear()
        #expect(nav.lastFocusedAuthorID == nil)
        #expect(nav.needsMapFocus(locationKey: "place:shared", viewportSize: viewport, authorID: bob))
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

    private func authorSequenceFixtures() -> [FriendStoryGroup] {
        FriendStoryFeed.groups(reals: [reel(id: 201, author: alice, ago: 100),
            reel(id: 202, author: alice, ago: 50), reel(id: 203, author: bob, ago: 40),
            reel(id: 204, author: bob, ago: 20)], ratedPOIs: [], userProvider: { _ in nil }, now: now)
            .sorted { $0.authorID.uuidString < $1.authorID.uuidString }
    }

    private func cardPagerFixtures() -> [FriendStoryGroup] {
        let thirdAuthor = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let thirdGroup = FriendStoryFeed.groups(
            reals: [reel(id: 205, author: thirdAuthor, ago: 15), reel(id: 206, author: thirdAuthor, ago: 10)],
            ratedPOIs: [], userProvider: { _ in nil }, now: now
        )
        return authorSequenceFixtures() + thirdGroup
    }

    private func samePlacePagerFixture() throws -> FriendStoryGroup {
        let visits = (0..<6).map { index in
            RatedPOI.CheckIn(id: UUID(), userId: alice,
                createdAt: now.addingTimeInterval(TimeInterval(-40 + index)),
                media: [.init(id: UUID(), kind: .photo(
                    URL(fileURLWithPath: "/tmp/pager-slice-\(index).jpg")))])
        }
        let place = RatedPOI(
            poi: .init(id: UUID(), name: "Six-slice place",
                       coordinate: .init(latitude: 47.6, longitude: -122.3), category: .other),
            highlight: nil, secondary: nil, media: [], checkIns: visits, comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
        let groups = FriendStoryFeed.groups(
            reals: [reel(id: 801, author: alice, ago: 100), reel(id: 802, author: alice, ago: 80)],
            ratedPOIs: [place], userProvider: { _ in nil }, now: now)
        let group = try #require(groups.first)
        try #require(group.pages.count == 8)
        try #require(group.moments.last?.pageRange == 2..<8,
                     "The fixture must contain exactly six consecutive slices at one place")
        return group
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

    private func flightRegion(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        .init(center: .init(latitude: latitude, longitude: longitude),
              latitudinalMeters: 30_000, longitudinalMeters: 30_000)
    }

    private func nearbyStops(around center: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        [-0.001, 0, 0.001].map {
            CLLocationCoordinate2D(latitude: center.latitude + $0, longitude: center.longitude)
        }
    }

    private func waitForFlight(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The shared flight should settle within five seconds")
    }

    @MainActor
    private final class FlightProbe {
        var position: MapCameraPosition
        var writes: [MapCameraPosition] = []
        var updates: [MKCoordinateRegion] = []
        private weak var controller: MapFlightController?

        init(position: MapCameraPosition, controller: MapFlightController? = nil) {
            self.position = position
            self.controller = controller
        }

        var binding: Binding<MapCameraPosition> {
            Binding(get: { self.position }, set: { value in
                self.position = value
                self.writes.append(value)
                if let camera = value.camera {
                    // These navigation tests model a renderer which reaches
                    // each requested camera immediately. Native timing and
                    // incomplete-camera observations are tested separately.
                    self.controller?.observeCamera(region: .init(
                        center: camera.centerCoordinate,
                        latitudinalMeters: camera.distance,
                        longitudinalMeters: camera.distance), camera: camera)
                } else if let region = value.region {
                    self.controller?.observeCamera(region: region)
                }
            })
        }
    }
}

@MainActor
struct MapTalkPostEntryGeometryTests {
    private let canvas = CGSize(width: 390, height: 760)
    private let baseBottomInset: CGFloat = 16
    private let compactBottomInset: CGFloat = 292

    @Test
    func sheetClearanceUsesTheActualCardEdgeNotTheWholeSheetHeight() {
        // The map ends above the tab bar, but the native sheet extends below it.
        let mapFrame = CGRect(x: 0, y: 59, width: 393, height: 710)
        let sheetFrame = CGRect(x: 8, y: 558, width: 377, height: 286)
        let inset = MapTalkPostEntryGeometry.sheetClearance(
            mapFrame: mapFrame, sheetFrame: sheetFrame, baseBottomInset: 17)
        #expect(inset == 223)
        #expect(mapFrame.maxY - inset == sheetFrame.minY - 12)
        let withPersonHeader = MapTalkPostEntryGeometry.sheetClearance(
            mapFrame: mapFrame, sheetFrame: sheetFrame, baseBottomInset: 17, accessoryHeight: 80)
        #expect(withPersonHeader == inset + 80)
    }

    @Test
    func idleCoverHasAFixedLowerLeftPosition() {
        let center = MapTalkPostEntryGeometry.center(
            canvasSize: canvas, bottomInset: baseBottomInset)
        let cover = coverFrame(at: center)

        #expect(cover.minX == 22)
        #expect(cover.maxY == canvas.height - baseBottomInset)
    }

    @Test
    func compactCardLiftsCoverWithoutChangingItsHorizontalPosition() {
        let closed = MapTalkPostEntryGeometry.center(
            canvasSize: canvas, bottomInset: baseBottomInset)
        let open = MapTalkPostEntryGeometry.center(
            canvasSize: canvas, bottomInset: compactBottomInset)

        #expect(open.x == closed.x)
        #expect(open.y < closed.y)
        #expect(coverFrame(at: open).maxY == canvas.height - compactBottomInset)
    }

    @Test
    func closingCardRestoresIdlePositionOnBothCanvasSizes() {
        for size in [canvas, CGSize(width: 320, height: 640)] {
            let before = MapTalkPostEntryGeometry.center(
                canvasSize: size, bottomInset: baseBottomInset)
            let open = MapTalkPostEntryGeometry.center(
                canvasSize: size, bottomInset: compactBottomInset)
            let after = MapTalkPostEntryGeometry.center(
                canvasSize: size, bottomInset: baseBottomInset)

            #expect(open.y < before.y)
            #expect(after == before)
            #expect(coverFrame(at: after).minX == 22)
            #expect(coverFrame(at: after).maxY == size.height - baseBottomInset)
        }
    }

    private func coverFrame(at center: CGPoint) -> CGRect {
        let size = MapTalkPostEntryGeometry.size
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }
}

@MainActor
struct MapTalkPostEntryPageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func classicPostPreviewIsOptInAndLeavesExistingDetailsAlone() {
        let author = user("alice")
        let post = reel(author: author, ago: 60)
        #expect(!ExperienceDetailView(mode: .real(post, author), isExpanded: false).isClassicPostPreview)
        #expect(!ExperienceDetailView(mode: .real(post, author), isExpanded: true).isClassicPostPreview)
        #expect(ExperienceDetailView(mode: .real(post, author), isExpanded: false,
                                    usesClassicPostPreview: true).isClassicPostPreview)
        #expect(ExperienceDetailView(mode: .real(post, author), isExpanded: true,
                                    usesClassicPostPreview: true).isClassicPostPreview)

        let place = RatedPOI(
            poi: .init(id: UUID(), name: "Place", coordinate: .init(latitude: 47.6, longitude: -122.3),
                       category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0
        )
        for expanded in [false, true] {
            #expect(!ExperienceDetailView(mode: .poi(place), isExpanded: expanded,
                                         usesClassicPostPreview: true).isClassicPostPreview)
        }
    }

    @Test
    func firstTextOnlyPostIsNotSkippedForAPhotoCover() {
        let alice = user("alice")
        let text = reel(author: alice, ago: 120)
        let photo = reel(author: alice, ago: 60,
            attachments: [.init(kind: .photo(URL(string: "https://example.com/cover.jpg")!))])
        let groups = FriendStoryFeed.groups(reals: [photo, text], ratedPOIs: [],
            userProvider: { _ in nil }, now: now)

        #expect(MapTalkPostEntryPage.resolve(in: groups, resumePageID: nil)?.memoryID == text.id)
    }

    @Test
    func resumeWinsWhenReadStateReordersTheFeed() throws {
        let alice = user("alice"), bob = user("bob")
        let posts = [reel(author: alice, ago: 10), reel(author: bob, ago: 20)]
        let initial = FriendStoryFeed.groups(reals: posts, ratedPOIs: [],
            userProvider: { _ in nil }, now: now)
        let saved = try #require(initial.first?.pages.first)
        let reordered = FriendStoryFeed.groups(reals: posts, ratedPOIs: [],
            viewedKeys: [saved.readKey], userProvider: { _ in nil }, now: now)

        #expect(initial.first?.authorID == alice.id)
        #expect(reordered.first?.authorID == bob.id)
        #expect(MapTalkPostEntryPage.resolve(in: reordered, resumePageID: saved.id)?.id == saved.id)
        #expect(MapTalkPostEntryPage.resolve(in: Array(reordered.reversed()),
            resumePageID: saved.id)?.id == saved.id)
    }

    @Test
    func removedResumeFallsBackToAvailablePostAndEmptyFeedHasNoCover() throws {
        let alice = user("alice")
        let removed = reel(author: alice, ago: 120), remaining = reel(author: alice, ago: 60)
        let initial = FriendStoryFeed.groups(reals: [removed, remaining], ratedPOIs: [],
            userProvider: { _ in nil }, now: now)
        let saved = try #require(initial.first?.pages.first)
        let refreshed = FriendStoryFeed.groups(reals: [remaining], ratedPOIs: [],
            userProvider: { _ in nil }, now: now)

        #expect(MapTalkPostEntryPage.resolve(in: refreshed, resumePageID: saved.id)?.memoryID == remaining.id)
        #expect(MapTalkPostEntryPage.resolve(in: [], resumePageID: saved.id) == nil)
        #expect(MapTalkPostEntryPage.resolve(in: [], resumePageID: nil) == nil)
    }

    @Test
    func openingCoverSelectsItsExactPageInsteadOfAnotherUnreadPost() throws {
        let alice = user("alice")
        let posts = [reel(author: alice, ago: 120), reel(author: alice, ago: 60)]
        let groups = FriendStoryFeed.groups(reals: posts, ratedPOIs: [],
            userProvider: { _ in nil }, now: now)
        let cover = try #require(MapTalkPostEntryPage.resolve(in: groups, resumePageID: nil))
        let navigation = FriendStoryNavigation()
        navigation.begin(groups: groups, authorID: cover.authorID,
            viewedKeys: [cover.readKey], origin: .init(camera: nil, region: nil))

        #expect(navigation.session?.currentPage?.id != cover.id,
                "The unread entry rule would otherwise open the later Post")
        navigation.session?.selectPage(id: cover.id)
        #expect(navigation.session?.currentPage?.id == cover.id)
    }

    @Test
    func refreshAvoidsCurrentCardAndPrefersAnotherUnreadPost() throws {
        let alice = user("alice")
        let groups = FriendStoryFeed.groups(
            reals: [reel(author: alice, ago: 180), reel(author: alice, ago: 120),
                    reel(author: alice, ago: 60)],
            ratedPOIs: [], userProvider: { _ in nil }, now: now)
        let pages = try #require(groups.first?.pages)

        #expect(MapTalkPostEntryPage.refreshTarget(in: groups,
            currentPageID: pages[0].id, viewedKeys: [pages[1].readKey])?.id == pages[2].id,
            "The current card is excluded even if its read marker has not fired yet")
        #expect(MapTalkPostEntryPage.refreshTarget(in: groups,
            currentPageID: pages[2].id, viewedKeys: [pages[1].readKey])?.id == pages[0].id)
    }

    @Test
    func repeatedRefreshCyclesForwardBeforeAndAfterReadMarkers() throws {
        let alice = user("alice")
        let groups = FriendStoryFeed.groups(
            reals: [reel(author: alice, ago: 180), reel(author: alice, ago: 120),
                    reel(author: alice, ago: 60)],
            ratedPOIs: [], userProvider: { _ in nil }, now: now)
        let pages = try #require(groups.first?.pages)
        let readStates: [Set<String>] = [[], Set(pages.map(\.readKey))]

        for viewedKeys in readStates {
            var current = pages[0]
            for expected in [pages[1], pages[2], pages[0]] {
                current = try #require(MapTalkPostEntryPage.refreshTarget(in: groups,
                    currentPageID: current.id, viewedKeys: viewedKeys))
                #expect(current.id == expected.id,
                    "Rapid taps must not bounce between only the first two posts")
            }
        }
    }

    @Test
    func refreshHandlesEmptySingletonAndRemovedCursor() throws {
        let alice = user("alice")
        let groups = FriendStoryFeed.groups(reals: [reel(author: alice, ago: 60)],
            ratedPOIs: [], userProvider: { _ in nil }, now: now)
        let only = try #require(groups.first?.pages.first)

        #expect(MapTalkPostEntryPage.refreshTarget(in: [], currentPageID: only.id,
            viewedKeys: []) == nil)
        #expect(MapTalkPostEntryPage.refreshTarget(in: groups, currentPageID: only.id,
            viewedKeys: [only.readKey])?.id == only.id)
        #expect(MapTalkPostEntryPage.refreshTarget(in: groups, currentPageID: "removed",
            viewedKeys: [])?.id == only.id)
        #expect(MapTalkPostEntryPage.refreshTarget(in: groups, currentPageID: nil,
            viewedKeys: [])?.id == only.id)
    }

    @Test
    func refreshAdoptsNewPostWithoutReplacingOriginalMapOrigin() throws {
        let alice = user("alice")
        let oldPost = reel(author: alice, ago: 120)
        let newPost = reel(author: alice, ago: 60)
        let initial = FriendStoryFeed.groups(reals: [oldPost], ratedPOIs: [],
            userProvider: { _ in nil }, now: now)
        let fresh = FriendStoryFeed.groups(reals: [oldPost, newPost], ratedPOIs: [],
            userProvider: { _ in nil }, now: now)
        let oldPage = try #require(initial.first?.pages.first)
        let originalRegion = MKCoordinateRegion(center: .init(latitude: 47.6, longitude: -122.3),
            span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
        let navigation = FriendStoryNavigation()
        navigation.begin(groups: initial, authorID: alice.id, viewedKeys: [],
            origin: .init(camera: nil, region: originalRegion))
        let target = try #require(MapTalkPostEntryPage.refreshTarget(in: fresh,
            currentPageID: oldPage.id, viewedKeys: []))

        navigation.begin(groups: fresh, authorID: target.authorID, viewedKeys: [],
            origin: .init(camera: nil, region: nil))
        #expect(navigation.session?.currentPage?.id == oldPage.id,
            "Beginning a fresh snapshot deliberately retains the author's saved cursor")
        navigation.session?.selectPage(id: target.id)

        #expect(navigation.isActive)
        #expect(navigation.session?.currentPage?.memoryID == newPost.id)
        #expect(navigation.origin?.region?.center.latitude == originalRegion.center.latitude)
        #expect(navigation.origin?.region?.center.longitude == originalRegion.center.longitude)
        #expect(!navigation.selectPagerPage(id: target.id, fromAuthorID: alice.id,
            fromPageID: oldPage.id), "The old pager callback cannot overwrite refreshed selection")
    }

    private func user(_ handle: String) -> User {
        .init(id: UUID(), handle: handle, avatarURL: nil)
    }

    private func reel(author: User, ago: TimeInterval,
                      attachments: [RealPost.Attachment] = []) -> RealPost {
        let created = now.addingTimeInterval(-ago)
        return .init(id: UUID(), userId: author.id,
            center: .init(latitude: 47.6, longitude: -122.3), radiusMeters: 220,
            message: "Post entry fixture", attachments: attachments, likes: [], comments: [],
            visibility: .publicAll, createdAt: created,
            expiresAt: created.addingTimeInterval(StoryReadKeys.freshWindow))
    }
}

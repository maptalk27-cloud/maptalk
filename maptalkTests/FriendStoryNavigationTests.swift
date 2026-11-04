import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

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

    @Test
    func storyCameraFocusIgnoresRemoteAndRepeatedCoordinatesAndScopesPreviousToItsAuthor() throws {
        let coordinates: [CLLocationCoordinate2D] = [
            .init(latitude: 47.6, longitude: -122.3),
            .init(latitude: 47.604, longitude: -122.3),
            .init(latitude: 47.61, longitude: -122.3),
            .init(latitude: 21.28, longitude: -157.83),
            .init(latitude: 47.604, longitude: -122.3),
            .init(latitude: 47.604, longitude: -122.3)
        ]
        let posts = coordinates.enumerated().map { index, coordinate in
            var post = reel(id: 201 + index, author: alice, ago: Double(100 - index))
            post.center = coordinate
            return post
        }
        let local = try #require(FriendStoryFeed.groups(reals: Array(posts.prefix(3)),
            ratedPOIs: [], userProvider: { _ in nil }, now: now).first)
        let complete = try #require(FriendStoryFeed.groups(reals: posts,
            ratedPOIs: [], userProvider: { _ in nil }, now: now).first)
        let target = local.pages[0]
        let previousKey = local.pages[1].locationKey
        let expected = try #require(local.cameraFocus(for: target,
            previousLocationKey: previousKey, previousAuthorID: alice))
        let actual = try #require(complete.cameraFocus(for: target,
            previousLocationKey: previousKey, previousAuthorID: alice))
        #expect(abs(actual.landingSpan - expected.landingSpan) < 0.01,
                "A distant post or repeated same-coordinate pages must not enlarge the local framing")
        #expect(actual.landingSpan >= 800 && actual.landingSpan < 2_000)
        let previous = try #require(actual.previousCoordinate)
        #expect(previous.distance(to: coordinates[1]) < 1)
        let changedAuthor = try #require(complete.cameraFocus(for: target,
            previousLocationKey: previousKey, previousAuthorID: bob))
        #expect(changedAuthor.previousCoordinate == nil)
        #expect(changedAuthor.landingSpan == actual.landingSpan)
        let remotePage = complete.pages.first { $0.coordinate?.latitude == 21.28 }!
        let remoteFocus = try #require(complete.cameraFocus(for: remotePage,
            previousLocationKey: previousKey, previousAuthorID: alice))
        #expect(remoteFocus.landingSpan == 20_000)
        #expect(remoteFocus.previousCoordinate?.distance(to: coordinates[1]) ?? .infinity < 1,
                "An isolated destination must still retain the story's departure")
    }

    @Test(arguments: [false, true])
    func childOpenedDuringFlightReturnsToPendingDestinationNotStaleDeparture(useStoryFocus: Bool) throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 21.33147, longitude: -157.92001)
        let target = flightRegion(latitude: 19.73698, longitude: -156.04092)
        let viewport = MapCameraViewport(size: CGSize(width: 400, height: 800),
                                         topInset: 110, bottomInset: 380)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(currentRegion: origin, targetRegion: target, cause: .poi,
            viewport: viewport,
            storyFocus: useStoryFocus ? .init(landingSpan: 20_000, previousCoordinate: origin.center) : nil,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let landing = try #require(controller.pendingLandingRegion)
        #expect(landing.center.distance(to: origin.center) > 200_000)
        #expect(abs(landing.center.longitude - target.center.longitude) < 0.001)
        controller.observeCamera(region: origin)
        #expect(controller.pendingLandingRegion?.center.distance(to: landing.center) ?? .infinity < 1,
                "Late/intermediate camera samples must not overwrite the parent return destination")
        controller.cancelActiveTransition()
        #expect(controller.pendingLandingRegion == nil,
                "After cancellation, capture preserves the user's actual camera instead of an old destination")
    }

    @Test(arguments: [false, true])
    func nearbyStoryFocusUsesLocalLandingWhileOrdinarySelectionKeepsItsWideView(useStoryFocus: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let target = flightRegion(latitude: 47.61, longitude: -122.3)
        let local = MKCoordinateRegion(center: target.center, latitudinalMeters: 1_200, longitudinalMeters: 1_200)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            storyFocus: useStoryFocus ? .init(landingSpan: 1_200, previousCoordinate: origin.center) : nil,
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        if useStoryFocus && !UIAccessibility.isReduceMotionEnabled {
            let request = try #require(controller.storyFlight)
            #expect(request.destination.center.latitude == target.center.latitude)
            #expect(abs(request.destination.span.latitudeDelta - local.span.latitudeDelta) < 0.000_000_001)
            #expect(abs(request.destination.span.longitudeDelta - local.span.longitudeDelta) < 0.000_000_001)
            #expect(request.previousCoordinate.distance(to: origin.center) < 1)
            #expect(!request.isRetarget)
            #expect(probe.writes.isEmpty, "MapKit owns the local keyframes; the controller must not write competing cameras")
            #expect(probe.updates.isEmpty, "Only the real map's completion may report the settled region")
            return
        }
        try await waitForFlight { !probe.updates.isEmpty }
        let landed = try #require(probe.position.region)
        let expectedSpan = useStoryFocus ? local.span : origin.span
        #expect(abs(landed.span.latitudeDelta - expectedSpan.latitudeDelta) < 0.000_000_001)
        #expect(abs(landed.span.longitudeDelta - expectedSpan.longitudeDelta) < 0.000_000_001)
        #expect(landed.center.latitude == target.center.latitude)
        #expect(probe.updates.count == 1)
        #expect(controller.storyFlight == nil)
        #expect(probe.writes.count == 1)
        #expect(probe.writes.allSatisfy { $0.camera == nil })
    }

    @Test(arguments: [false, true])
    func firstEntryAndRepeatedStoryCoordinateFrameLocallyWithoutLifting(hasPreviousCoordinate: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let target = flightRegion(latitude: 47.61, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: hasPreviousCoordinate ? target.center : nil),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        try await waitForFlight { !probe.updates.isEmpty }
        #expect(probe.writes.count == 1)
        #expect(probe.writes.allSatisfy { $0.camera == nil }, "No geographic story hop means no lift")
        let landed = try #require(probe.position.region)
        let local = MKCoordinateRegion(center: target.center, latitudinalMeters: 1_200, longitudinalMeters: 1_200)
        #expect(abs(landed.span.latitudeDelta - local.span.latitudeDelta) < 0.000_000_001)
        #expect(abs(landed.span.longitudeDelta - local.span.longitudeDelta) < 0.000_000_001)
    }

    @Test(arguments: [false, true])
    func distantStoryHopUsesNativeCityScaleWhileFirstEntryKeepsExistingBehavior(cameraAlreadyNearby: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let previous = flightRegion(latitude: 47.6, longitude: -122.3)
        let target = flightRegion(latitude: 48.45, longitude: -122.3)
        let origin = cameraAlreadyNearby ? flightRegion(latitude: 48.44, longitude: -122.3) : previous
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            storyFocus: .init(landingSpan: 1_200,
                              previousCoordinate: cameraAlreadyNearby ? previous.center : target.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        if cameraAlreadyNearby && !UIAccessibility.isReduceMotionEnabled {
            let request = try #require(controller.storyFlight)
            #expect(request.previousCoordinate.distance(to: previous.center) < 1)
            #expect(request.destination.center.distance(to: target.center) < 1)
            #expect(request.destination.span.latitudeDelta > 0.17,
                    "A regional hop retains city-scale landing, even if the interrupted camera is nearby")
            #expect(request.duration > 1.2)
            #expect(probe.writes.isEmpty, "One native owner replaces the legacy timed stages")
            return
        }
        try await waitForFlight { !probe.updates.isEmpty }
        let landed = try #require(probe.position.region)
        #expect(landed.center.latitude == target.center.latitude)
        #expect(landed.span.latitudeDelta > 0.17, "A distant story must retain the old city-scale behavior")
        #expect(landed.span.latitudeDelta <= target.span.latitudeDelta * 1.15)
        #expect(probe.updates.count == 1)
    }

    @Test
    func regionalStoryTempoIsSymmetricAndContinuousAcrossOldDistanceThreshold() {
        let origin = CLLocationCoordinate2D(latitude: 20.79060, longitude: -156.94978)
        let destination = CLLocationCoordinate2D(latitude: 21.32272, longitude: -157.91080)
        func request(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> MapStoryFlightRequest {
            .init(destination: MKCoordinateRegion(center: to, latitudinalMeters: 30_000,
                                                 longitudinalMeters: 30_000),
                  previousCoordinate: from, viewport: nil)
        }
        #expect(request(from: origin, to: destination).duration == request(from: destination, to: origin).duration)
        let justBelow = origin.interpolated(to: destination, fraction: 1)
        let slightlyFarther = CLLocationCoordinate2D(latitude: destination.latitude + 0.05,
                                                      longitude: destination.longitude - 0.05)
        #expect(abs(request(from: origin, to: justBelow).duration
                    - request(from: origin, to: slightlyFarther).duration) < 0.1,
                "Crossing the old 120 km cutoff must not switch from 0.84 to 3.2 seconds")
    }

    @Test
    func rapidNearbyStorySelectionCancelsThePreviousLocalLanding() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        let oldTarget = flightRegion(latitude: 47.61, longitude: -122.3)
        let newTarget = flightRegion(latitude: 47.62, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: oldTarget, cause: .real,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: origin.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        let firstRequest = try #require(controller.storyFlight)
        #expect(probe.writes.isEmpty)
        #expect(probe.updates.isEmpty)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: newTarget, cause: .poi,
            storyFocus: .init(landingSpan: 1_800, previousCoordinate: oldTarget.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        let replacement = try #require(controller.storyFlight)
        #expect(replacement.id != firstRequest.id)
        #expect(replacement.isRetarget)
        let local = MKCoordinateRegion(center: newTarget.center, latitudinalMeters: 1_800, longitudinalMeters: 1_800)
        #expect(replacement.destination.center.latitude == newTarget.center.latitude)
        #expect(abs(replacement.destination.span.latitudeDelta - local.span.latitudeDelta) < 0.000_000_001)
        #expect(abs(replacement.destination.span.longitudeDelta - local.span.longitudeDelta) < 0.000_000_001)
        let live = MapCamera(centerCoordinate: .init(latitude: 47.614, longitude: -122.305),
                             distance: 18_000, heading: 35, pitch: 12)
        let plan = replacement.plan(from: live) { region in
            MapCamera(centerCoordinate: region.center, distance: 4_000, heading: 0, pitch: 0)
        }
        let timeline = KeyframeTimeline(initialValue: live) { storyFlightKeyframes(plan) }
        let start = timeline.value(time: 0)
        #expect(start.centerCoordinate.distance(to: live.centerCoordinate) < 0.01)
        #expect(abs(start.distance - live.distance) < 0.01)
        #expect(abs(start.heading - live.heading) < 0.01)
        #expect(abs(start.pitch - live.pitch) < 0.01)
        controller.cancelActiveTransition()
        #expect(controller.storyFlight == nil)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(probe.writes.isEmpty, "A replaced or canceled native flight must not schedule an old binding landing")
        #expect(probe.updates.isEmpty)
    }

    @Test(arguments: [4_800.0, 30_000.0],
          [(0.0009, 0.0), (-0.0009, 0.0), (0.0, 0.00133), (0.027, 0.0), (-0.027, 0.0)])
    func nearbyStoryKeyframesRiseAndLandWithoutReversingAtTheCardOffset(startDistance: Double, offset: (Double, Double)) {
        // Production compact chrome: 800 * 0.35 + 34 safe area + 80 story header.
        let viewport = MapCameraViewport(size: .init(width: 400, height: 800), topInset: 90, bottomInset: 394)
        let previous = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        // North, south, and east short hops plus 3 km north/south hops must keep
        // the visible focus moving forward, even as the camera center reframes.
        let destination = MKCoordinateRegion(center: .init(latitude: previous.latitude + offset.0,
                                                           longitude: previous.longitude + offset.1),
            latitudinalMeters: 1_200, longitudinalMeters: 1_200)
        let previousRegion = MKCoordinateRegion(center: previous,
            latitudinalMeters: 1_200, longitudinalMeters: 1_200)
        let live = MapCamera(centerCoordinate: viewport.framed(previousRegion).center,
                             distance: startDistance, heading: 0, pitch: 0)
        let request = MapStoryFlightRequest(destination: destination,
            previousCoordinate: previous, viewport: viewport)
        let plan = request.plan(from: live) { storyTestCamera(for: $0, viewport: viewport) }
        let timeline = KeyframeTimeline(initialValue: live) { storyFlightKeyframes(plan) }
        #expect(abs(timeline.duration - 1.2) < 0.000_001)
        #expect(plan.overviewDistance > max(live.distance, plan.landing.distance))
        #expect(plan.landing.centerCoordinate.distance(to: viewport.framed(destination).center) < 0.01)
        #expect(plan.landing.centerCoordinate.latitude < destination.center.latitude)

        let startFocus = MKMapPoint(plan.visibleFocus(of: live))
        let endFocus = MKMapPoint(destination.center)
        let dx = endFocus.x - startFocus.x
        let dy = endFocus.y - startFocus.y
        let length = hypot(dx, dy)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(destination.center.latitude)
        let progressTolerance = 1 / max(1, length * metersPerPoint)
        var previousProgress = 0.0
        for step in 0...60 {
            let camera = timeline.value(time: timeline.duration * Double(step) / 60)
            let focus = MKMapPoint(plan.visibleFocus(of: camera))
            let progress = ((focus.x - startFocus.x) * dx + (focus.y - startFocus.y) * dy) / (length * length)
            let crossTrackMeters = abs((focus.x - startFocus.x) * dy - (focus.y - startFocus.y) * dx)
                / length * metersPerPoint
            #expect(progress >= previousProgress - progressTolerance,
                    "The geographic center may reframe, but the visible focus must not backtrack")
            #expect(progress >= -progressTolerance && progress <= 1 + progressTolerance)
            #expect(crossTrackMeters < 1)
            #expect(camera.distance <= plan.overviewDistance + 0.01)
            previousProgress = progress
        }
        let peak = timeline.value(time: MapStoryFlightPlan.liftDuration)
        #expect(abs(peak.distance - plan.overviewDistance) < 0.01)
        let scale = peak.distance / 2 / MKMetersPerMapPointAtLatitude(peak.centerCoordinate.latitude)
            / viewport.size.height
        let center = MKMapPoint(peak.centerCoordinate)
        for stop in [previous, destination.center] {
            let point = MKMapPoint(stop)
            let x = viewport.size.width / 2 + (point.x - center.x) / scale
            let y = viewport.size.height / 2 + (point.y - center.y) / scale
            #expect(x >= 28 && x <= viewport.size.width - 28)
            #expect(y >= viewport.topInset + 24 && y <= viewport.size.height - viewport.bottomInset - 24,
                    "Both pins fit in the unobscured overview, not underneath the card")
        }
        for time in [timeline.duration, timeline.duration + 0.5] {
            let landed = timeline.value(time: time)
            #expect(landed.centerCoordinate.distance(to: plan.landing.centerCoordinate) < 0.01)
            #expect(plan.visibleFocus(of: landed).distance(to: destination.center) < 0.01)
            #expect(abs(landed.distance - plan.landing.distance) < 0.01)
        }
    }

    @Test
    func nearbyStoryAcrossDatelineUsesShortSphericalPathWithoutGlobeZoom() throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 0, longitude: 179.99)
        let target = flightRegion(latitude: 0, longitude: -179.99)
        let probe = FlightProbe(position: .region(origin))
        #expect(origin.center.distance(to: target.center) < 12_000)
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: origin.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) }
        )
        let request = try #require(controller.storyFlight)
        #expect(request.usesGlobalPlan)
        #expect(request.duration == MapStoryFlightPlan.duration)
        let start = MapCamera(centerCoordinate: origin.center, distance: 20_000)
        let plan = request.plan(from: start) { MapCamera(centerCoordinate: $0.center, distance: 20_000) }
        #expect(plan.overviewDistance < 40_000, "Crossing the dateline nearby must not manufacture a globe trip")
        let timeline = KeyframeTimeline(initialValue: start) { storyFlightKeyframes(plan) }
        let landed = timeline.value(time: timeline.duration)
        #expect(landed.centerCoordinate.distance(to: target.center) < 1)
        #expect(probe.writes.isEmpty)
        #expect(probe.updates.isEmpty)
    }

    @Test
    func absentStoryKeyframesLeaveTheLiveCameraUntouched() {
        let live = MapCamera(centerCoordinate: .init(latitude: 47.6, longitude: -122.3),
                             distance: 8_765, heading: 47, pitch: 23)
        let timeline = KeyframeTimeline(initialValue: live) { storyFlightKeyframes(nil) }
        #expect(timeline.duration == 0)
        for time in [0.0, 1.2] {
            let camera = timeline.value(time: time)
            #expect(camera.centerCoordinate.distance(to: live.centerCoordinate) < 0.01)
            #expect(abs(camera.distance - live.distance) < 0.01)
            #expect(abs(camera.heading - live.heading) < 0.01)
            #expect(abs(camera.pitch - live.pitch) < 0.01)
        }
    }

    @Test
    func nearbyStoryHeadingDoesNotSpinTheLongWayAcrossNorth() {
        let live = MapCamera(centerCoordinate: .init(latitude: 47.6, longitude: -122.3),
                             distance: 4_000, heading: 350, pitch: 0)
        let request = MapStoryFlightRequest(destination: flightRegion(latitude: 47.61, longitude: -122.3),
            previousCoordinate: live.centerCoordinate, viewport: nil)
        let plan = request.plan(from: live) {
            MapCamera(centerCoordinate: $0.center, distance: 4_000, heading: 0, pitch: 0)
        }
        let timeline = KeyframeTimeline(initialValue: live) { storyFlightKeyframes(plan) }
        #expect(abs(plan.landingHeading - live.heading) <= 10.01)
        let halfway = timeline.value(time: timeline.duration / 2)
        #expect(halfway.heading >= 350 && halfway.heading <= 360)
    }

    @Test(arguments: [false, true])
    func distantReelAndPOISelectionsLiftTravelAndLand(isPOI: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = flightRegion(latitude: 47.6, longitude: -122.3)
        // About 95 km: beyond the removed 80 km shortcut, but inside the
        // original controller's short staged-flight band for a fast test.
        let target = flightRegion(latitude: 48.45, longitude: -122.3)
        let probe = FlightProbe(position: .region(origin))
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
        let probe = FlightProbe(position: .region(origin))
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
        let probe = FlightProbe(position: .region(origin))
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

    // Global-story routing and geometry are pure here. Native frame behavior
    // remains covered separately by MapStoryFlightAnimatorTests.
    @Test(arguments: [false, true])
    func rapidNearbyDestinationSkipWhileCameraStillOverseasKeepsGlobalTiming(useNairobi: Bool) throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let hawaii = flightRegion(latitude: 20.7906, longitude: -156.94978)
        let firstTarget = useNairobi
            ? flightRegion(latitude: -1.2921, longitude: 36.8219)
            : flightRegion(latitude: 46.065, longitude: -118.343)
        let nextTarget = flightRegion(latitude: firstTarget.center.latitude + 0.018,
                                      longitude: firstTarget.center.longitude)
        let probe = FlightProbe(position: .region(hawaii))
        controller.observeCamera(region: hawaii)
        controller.handleRegionChange(currentRegion: hawaii, targetRegion: firstTarget, cause: .real,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: hawaii.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let firstRequest = try #require(controller.storyFlight)
        try #require(firstRequest.usesGlobalPlan)

        // The next post is only ~2 km away, but no native camera frame has
        // left Hawaii yet. Also supply a stale/predicted settled destination.
        controller.handleRegionChange(currentRegion: firstTarget, targetRegion: nextTarget, cause: .poi,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: firstTarget.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let replacement = try #require(controller.storyFlight)
        #expect(replacement.id != firstRequest.id)
        #expect(replacement.isRetarget && replacement.usesGlobalPlan)
        #expect(replacement.previousCoordinate.distance(to: hawaii.center) < 1,
                "Remaining-flight timing must use the still-visible continent, not the nearby logical post")
        #expect(replacement.duration >= 3.2,
                "An 80 ms page skip must not compress the remaining cross-continent flight to 1.2 seconds")
        let expected = MapStoryFlightRequest(destination: replacement.destination,
            previousCoordinate: hawaii.center, viewport: nil, isRetarget: true, isGlobal: true)
        #expect(abs(replacement.duration - expected.duration) < 0.000_001)
        #expect(replacement.destination.center.distance(to: nextTarget.center) < 1)
        #expect(probe.writes.isEmpty && probe.updates.isEmpty,
                "The native animator remains the only camera owner during the rapid skip")
    }

    @Test
    func globalFlightInterruptedByNearbyStoryDescendsFromActualHighCamera() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let hawaii = flightRegion(latitude: 20.7906, longitude: -156.94978)
        let nairobi = flightRegion(latitude: -1.2921, longitude: 36.8219)
        let nearby = flightRegion(latitude: -1.2821, longitude: 36.8319)
        let probe = FlightProbe(position: .region(hawaii))
        controller.handleRegionChange(currentRegion: hawaii, targetRegion: nairobi, cause: .real,
            storyFocus: .init(landingSpan: 20_000, previousCoordinate: hawaii.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let outward = try #require(controller.storyFlight)
        try #require(outward.usesGlobalPlan)
        let visible = MKCoordinateRegion(center: .init(latitude: -5, longitude: 32),
                                         latitudinalMeters: 1_500_000, longitudinalMeters: 1_500_000)
        controller.observeCamera(region: visible)
        controller.handleRegionChange(currentRegion: hawaii, targetRegion: nearby, cause: .poi,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: nairobi.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let replacement = try #require(controller.storyFlight)
        #expect(replacement.id != outward.id)
        #expect(replacement.isRetarget && replacement.usesGlobalPlan,
                "A nearby logical hop must not restart a flat 1.2-second flight from globe altitude")
        let live = MapCamera(centerCoordinate: visible.center, distance: 12_000_000, heading: 0, pitch: 0)
        let plan = replacement.plan(from: live) {
            MapCamera(centerCoordinate: $0.center, distance: 40_000, heading: 0, pitch: 0)
        }
        let trajectory = try #require(plan.globalTrajectory)
        #expect(trajectory.center(at: 0).distance(to: live.centerCoordinate) < 0.01)
        #expect(abs(trajectory.distance(at: 0) - live.distance) < 0.01)
        let distances = (0...120).map { trajectory.distance(at: Double($0) / 120 * plan.totalDuration) }
        #expect(distances.allSatisfy { $0.isFinite && $0 > 0 && $0 <= live.distance * 1.000_001 })
        #expect(zip(distances, distances.dropFirst()).allSatisfy { pair in pair.1 <= pair.0 + 0.01 },
                "An inherited high camera should descend smoothly, not replay another takeoff")
        #expect(trajectory.distance(at: plan.totalDuration * 0.25) < live.distance * 0.9)
        #expect(abs(trajectory.distance(at: plan.totalDuration) - plan.landing.distance) < 0.01)
        #expect(probe.writes.isEmpty && probe.updates.isEmpty)
    }

    @Test
    func switchingToDistantAuthorUsesObservedMapDepartureForGlobalFlight() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        var first = reel(id: 970, author: alice, ago: 30)
        first.center = .init(latitude: 20.7906, longitude: -156.94978)
        var second = reel(id: 971, author: bob, ago: 20)
        second.center = .init(latitude: -1.2921, longitude: 36.8219)
        let groups = FriendStoryFeed.groups(reals: [first, second], ratedPOIs: [],
                                           userProvider: { _ in nil }, now: now)
        let source = try #require(groups.first { $0.authorID == alice })
        let destination = try #require(groups.first { $0.authorID == bob })
        let sourcePage = try #require(source.pages.first)
        let targetPage = try #require(destination.pages.first)
        let focus = try #require(destination.cameraFocus(for: targetPage,
            previousLocationKey: sourcePage.locationKey, previousAuthorID: alice))
        #expect(focus.previousCoordinate == nil,
                "A new author must not import the previous author's private sequence state")
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let actual = flightRegion(latitude: first.center.latitude, longitude: first.center.longitude)
        let target = flightRegion(latitude: second.center.latitude, longitude: second.center.longitude)
        let probe = FlightProbe(position: .region(actual))
        controller.observeCamera(region: actual)
        controller.handleRegionChange(currentRegion: target, targetRegion: target, cause: .real,
            storyFocus: focus, cameraPosition: probe.binding,
            onRegionUpdate: { probe.updates.append($0) })
        let request = try #require(controller.storyFlight)
        #expect(request.usesGlobalPlan)
        #expect(request.previousCoordinate.distance(to: actual.center) < 1,
                "Stale settled state must not turn a cross-author flight into a local reframe")
        #expect(probe.writes.isEmpty && probe.updates.isEmpty)
    }

    @Test(arguments: [false, true])
    func storyDatelineCrossingUsesEquivalentLongitudeResetInBothDirections(reverse: Bool) throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let origin = flightRegion(latitude: 20, longitude: reverse ? -179.4 : 179.4)
        let destination = flightRegion(latitude: 20, longitude: reverse ? 179.4 : -179.4)
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let probe = FlightProbe(position: .region(origin))
        controller.handleRegionChange(currentRegion: origin, targetRegion: destination, cause: .poi,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: origin.center),
            cameraPosition: probe.binding, onRegionUpdate: { probe.updates.append($0) })
        let request = try #require(controller.storyFlight)
        #expect(request.usesGlobalPlan)
        let start = MapCamera(centerCoordinate: origin.center, distance: 40_000, heading: 0, pitch: 0)
        let plan = request.plan(from: start) {
            MapCamera(centerCoordinate: $0.center, distance: 40_000, heading: 0, pitch: 0)
        }
        let trajectory = try #require(plan.globalTrajectory)
        #expect(abs(trajectory.center(at: plan.totalDuration * 0.51).longitude) > 179,
                "A short dateline hop must stay near the dateline, not circle through Greenwich")
        let frames = plan.centerKeyframes
        #expect(frames.contains { $0.resetBefore != nil })
        #expect(abs(frames.reduce(0) { $0 + $1.duration } - plan.totalDuration) < 0.000_001)
        var previous = start.centerCoordinate
        for frame in frames {
            #expect(frame.duration.isFinite && frame.duration > 0)
            #expect(CLLocationCoordinate2DIsValid(frame.coordinate))
            if let reset = frame.resetBefore {
                #expect(CLLocationCoordinate2DIsValid(reset))
                #expect(previous.distance(to: reset) < 0.01,
                        "A longitude reset may change representation, never physical position")
                previous = reset
            }
            #expect(abs(frame.coordinate.longitude - previous.longitude) <= 180,
                    "No interpolated segment may contain a numerical 360-degree turn")
            previous = frame.coordinate
        }
        #expect(probe.writes.isEmpty && probe.updates.isEmpty)
    }

    @Test(arguments: [false, true])
    func standardMapGlobalFlightDoesNotDetourNorthOfItsEndpoints(reverse: Bool) throws {
        let nairobi = CLLocationCoordinate2D(latitude: -1.2921, longitude: 36.8219)
        let spokane = CLLocationCoordinate2D(latitude: 47.72, longitude: -117)
        let origin = reverse ? spokane : nairobi
        let destination = reverse ? nairobi : spokane
        let start = MapCamera(centerCoordinate: origin, distance: 30_000, heading: 0, pitch: 0)
        let request = MapStoryFlightRequest(destination: .init(center: destination,
            latitudinalMeters: 20_000, longitudinalMeters: 20_000),
            previousCoordinate: origin, viewport: nil, isGlobal: true)
        let plan = request.plan(from: start) {
            MapCamera(centerCoordinate: $0.center, distance: 30_000, heading: 0, pitch: 0)
        }
        let trajectory = try #require(plan.globalTrajectory)
        let timeline = KeyframeTimeline(initialValue: start) { storyFlightKeyframes(plan) }
        for step in 0...180 {
            let time = timeline.duration * Double(step) / 180
            for coordinate in [trajectory.center(at: time), timeline.value(time: time).centerCoordinate] {
                #expect(CLLocationCoordinate2DIsValid(coordinate))
                #expect(coordinate.latitude >= nairobi.latitude - 0.000_001)
                #expect(coordinate.latitude <= spokane.latitude + 0.000_001,
                        "A flat-map trip between Nairobi and Spokane must not detour over Greenland")
                #expect(coordinate.longitude >= spokane.longitude - 0.000_001)
                #expect(coordinate.longitude <= nairobi.longitude + 0.000_001)
            }
        }
        #expect(timeline.value(time: 0).centerCoordinate.distance(to: origin) < 0.01)
        #expect(timeline.value(time: timeline.duration).centerCoordinate.distance(to: destination) < 0.01)
    }

    @Test(arguments: [3_000.0, 30_000.0], [false, true])
    func globalFlightTraversesAtOverviewAndKeepsLateDescentCentered(cityDistance: Double, reverse: Bool) throws {
        let routes: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            (.init(latitude: 20.7906, longitude: -156.94978),
             .init(latitude: -1.2921, longitude: 36.8219)),
            // Synthetic ~3,000 km control, just above regional-flight scope.
            (.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 27))
        ]
        for (a, b) in routes {
            let origin = reverse ? b : a
            let destination = reverse ? a : b
            let start = MapCamera(centerCoordinate: origin, distance: cityDistance, heading: 0, pitch: 0)
            let target = MKCoordinateRegion(center: destination,
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
            let request = MapStoryFlightRequest(destination: target, previousCoordinate: origin,
                                               viewport: nil, isGlobal: true)
            let plan = request.plan(from: start) {
                MapCamera(centerCoordinate: $0.center, distance: cityDistance, heading: 0, pitch: 0)
            }
            let trajectory = try #require(plan.globalTrajectory)
            let timeline = KeyframeTimeline(initialValue: start) { storyFlightKeyframes(plan) }
            let routeDistance = origin.distance(to: destination)
            let expectedDuration = min(5.2, 3.2 + 0.9 * log2(max(2_000_000, routeDistance) / 2_000_000))
            let expectedPeak = min(9_000_000, max(cityDistance * 1.45, routeDistance * 0.65))
            #expect(abs(request.duration - expectedDuration) < 0.000_001)
            #expect(abs(timeline.duration - expectedDuration) < 0.000_001)
            #expect(abs(trajectory.peakDistance - expectedPeak) < 0.01)

            let steps = 600
            let stepDuration = timeline.duration / Double(steps)
            var previous = timeline.value(time: 0)
            var maximumTurnover = 0.0
            var maximumLogSpeed = 0.0
            for index in 1...steps {
                let fraction = Double(index) / Double(steps)
                let time = fraction * timeline.duration
                let camera = timeline.value(time: time)
                #expect(abs(log(camera.distance / trajectory.distance(at: time))) < 0.003,
                        "Native distance tracks must preserve the intended perceptual curve")
                // Ground speed divided by camera distance estimates geographic
                // viewport turnover, not download throughput or tile readiness.
                let groundSpeed = previous.centerCoordinate.distance(to: camera.centerCoordinate) / stepDuration
                maximumTurnover = max(maximumTurnover,
                    groundSpeed / min(previous.distance, camera.distance))
                maximumLogSpeed = max(maximumLogSpeed,
                    abs(log(camera.distance / previous.distance)) / stepDuration)
                if fraction >= 0.73 {
                    #expect(camera.centerCoordinate.distance(to: destination) < 1,
                            "The final quarter must descend over fixed destination geography")
                }
                if (0.40...0.60).contains(fraction) {
                    #expect(abs(camera.distance - expectedPeak) < 1,
                            "The continental overview needs time to be read before descent")
                }
                previous = camera
            }
            #expect(maximumTurnover < 1.5,
                    "Lowering zoom acceleration must not move the speed spike into early/late geographic travel")
            let averagePhaseLogSpeed = log(expectedPeak / cityDistance) / (timeline.duration * 0.40)
            #expect(maximumLogSpeed < averagePhaseLogSpeed * 1.35,
                    "Global zoom must have a steady middle, not a narrow velocity spike")
            #expect(timeline.value(time: 0.15).distance / cityDistance < 1.25,
                    "The first 150 ms must remain a gentle takeoff")
        }
    }

    @Test(arguments: [0.0, 45.0])
    func exactAntipodalGlobeRouteStaysFiniteAndReversesAlongSameArc(originLongitude: Double) throws {
        let a = MapCamera(centerCoordinate: .init(latitude: 0, longitude: originLongitude),
                          distance: 40_000, heading: 0, pitch: 0)
        let b = MapCamera(centerCoordinate: .init(latitude: 0,
                                                  longitude: originLongitude == 0 ? 180 : originLongitude - 180),
                          distance: 40_000, heading: 0, pitch: 0)
        let forward = MapStoryGlobalTrajectory(start: a, landing: b, totalDuration: 4.2)
        let reverse = MapStoryGlobalTrajectory(start: b, landing: a, totalDuration: 4.2)
        #expect(forward.peakDistance <= 9_000_000)
        #expect(reverse.peakDistance == forward.peakDistance)
        var previous = a.centerCoordinate
        let travel = MapStoryGlobalTrajectory.centerTravelRange
        let travelLength = travel.upperBound - travel.lowerBound
        for index in 0...120 {
            let phase = Double(index) / 120
            let point = forward.center(at: (travel.lowerBound + travelLength * phase) * 4.2)
            let reversedPoint = reverse.center(at: (travel.lowerBound + travelLength * (1 - phase)) * 4.2)
            #expect(CLLocationCoordinate2DIsValid(point))
            #expect(CLLocationCoordinate2DIsValid(reversedPoint))
            #expect(abs(point.latitude) < 0.000_001,
                    "Equatorial antipodes must not detour through a polar longitude singularity")
            #expect(point.distance(to: reversedPoint) < 1,
                    "Exact antipodes need a stable shared arc, not a direction-dependent fallback")
            #expect(previous.distance(to: point) < 600_000)
            let distance = forward.distance(at: phase * 4.2)
            #expect(distance.isFinite && distance > 0 && distance <= 9_000_000)
            previous = point
        }
        #expect(previous.distance(to: b.centerCoordinate) < 0.01)
        #expect(forward.centerKeyframes.allSatisfy {
            CLLocationCoordinate2DIsValid($0.coordinate) && $0.duration.isFinite && $0.duration > 0
                && $0.startVelocity.latitude.isFinite && $0.startVelocity.longitude.isFinite
                && $0.endVelocity.latitude.isFinite && $0.endVelocity.longitude.isFinite
        })
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

    /// A deterministic, flat-camera projection for testing geometry without a
    /// mounted map: camera distance is twice the fitted vertical ground span.
    private func storyTestCamera(for region: MKCoordinateRegion, viewport: MapCameraViewport) -> MapCamera {
        let north = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2, longitude: region.center.longitude))
        let south = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2, longitude: region.center.longitude))
        let west = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude, longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let east = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude, longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let visibleHeight = max(abs(north.y - south.y),
            abs(east.x - west.x) * viewport.size.height / viewport.size.width)
        return MapCamera(centerCoordinate: region.center,
            distance: visibleHeight * MKMetersPerMapPointAtLatitude(region.center.latitude) * 2,
            heading: 0, pitch: 0)
    }

    private func waitForFlight(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The short shared flight should settle within three seconds")
    }

    private final class FlightProbe {
        var position: MapCameraPosition
        var writes: [MapCameraPosition] = []
        var updates: [MKCoordinateRegion] = []

        init(position: MapCameraPosition) { self.position = position }

        var binding: Binding<MapCameraPosition> {
            Binding(get: { self.position }, set: { value in
                self.position = value
                self.writes.append(value)
            })
        }
    }
}

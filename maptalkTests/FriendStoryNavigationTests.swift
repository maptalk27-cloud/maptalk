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
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice))
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice))
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
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: bob))
        #expect(nav.session?.selectedAuthorID == alice)
        #expect(nav.session?.currentPage?.id == aliceGroup.pages[1].id,
                "Backward swiping ignores the previous person's saved first-page cursor")
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice))
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
        #expect(!nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice),
                "Only the current author's last page may cross forward")
        #expect(!nav.selectPagerPage(id: thirdGroup.pages.last!.id, fromAuthorID: alice),
                "The first author cannot wrap backward to the final author")
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice))
        #expect(!nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: alice))
        #expect(!nav.selectPagerPage(id: thirdGroup.pages[0].id, fromAuthorID: alice))
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice))
        #expect(nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: bob))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages.last!.id, fromAuthorID: bob),
                "Only the current author's first page may cross backward")
        #expect(nav.selectPagerPage(id: thirdGroup.pages[0].id, fromAuthorID: bob))
        #expect(nav.selectPagerPage(id: thirdGroup.pages[1].id, fromAuthorID: thirdGroup.authorID))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages[0].id, fromAuthorID: thirdGroup.authorID))
        #expect(!nav.selectPagerPage(id: thirdGroup.pages[1].id, fromAuthorID: thirdGroup.authorID))
        #expect(!nav.selectPagerPage(id: "missing-page", fromAuthorID: thirdGroup.authorID))
        #expect(nav.session?.currentPage?.id == thirdGroup.pages[1].id)
    }

    @Test
    func queuedCardPagerCallbacksCannotChangeAnotherAuthorOrCoveredParent() throws {
        let nav = FriendStoryNavigation()
        let groups = authorSequenceFixtures()
        let aliceGroup = groups[0]
        let bobGroup = groups[1]
        let origin = snapshot(latitude: 47.6, longitude: -122.3)
        nav.begin(groups: groups, authorID: alice, viewedKeys: [], origin: origin)
        #expect(nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice))
        nav.routes.append(.init(content: .reel(reel(id: 900, author: bob, ago: 10)),
                                returnCamera: origin, returnDetent: .large))
        #expect(!nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice))
        #expect(nav.session?.currentPage?.id == aliceGroup.pages[1].id)
        nav.routes.removeAll()
        #expect(nav.selectPagerPage(id: bobGroup.pages[0].id, fromAuthorID: alice))
        #expect(!nav.selectPagerPage(id: aliceGroup.pages[1].id, fromAuthorID: alice),
                "A delayed selection from the departed author's render cannot reverse the swipe")
        #expect(nav.session?.currentPage?.id == bobGroup.pages[0].id)
        nav.clear()
        #expect(!nav.selectPagerPage(id: bobGroup.pages[1].id, fromAuthorID: bob))
    }

    @Test
    func singlePageAuthorsSupportBothCardBoundariesWithoutWrapping() throws {
        let groups = cardPagerFixtures().map {
            FriendStoryGroup(authorID: $0.authorID, user: $0.user, pages: [$0.pages[0]])
        }
        let nav = FriendStoryNavigation()
        nav.begin(groups: groups, authorID: bob, viewedKeys: [],
                  origin: snapshot(latitude: 47.6, longitude: -122.3))
        #expect(nav.selectPagerPage(id: groups[0].pages[0].id, fromAuthorID: bob))
        #expect(!nav.selectPagerPage(id: groups[2].pages[0].id, fromAuthorID: alice))
        #expect(nav.selectPagerPage(id: groups[1].pages[0].id, fromAuthorID: alice))
        #expect(nav.selectPagerPage(id: groups[2].pages[0].id, fromAuthorID: bob))
        #expect(!nav.selectPagerPage(id: groups[0].pages[0].id, fromAuthorID: groups[2].authorID))
        #expect(nav.selectPagerPage(id: groups[1].pages[0].id, fromAuthorID: groups[2].authorID))
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

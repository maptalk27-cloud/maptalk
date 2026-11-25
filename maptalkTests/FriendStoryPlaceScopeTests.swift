import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
@testable import maptalk

@MainActor
struct FriendStoryPlaceScopeTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func mapQueueContainsOnlyItsPlaceAndThreeDisplayedRecentAuthors() throws {
        let latest = visit(102, author: alice, ago: 10, media: [709, 700])
        let expired = visit(106, author: bob, ago: StoryReadKeys.freshWindow + 30, media: [])
        let source = groups([
            place(500, visits: [visit(101, author: alice, ago: 90, media: [701]), latest,
                visit(103, author: bob, ago: 20, media: []),
                visit(104, author: uuid(3), ago: 30, media: []),
                visit(105, author: uuid(4), ago: 40, media: []), expired]),
            place(501, visits: [visit(107, author: alice, ago: 5, media: [])])
        ], asOf: now.addingTimeInterval(-60))
        let originalIDs = source.flatMap(\.pages).map(\.id)
        let entry = try #require(FriendStoryPageSelection.latestPlacePage(placeID: uuid(500), in: source))
        let scoped = FriendStoryFeed.placeGroups(in: source, placeID: uuid(500),
            entryAuthorID: entry.authorID, now: now)
        let nav = FriendStoryNavigation()
        #expect(nav.beginPlace(groups: scoped, placeID: uuid(500), entryPageID: entry.id, origin: origin))
        let session = try #require(nav.session)
        #expect(nav.isPlaceScoped)
        #expect(session.currentPage?.memoryID == latest.id)
        #expect(session.currentPage?.mediaID == uuid(709))
        #expect(Set(session.groups.map(\.authorID)) == [alice, bob, uuid(3)])
        #expect(session.pagesInStoryOrder.map(\.memoryID)
                == [latest.id, latest.id, uuid(103), uuid(104), uuid(101)])
        #expect(session.pagesInStoryOrder.compactMap(\.mediaID) == [uuid(709), uuid(700), uuid(701)])
        #expect(session.pagesInStoryOrder.first?.id == session.currentPage?.id)
        #expect(!session.pagesInStoryOrder.contains { $0.memoryID == expired.id })
        #expect(session.pagesInStoryOrder.allSatisfy {
            if case let .poi(place, _, _) = $0.content { return place.id == uuid(500) }
            return false
        })
        #expect(source.flatMap(\.pages).map(\.id) == originalIDs)
        for destination in session.pagesInStoryOrder.dropFirst() {
            let previous = try #require(nav.session?.currentPage)
            #expect(nav.selectPagerPage(id: destination.id, fromAuthorID: previous.authorID,
                fromPageID: previous.id))
            #expect(nav.session?.currentPage?.publishedAt ?? .distantFuture <= previous.publishedAt)
        }
        #expect(nav.session?.currentPage?.memoryID == uuid(101))
        #expect(nav.session?.isEnded == false, "Arrival at the final slice does not auto-close")
    }

    @Test
    func scopedCursorCannotJumpOutsideButPersonEntryRestoresTheOriginalQueue() throws {
        let source = groups([
            place(500, visits: [visit(101, author: alice, ago: 20, media: []),
                               visit(102, author: bob, ago: 30, media: [])]),
            place(501, visits: [visit(103, author: alice, ago: 5, media: [])])
        ])
        let entry = try #require(FriendStoryPageSelection.latestPlacePage(placeID: uuid(500), in: source))
        let outside = try #require(FriendStoryPageSelection.latestPlacePage(placeID: uuid(501), in: source))
        let nav = FriendStoryNavigation()
        #expect(nav.beginPlace(groups: FriendStoryFeed.placeGroups(in: source, placeID: uuid(500),
            entryAuthorID: alice, now: now), placeID: uuid(500), entryPageID: entry.id, origin: origin))
        #expect(!nav.selectPagerPage(id: outside.id, fromAuthorID: alice, fromPageID: entry.id))
        let key = try #require(entry.locationKey)
        let size = CGSize(width: 390, height: 844)
        nav.lastLocationKey = key
        nav.lastViewportSize = size
        nav.lastFocusedAuthorID = alice
        #expect(!nav.needsMapFocus(locationKey: key, viewportSize: size, authorID: bob))
        nav.begin(groups: source, authorID: alice, viewedKeys: [], origin: origin)
        #expect(!nav.isPlaceScoped)
        #expect(nav.session?.pagesInStoryOrder.map(\.id) == source.flatMap(\.pages).map(\.id))
        #expect(nav.needsMapFocus(locationKey: key, viewportSize: size, authorID: bob))
    }

    @Test
    func mapOnlyRecordsOpenWithoutFeedAndChooseLocalRecencyInsteadOfUnreadRanking() throws {
        let visits = [visit(101, author: alice, ago: 10, media: []),
                      visit(102, author: bob, ago: 20, media: []),
                      visit(103, author: uuid(3), ago: 30, media: []),
                      visit(104, author: uuid(4), ago: 40, media: [])]
        let visiblePlace = place(500, visits: visits)
        let visibleRecords = visits.map { record($0) }
        let readKeys = Set(groups([visiblePlace]).filter { $0.authorID != uuid(4) }.flatMap(\.readKeys))
        let unreadRanked = FriendStoryFeed.groups(reals: [], ratedPOIs: [visiblePlace],
            backendRecords: visibleRecords, viewedKeys: readKeys, userProvider: user, now: now)
        #expect(unreadRanked.first?.authorID == uuid(4))
        #expect(groups([]).isEmpty, "The global feed has not received these map records")

        let unrelated = record(visit(105, author: uuid(5), ago: 1, media: []))
        let scoped = FriendStoryFeed.mapPlaceGroups(for: visiblePlace,
            backendRecords: visibleRecords + [unrelated], viewedKeys: readKeys,
            userProvider: user, now: now)
        #expect(scoped.map(\.authorID) == [alice, bob, uuid(3)])
        #expect(scoped.flatMap(\.pages).map(\.memoryID) == [uuid(101), uuid(102), uuid(103)])
        let entry = try #require(FriendStoryPageSelection.latestPlacePage(placeID: visiblePlace.id, in: scoped))
        let nav = FriendStoryNavigation()
        #expect(nav.beginPlace(groups: scoped, placeID: visiblePlace.id, entryPageID: entry.id, origin: origin))
        let frozenIDs = Set(scoped.flatMap(\.pages).map(\.memoryID))

        // Production reconciles the exact authorized cache IDs, not the empty
        // global feed. A later unrelated visit cannot enter this frozen queue.
        let exactRecords = (visibleRecords + [unrelated]).filter { frozenIDs.contains($0.id) }
        let refreshed = FriendStoryFeed.groups(reals: [], ratedPOIs: [visiblePlace],
            backendRecords: exactRecords, viewedKeys: readKeys, userProvider: user, now: now)
        nav.session?.reconcile(with: refreshed, now: now)
        #expect(nav.session?.pagesInStoryOrder.map(\.id) == scoped.flatMap(\.pages).map(\.id))
        nav.session?.reconcile(with: FriendStoryFeed.groups(reals: [], ratedPOIs: [visiblePlace],
            backendRecords: exactRecords.filter { $0.ownerId != alice },
            userProvider: user, now: now), now: now)
        #expect(nav.session?.currentPage?.authorID == bob, "Revoked cached records still leave the queue")
    }

    @Test
    func scopeRefreshNeverAddsPagesAndRevocationStaysWithinRemainingAuthors() throws {
        let visits = [visit(101, author: alice, ago: 10, media: []),
                      visit(102, author: bob, ago: 20, media: []),
                      visit(103, author: uuid(3), ago: 30, media: [])]
        let source = groups([place(500, visits: visits)])
        let entry = try #require(FriendStoryPageSelection.latestPlacePage(placeID: uuid(500), in: source))
        let nav = FriendStoryNavigation()
        #expect(nav.beginPlace(groups: source, placeID: uuid(500), entryPageID: entry.id, origin: origin))
        let originalIDs = try #require(nav.session?.pagesInStoryOrder.map(\.id))
        nav.session?.reconcile(with: groups([place(500, visits: visits + [
            visit(104, author: alice, ago: 1, media: []),
            visit(105, author: uuid(4), ago: 2, media: [])])]), now: now)
        #expect(nav.session?.pagesInStoryOrder.map(\.id) == originalIDs)
        nav.session?.invalidate(memoryIDs: [uuid(101)])
        #expect(nav.session?.currentPage?.memoryID == uuid(102))
        nav.session?.reconcile(with: groups([
            place(501, visits: [visits[1]]), place(500, visits: [visits[2]])]), now: now)
        #expect(nav.session?.currentPage?.memoryID == uuid(103))
        nav.session?.invalidate(memoryIDs: [uuid(103)])
        #expect(nav.session?.isEnded == true)
    }

    @Test
    func sameDayContinuousMediaShareChromeWithoutReorderingABAOrJoiningDays() throws {
        let source = groups([
            place(500, visits: [visit(101, author: alice, ago: 50, media: [701, 702], day: "2026-09-21"),
                visit(102, author: alice, ago: 40, media: [703], day: "2026-09-21"),
                visit(104, author: alice, ago: 20, media: [705], day: "2026-09-21"),
                visit(105, author: alice, ago: 10, media: [706], day: "2026-09-22")]),
            place(501, visits: [visit(103, author: alice, ago: 30, media: [704], day: "2026-09-21")])
        ])
        let group = try #require(source.first)
        #expect(group.pages.map(\.memoryID) == [uuid(101), uuid(101), uuid(102), uuid(103), uuid(104), uuid(105)])
        #expect(group.moments.map(\.pageRange.count) == [3, 1, 1, 1])
        #expect(group.moments.map(\.placeID) == [uuid(500), uuid(501), uuid(500), uuid(500)])
        let chrome = group.pages.map { page -> FriendStoryPOIChromePage in
            guard case let .poi(place, _, _) = page.content else { preconditionFailure() }
            return .init(id: page.id, place: place, authorID: page.authorID, visitDayKey: page.poiVisitDayKey)
        }
        #expect(FriendStoryPOIChromeRun(pages: chrome, selectedID: chrome[0].id)?.pageIDs == Array(chrome.prefix(3)).map(\.id))
        #expect(FriendStoryPOIChromeRun(pages: chrome, selectedID: chrome[4].id)?.pageIDs == [chrome[4].id])
        #expect(FriendStoryPOIChromeRun(pages: chrome, selectedID: chrome[5].id)?.pageIDs == [chrome[5].id])
        var otherAuthor = chrome[5]
        otherAuthor.authorID = bob
        #expect(!chrome[5].sharesStop(with: otherAuthor))
    }

    private func groups(_ places: [RatedPOI], asOf: Date? = nil) -> [FriendStoryGroup] {
        FriendStoryFeed.groups(reals: [], ratedPOIs: places, userProvider: user, now: asOf ?? now)
    }

    private func visit(_ id: Int, author: UUID, ago: TimeInterval, media ids: [Int], day: String? = nil) -> RatedPOI.CheckIn {
        .init(id: uuid(id), userId: author, createdAt: now.addingTimeInterval(-ago), media: ids.map {
            .init(id: uuid($0), kind: .photo(URL(fileURLWithPath: "/tmp/place-scope-fixture-\($0).jpg")))
        }, visitDay: day)
    }

    private func place(_ id: Int, visits: [RatedPOI.CheckIn]) -> RatedPOI {
        .init(poi: .init(id: uuid(id), name: "Place scope fixture",
                        coordinate: .init(latitude: 47.6 + Double(id - 500) * 0.1, longitude: -122.3),
                        category: .coffee),
              highlight: nil, secondary: nil, media: visits.flatMap(\.media), checkIns: visits,
              comments: [], endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
              tags: [], isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private func record(_ visit: RatedPOI.CheckIn) -> BackendMemory {
        .init(id: visit.id, ownerId: visit.userId,
            owner: .init(id: visit.userId, handle: "person"), kind: "poi", visibility: "public",
            location: .init(latitude: 47.6, longitude: -122.3), caption: "",
            place: .init(id: uuid(500), sourceId: nil, name: "Place scope fixture", category: "coffee",
                coordinate: .init(latitude: 47.6, longitude: -122.3)),
            media: [], createdAt: visit.createdAt, publishedAt: visit.activityDate,
            expiresAt: StoryReadKeys.expiresAt(forActivityAt: visit.activityDate), moderationStatus: "approved")
    }

    private func user(_ id: UUID) -> User? {
        .init(id: id, handle: "person-\(id.uuidString.suffix(2))", avatarURL: nil)
    }

    private var origin: FriendStoryNavigation.MapSnapshot {
        .init(camera: nil, region: .init(center: .init(latitude: 47.6, longitude: -122.3),
                                       span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct FriendStoryFeedTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func oneAuthorHasOneEntryAcrossPlacesRepeatedVisitsAndReels() throws {
        let first = visit(id: 101, author: alice, ago: 300)
        let repeated = visit(id: 102, author: alice, ago: 100)
        let elsewhere = visit(id: 103, author: alice, ago: 50)
        let other = visit(id: 104, author: bob, ago: 20)
        let reel = reel(id: 201, author: alice, ago: 200)
        let groups = groups(reals: [reel], places: [place(id: 500, visits: [first, repeated, other]),
                                                   place(id: 501, visits: [elsewhere])])
        #expect(groups.count == 2)
        let group = try #require(groups.first { $0.authorID == alice })
        #expect(group.pages.map(\.memoryID) == [first.id, reel.id, repeated.id, elsewhere.id])
        #expect(group.pages.allSatisfy { $0.authorID == alice })
        #expect(group.latestTimestamp == elsewhere.activityDate)
        #expect(groups.first?.authorID == bob)
    }

    @Test
    func sharedPlaceSlicesKeepExactOriginalAuthorAndVisit() throws {
        let a = visit(id: 101, author: alice, ago: 100)
        let b = visit(id: 102, author: bob, ago: 80)
        let rated = place(id: 500, visits: [a, b])
        let groups = groups(places: [rated])
        let page = try #require(groups.first { $0.authorID == alice }?.pages.first)
        guard case let .poi(originalPlace, checkIn, media) = page.content else {
            Issue.record("A POI must not be represented as a fake Reel")
            return
        }
        #expect(originalPlace.id == rated.id)
        #expect(checkIn.id == a.id)
        #expect(checkIn.userId == alice)
        #expect(media?.id == a.media.first?.id)
        #expect(page.discussionTarget == .place(rated.id))
        #expect(originalPlace.checkIns.count == 2)
    }

    @Test
    func oldVisitDoesNotReturnWhenSamePersonChecksInAgain() {
        let old = visit(id: 101, author: alice, ago: StoryReadKeys.freshWindow + 1)
        let boundary = visit(id: 102, author: alice, ago: StoryReadKeys.freshWindow)
        let fresh = visit(id: 103, author: alice, ago: StoryReadKeys.freshWindow - 0.001)
        let rated = place(id: 500, visits: [old, boundary, fresh])
        let result = groups(places: [rated])
        #expect(result.first?.pages.map(\.memoryID) == [fresh.id])
        #expect(rated.checkIns.count == 3)
    }

    @Test
    func offlineCaptureBecomesRecentAtFirstPublicationAndPreservesCaptureTime() throws {
        var saved = visit(id: 101, author: alice, ago: StoryReadKeys.freshWindow * 2)
        saved.publishedAt = now.addingTimeInterval(-20)
        let page = try #require(groups(places: [place(id: 500, visits: [saved])]).first?.pages.first)
        #expect(page.publishedAt == saved.publishedAt)
        #expect(page.capturedAt == saved.createdAt)
        #expect(page.expiresAt == saved.publishedAt!.addingTimeInterval(StoryReadKeys.freshWindow))
        #expect(page.readKey == StoryReadKeys.poiStoryPage(poiId: uuid(500), checkInId: saved.id,
            mediaId: saved.media[0].id, timestamp: saved.activityDate))
    }

    @Test
    func nineMediaReelRemainsOneOriginalCardAndBubbleIsNotFlattened() throws {
        var original = reel(id: 201, author: alice, ago: 100)
        original.attachments = (0..<9).map { .init(id: uuid(700 + $0), kind: .photo(photoURL)) }
        original.capsuleId = uuid(900)
        let group = try #require(groups(reals: [original]).first)
        #expect(group.pages.count == 1)
        #expect(group.pages.first?.expectedMedia.count == 9)
        #expect(group.pages.first?.kind == .reelCard)
        guard case let .reel(stored) = group.pages[0].content else { Issue.record("Missing Reel"); return }
        #expect(stored.id == original.id)
        #expect(stored.attachments.map(\.id) == original.attachments.map(\.id))
        #expect(stored.capsuleId == original.capsuleId)
        #expect(group.pages.first?.discussionTarget == .memory(original.id))
    }

    @Test
    func actualNoMediaPOIAndCaptionOnlyReelAreReadablePages() throws {
        let checkIn = visit(id: 101, author: alice, ago: 100, media: [])
        let original = reel(id: 201, author: alice, ago: 50)
        let result = try #require(groups(reals: [original], places: [place(id: 500, visits: [checkIn])]).first)
        #expect(result.pages.map(\.kind) == [.poiLocationOnly, .reelCard])
        #expect(result.pages.allSatisfy { $0.isMediaReady })
        #expect(result.pages.first?.mediaID == nil)
        #expect(result.pages.first?.readKey.hasPrefix("poi-visit:") == true)
    }

    @Test
    func sourceMediaOrderWinsOverUUIDOrdering() throws {
        let assets: [RatedPOI.Media] = [media(800), media(600), media(700)]
        let visit = visit(id: 101, author: alice, ago: 100, media: assets)
        let result = try #require(groups(places: [place(id: 500, visits: [visit])]).first)
        #expect(result.pages.map(\.mediaID) == assets.map { Optional($0.id) })
        #expect(Set(result.pages.map(\.id)).count == 3)
    }

    @Test
    func equalPublicationTimeUsesStableRecordAndAuthorOrdering() {
        let a = reel(id: 203, author: alice, ago: 20)
        let b = reel(id: 201, author: alice, ago: 20)
        let c = reel(id: 202, author: bob, ago: 20)
        let result = groups(reals: [a, c, b])
        #expect(result.map(\.authorID) == [alice, bob])
        #expect(result.first?.pages.map(\.memoryID) == [b.id, a.id])
        #expect(groups(reals: [b, a, c]).first?.pages.map(\.id) == result.first?.pages.map(\.id))
    }

    @Test
    func unreadAuthorsPrecedeNewerReadAuthors() throws {
        let a = reel(id: 201, author: alice, ago: 200)
        let b = reel(id: 202, author: bob, ago: 20)
        let result = groups(reals: [a, b], viewed: [StoryReadKeys.real(b)])
        #expect(result.map(\.authorID) == [alice, bob])
        #expect(result.first?.hasUnviewed == true)
        #expect(result.last?.hasUnviewed == false)
    }

    @Test
    func privateReelsAndExpiredReelsNeverEnterProjectedStories() {
        var privateReel = reel(id: 201, author: alice, ago: 10)
        privateReel.visibility = .privateOnly
        let old = reel(id: 202, author: alice, ago: StoryReadKeys.freshWindow)
        var shortened = reel(id: 203, author: alice, ago: 10)
        shortened.expiresAt = now.addingTimeInterval(-1)
        #expect(groups(reals: [privateReel, old, shortened]).isEmpty)
    }

    @Test
    func authoritativeEmptyBackendSnapshotDoesNotFallbackToStaleProjection() {
        let cached = reel(id: 201, author: alice, ago: 20)
        #expect(groups(reals: [cached], records: []).isEmpty)
        #expect(groups(reals: [cached], records: nil).count == 1)
    }

    @Test
    func backendOnlyAllowsEligiblePublicRecords() {
        var record = record(id: 101, author: alice, kind: "poi", ago: 20)
        record.moderationStatus = "local_pending"
        let privateRecord = recordCopy(record, visibility: "private", moderation: "approved")
        let rejected = recordCopy(record, moderation: "rejected")
        let unknown = self.record(id: 104, author: alice, kind: "collection", ago: 20)
        #expect(groups(records: [record, privateRecord, rejected, unknown]).isEmpty)
    }

    @Test
    func missingDownloadsKeepStablePOIMediaPagesInsteadOfBecomingNoMedia() throws {
        let descriptors = [backendMedia(800, video: true), backendMedia(600)]
        let metadata = record(id: 101, author: alice, kind: "poi", ago: 20, media: descriptors)
        let before = try #require(groups(records: [metadata]).first)
        #expect(before.pages.count == 2)
        #expect(before.pages.allSatisfy { $0.kind == .poiMedia && !$0.isMediaReady })
        #expect(before.pages.map(\.mediaID) == descriptors.map { Optional($0.id) })
        #expect(before.pages.first?.expectedMedia.first?.kind == .video)

        let loaded = visit(id: 101, author: alice, ago: 20,
            media: [.init(id: uuid(800), kind: .video(url: photoURL, poster: nil)), media(600)])
        let after = try #require(groups(places: [place(id: 500, visits: [loaded])], records: [metadata]).first)
        #expect(after.pages.map(\.id) == before.pages.map(\.id))
        #expect(after.readKeys == before.readKeys)
        #expect(after.pages.allSatisfy { $0.isMediaReady })
    }

    @Test
    func backendReelSlotsRemainStableWhileCachedAttachmentsArePartial() throws {
        let assets = (0..<9).map { backendMedia(700 + $0) }
        let metadata = record(id: 201, author: alice, kind: "reel", ago: 20, media: assets)
        var cached = reel(id: 201, author: alice, ago: 20)
        cached.attachments = [.init(id: uuid(704), kind: .photo(photoURL)), .init(id: uuid(700), kind: .photo(photoURL))]
        let before = try #require(groups(reals: [cached], records: [metadata]).first?.pages.first)
        #expect(before.expectedMedia.map(\.id) == assets.map(\.id))
        #expect(before.isMediaReady == false)
        guard case let .reel(partial) = before.content else { Issue.record("Missing Reel"); return }
        #expect(partial.attachments.map(\.id) == [uuid(700), uuid(704)])
        cached.attachments = assets.map { .init(id: $0.id, kind: .photo(photoURL)) }
        let after = try #require(groups(reals: [cached], records: [metadata]).first?.pages.first)
        #expect(after.id == before.id)
        #expect(after.expectedMedia.count == 9)
        #expect(after.isMediaReady)
    }

    @Test
    func backendMetadataRefreshesCaptionOwnerAndPublicationRatherThanCachedValues() throws {
        var cached = reel(id: 201, author: alice, ago: 50)
        cached.message = "stale caption"
        let metadata = record(id: 201, author: alice, kind: "reel", ago: 20)
        let page = try #require(groups(reals: [cached], records: [metadata]).first?.pages.first)
        guard case let .reel(real) = page.content else { Issue.record("Missing Reel"); return }
        #expect(real.message == "caption")
        #expect(page.publishedAt == metadata.publishedAt)
        #expect(page.expiresAt == metadata.publishedAt!.addingTimeInterval(StoryReadKeys.freshWindow))
        #expect(real.id == cached.id)
    }

    @Test
    func backendOwnerCannotBeReplacedByMismatchingCachedAuthor() throws {
        var cached = reel(id: 201, author: bob, ago: 20)
        cached.attachments = [.init(id: uuid(700), kind: .photo(photoURL))]
        let metadata = record(id: 201, author: alice, kind: "reel", ago: 20, media: [backendMedia(700)])
        let page = try #require(groups(reals: [cached], records: [metadata]).first?.pages.first)
        #expect(page.authorID == alice)
        #expect(!page.isMediaReady)
    }

    @Test
    func duplicatesDoNotCreateDuplicateEntriesOrCrash() {
        let original = reel(id: 201, author: alice, ago: 20)
        let visit = visit(id: 101, author: alice, ago: 30)
        let rated = place(id: 500, visits: [visit, visit])
        let projected = groups(reals: [original, original], places: [rated, rated])
        #expect(projected.first?.pages.count == 2)
        let metadata = record(id: 101, author: alice, kind: "poi", ago: 20,
            media: [backendMedia(700), backendMedia(700)])
        #expect(groups(places: [rated, rated], records: [metadata, metadata]).first?.pages.count == 1)
    }

    @Test
    func oneHeavyAuthorDoesNotHideAuthorsAfterFirstHundredRecords() {
        let records = (0..<150).map { record(id: 1_000 + $0, author: alice, kind: "reel", ago: Double($0 + 1)) }
            + [record(id: 2_000, author: bob, kind: "poi", ago: 300)]
        let result = groups(records: records)
        #expect(result.count == 2)
        #expect(result.first { $0.authorID == alice }?.pages.count == 150)
        #expect(result.first { $0.authorID == bob }?.pages.count == 1)
    }

    @Test
    func canonicalPlaceLocationIsSharedButInvalidCoordinatesNeverUsePhoneFallback() throws {
        let visits = [visit(id: 101, author: alice, ago: 20), visit(id: 102, author: bob, ago: 10)]
        let result = groups(places: [place(id: 500, visits: visits)])
        #expect(Set(result.flatMap(\.pages).compactMap(\.locationKey)).count == 1)
        #expect(result.first?.pages.first?.coordinate?.latitude == 47.6)
        var invalid = reel(id: 201, author: alice, ago: 20)
        invalid.center = .init(latitude: .nan, longitude: 250)
        let page = try #require(groups(reals: [invalid]).first?.pages.first)
        #expect(page.coordinate == nil)
        #expect(page.locationKey == nil)
    }

    @Test
    func firstEntryStartsAtFirstUnreadAndAllReadStartsAtLatestPublicationsFirstSlice() throws {
        let first = visit(id: 101, author: alice, ago: 100)
        let last = visit(id: 102, author: alice, ago: 20, media: [media(700), media(701)])
        let result = groups(places: [place(id: 500, visits: [first, last])])
        let pages = try #require(result.first?.pages)
        let partial = try #require(FriendStorySession(groups: result, authorID: alice, viewedKeys: [pages[0].readKey]))
        #expect(partial.currentPage?.id == pages[1].id)
        let complete = try #require(FriendStorySession(groups: result, authorID: alice,
            viewedKeys: Set(pages.map(\.readKey))))
        #expect(complete.currentPage?.id == pages[1].id)
    }

    @Test
    func pageBoundariesNeverImplicitlySwitchAuthorsOrWrap() throws {
        let result = groups(reals: [reel(id: 201, author: alice, ago: 30), reel(id: 202, author: bob, ago: 20)])
        var session = try #require(FriendStorySession(groups: result, authorID: alice))
        let original = session.currentPage?.id
        let navigationResult1 = !session.movePage(by: -1)
        #expect(navigationResult1)
        let navigationResult2 = !session.movePage(by: 1)
        #expect(navigationResult2)
        let navigationResult3 = !session.movePage(by: Int.max)
        #expect(navigationResult3)
        #expect(session.selectedAuthorID == alice)
        #expect(session.currentPage?.id == original)
        let navigationResult4 = !session.moveAuthor(by: Int.max)
        #expect(navigationResult4)
        let navigationResult5 = session.selectAuthor(id: bob)
        #expect(navigationResult5)
        let navigationResult6 = !session.moveAuthor(by: -1)
        #expect(navigationResult6)
        #expect(session.selectedAuthorID == bob)
    }

    @Test
    func switchingBackToAuthorResumesTheirExactSlice() throws {
        let a = visit(id: 101, author: alice, ago: 100, media: [media(700), media(701), media(702)])
        let b = visit(id: 102, author: bob, ago: 20)
        let result = groups(places: [place(id: 500, visits: [a, b])])
        var session = try #require(FriendStorySession(groups: result, authorID: alice))
        let navigationResult7 = session.movePage(by: 2)
        #expect(navigationResult7)
        let saved = session.currentPage?.id
        let navigationResult8 = session.selectAuthor(id: bob)
        #expect(navigationResult8)
        let navigationResult9 = session.selectAuthor(id: alice)
        #expect(navigationResult9)
        #expect(session.currentPage?.id == saved)
        #expect(session.currentPageIndex == 2)
        let navigationResult10 = !session.selectPage(id: "another-author-or-unknown-page")
        #expect(navigationResult10)
    }

    @Test
    func sessionFreezesOrderAndMembershipWhileUpdatingLoadedPayloads() throws {
        let a = record(id: 101, author: alice, kind: "poi", ago: 100, media: [backendMedia(700)])
        let b = record(id: 201, author: bob, kind: "reel", ago: 20)
        let initial = groups(records: [a, b])
        var session = try #require(FriendStorySession(groups: initial, authorID: alice))
        let originalPage = session.currentPage?.id
        let originalAuthors = session.groups.map(\.id)
        let newA = record(id: 202, author: alice, kind: "reel", ago: 1)
        let c = record(id: 203, author: uuid(3), kind: "reel", ago: 2)
        let loaded = visit(id: 101, author: alice, ago: 100, media: [media(700)])
        let refreshed = groups(places: [place(id: 500, visits: [loaded])], records: [a, b, newA, c])
        session.reconcile(with: refreshed, now: now)
        #expect(session.groups.map(\.id) == originalAuthors)
        #expect(session.groups.flatMap(\.pages).count == 2)
        #expect(session.currentPage?.id == originalPage)
        #expect(session.currentPage?.isMediaReady == true)
        let navigationResult11 = !session.selectAuthor(id: uuid(3))
        #expect(navigationResult11)
    }

    @Test
    func deletingCurrentPageChoosesNextSameAuthorThenPrevious() throws {
        let originals = [reel(id: 201, author: alice, ago: 100), reel(id: 202, author: alice, ago: 70),
                         reel(id: 203, author: alice, ago: 20), reel(id: 204, author: bob, ago: 10)]
        var session = try #require(FriendStorySession(groups: groups(reals: originals), authorID: alice))
        let navigationResult12 = session.movePage(by: 1)
        #expect(navigationResult12)
        session.invalidate(memoryIDs: [uuid(202)])
        #expect(session.currentPage?.memoryID == uuid(203))
        session.invalidate(memoryIDs: [uuid(203)])
        #expect(session.currentPage?.memoryID == uuid(201))
        #expect(session.selectedAuthorID == alice)
        session.invalidate(memoryIDs: [uuid(201)])
        #expect(session.isEnded)
        #expect(session.currentPage == nil)
        #expect(session.groups.isEmpty)
        let navigationResult13 = !session.selectAuthor(id: bob)
        #expect(navigationResult13)
    }

    @Test
    func authoritativeRevocationCannotBeOverriddenByStaleRefreshedPayload() throws {
        let originals = [reel(id: 201, author: alice, ago: 100), reel(id: 202, author: alice, ago: 70)]
        let initial = groups(reals: originals)
        var session = try #require(FriendStorySession(groups: initial, authorID: alice))
        session.reconcile(with: initial, now: now, validMemoryIDs: [uuid(202)])
        #expect(session.currentPage?.memoryID == uuid(202))
        #expect(session.currentGroup?.pages.count == 1)
        session.reconcile(with: initial, now: now, validMemoryIDs: [uuid(201), uuid(202)])
        #expect(session.currentGroup?.pages.map(\.memoryID) == [uuid(202)])
    }

    @Test
    func naturalExpiryRetentionRequiresExplicitStillVisibleRecordAndOnlyKeepsCurrent() throws {
        let original = reel(id: 201, author: alice, ago: StoryReadKeys.freshWindow - 1)
        let next = reel(id: 202, author: alice, ago: 20)
        let initial = groups(reals: [original, next])
        var retained = try #require(FriendStorySession(groups: initial, authorID: alice))
        let future = now.addingTimeInterval(2)
        let fresh = FriendStoryFeed.groups(reals: [next], ratedPOIs: [], userProvider: { _ in nil }, now: future)
        retained.reconcile(with: fresh, now: future, retainCurrentExpiredPage: true,
            validMemoryIDs: [original.id, next.id])
        #expect(retained.currentPage?.memoryID == original.id)
        let navigationResult14 = retained.movePage(by: 1)
        #expect(navigationResult14)
        retained.reconcile(with: fresh, now: future, retainCurrentExpiredPage: true,
            validMemoryIDs: [original.id, next.id])
        #expect(retained.currentGroup?.pages.map(\.memoryID) == [next.id])
        var unknownAccess = try #require(FriendStorySession(groups: initial, authorID: alice))
        unknownAccess.reconcile(with: fresh, now: future, retainCurrentExpiredPage: true)
        #expect(unknownAccess.currentPage?.memoryID == next.id)
    }

    @Test
    func expiredLastPageDoesNotAutomaticallyAdvanceToAnotherAuthor() throws {
        let a = reel(id: 201, author: alice, ago: StoryReadKeys.freshWindow - 1)
        let b = reel(id: 202, author: bob, ago: 20)
        var session = try #require(FriendStorySession(groups: groups(reals: [a, b]), authorID: alice))
        session.reconcile(with: groups(reals: [b]), now: now.addingTimeInterval(2))
        #expect(session.isEnded)
        #expect(session.selectedAuthorID == nil)
    }

    @Test
    func deletedSavedPositionIsNotResurrectedWhenReturningToAuthor() throws {
        let originals = [reel(id: 201, author: alice, ago: 100), reel(id: 202, author: alice, ago: 50),
                         reel(id: 203, author: bob, ago: 20)]
        var session = try #require(FriendStorySession(groups: groups(reals: originals), authorID: alice))
        let navigationResult15 = session.movePage(by: 1)
        #expect(navigationResult15)
        let navigationResult16 = session.selectAuthor(id: bob)
        #expect(navigationResult16)
        session.invalidate(memoryIDs: [uuid(202)])
        let navigationResult17 = session.selectAuthor(id: alice)
        #expect(navigationResult17)
        #expect(session.currentPage?.memoryID == uuid(201))
    }

    @Test
    func sessionEndClearsSnapshotsAndCannotBeRevivedByReconciliation() throws {
        let original = groups(reals: [reel(id: 201, author: alice, ago: 100)])
        var session = try #require(FriendStorySession(groups: original, authorID: alice))
        session.end()
        session.reconcile(with: original, now: now)
        #expect(session.isEnded)
        #expect(session.groups.isEmpty)
        #expect(session.resumePageIDs.isEmpty)
        let navigationResult18 = !session.moveAuthor(by: 0)
        #expect(navigationResult18)
        #expect(FriendStorySession(groups: [], authorID: alice) == nil)
    }

    private var photoURL: URL { URL(fileURLWithPath: "/tmp/friend-story-fixture.jpg") }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func media(_ number: Int) -> RatedPOI.Media { .init(id: uuid(number), kind: .photo(photoURL)) }

    private func visit(id: Int, author: UUID, ago: TimeInterval, media: [RatedPOI.Media]? = nil) -> RatedPOI.CheckIn {
        .init(id: uuid(id), userId: author, createdAt: now.addingTimeInterval(-ago),
            media: media ?? [self.media(id + 10_000)])
    }

    private func place(id: Int, visits: [RatedPOI.CheckIn]) -> RatedPOI {
        .init(poi: .init(id: uuid(id), name: "Shared place", coordinate: .init(latitude: 47.6, longitude: -122.3),
            category: .coffee), highlight: nil, secondary: nil, media: visits.flatMap(\.media), checkIns: visits,
            comments: [], endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private func reel(id: Int, author: UUID, ago: TimeInterval) -> RealPost {
        let time = now.addingTimeInterval(-ago)
        return .init(id: uuid(id), userId: author, center: .init(latitude: 47.6, longitude: -122.3),
            radiusMeters: 220, message: "caption", attachments: [], likes: [], comments: [],
            visibility: .publicAll, createdAt: time, expiresAt: time.addingTimeInterval(StoryReadKeys.freshWindow))
    }

    private func backendMedia(_ id: Int, video: Bool = false) -> BackendMedia {
        .init(id: uuid(id), mimeType: video ? "video/mp4" : "image/jpeg", byteCount: 100,
            path: "/v1/media/\(uuid(id).uuidString)")
    }

    private func record(id: Int, author: UUID, kind: String, ago: TimeInterval,
                        media: [BackendMedia] = []) -> BackendMemory {
        let time = now.addingTimeInterval(-ago)
        return .init(id: uuid(id), ownerId: author, owner: .init(id: author, handle: "person"), kind: kind,
            visibility: "public", location: .init(latitude: 47.61, longitude: -122.31), caption: "caption",
            place: kind == "poi" ? .init(id: uuid(500), sourceId: nil, name: "Shared place", category: "coffee",
                coordinate: .init(latitude: 47.6, longitude: -122.3)) : nil,
            media: media, createdAt: time.addingTimeInterval(-100), publishedAt: time,
            expiresAt: time.addingTimeInterval(StoryReadKeys.freshWindow), moderationStatus: "approved")
    }

    private func recordCopy(_ value: BackendMemory, visibility: String? = nil,
                            moderation: String? = nil) -> BackendMemory {
        .init(id: value.id, ownerId: value.ownerId, owner: value.owner, kind: value.kind,
            visibility: visibility ?? value.visibility, location: value.location, caption: value.caption,
            place: value.place, media: value.media, createdAt: value.createdAt, publishedAt: value.publishedAt,
            expiresAt: value.expiresAt, moderationStatus: moderation ?? value.moderationStatus)
    }

    private func groups(reals: [RealPost] = [], places: [RatedPOI] = [], records: [BackendMemory]? = nil,
                        viewed: Set<String> = []) -> [FriendStoryGroup] {
        FriendStoryFeed.groups(reals: reals, ratedPOIs: places, backendRecords: records, viewedKeys: viewed,
            userProvider: { User(id: $0, handle: $0 == alice ? "Alice" : "Bob", avatarURL: nil) }, now: now)
    }
}

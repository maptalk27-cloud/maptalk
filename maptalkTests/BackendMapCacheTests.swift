import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendMapCacheTests {
    @Test(.timeLimit(.minutes(1)))
    func placeHistoryReadsOnePageThenExplicitlyAppendsWithoutChangingActiveFeedOrApplyingItsExpiry() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let active = fixture.poiMemory()
        var historical = fixture.poiMemory(publishedAt: .now.addingTimeInterval(-30 * 86_400))
        historical.place = active.place
        try await fixture.seed(mine: [active], feed: [active])
        let firstPage = fixture.page([active], nextCursor: "older-visits")
        let secondPage = fixture.page([historical])
        let expectedPath = "/v1/places/\(active.place!.id.uuidString)/memories"
        MapCacheProtocol.install { operation in
            #expect(operation.request.url?.path == expectedPath)
            let query = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first { $0.name == "limit" }?.value == "12")
            let cursor = query?.first { $0.name == "cursor" }?.value
            operation.respond(cursor == nil ? firstPage : secondPage)
        }
        var snapshots: [BackendStore.PlaceHistoryPage] = []
        let first = try await fixture.store.loadPlaceHistory(placeID: active.place!.id) { snapshots.append($0) }
        #expect(first.place?.checkIns.map(\.id) == [active.id])
        #expect(first.nextCursor == "older-visits")
        #expect(snapshots.count == 1)
        let result = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: first)
        #expect(Set(result.place?.checkIns.map(\.id) ?? []) == [active.id, historical.id])
        #expect(result.nextCursor == nil)
        #expect(first.place?.checkIns.map(\.id) == [active.id], "Appending must not mutate the verified prior page")
        MapCacheProtocol.install { _ in Issue.record("Exhausted history must not fetch again") }
        let exhausted = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: result)
        #expect(exhausted.place?.checkIns.count == 2)
        #expect(fixture.store.feedRecords.value.map(\.id) == [active.id])
        #expect(fixture.store.feedPOIs.value.first?.checkIns.map(\.id) == [active.id])
        #expect(fixture.store.excludedMapMemoryIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func earlierVisitFailureRetainsPriorPageAndRetryUsesTheSameCursor() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let active = fixture.poiMemory()
        var older = fixture.poiMemory(publishedAt: .now.addingTimeInterval(-30 * 86_400))
        older.place = active.place
        let initial = fixture.page([active], nextCursor: "older-visits")
        MapCacheProtocol.install { $0.respond(initial) }
        let first = try await fixture.store.loadPlaceHistory(placeID: active.place!.id)
        MapCacheProtocol.install { operation in
            let cursor = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            #expect(cursor == "older-visits")
            operation.respond(Data(), status: 503)
        }
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: first) { _ in
                Issue.record("Failed metadata cannot replace a verified page")
            }
            Issue.record("Expected a failed next page")
        } catch {
            #expect(BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: true,
                requestRevision: first.revision, currentRevision: fixture.store.publicContentRevision, isActive: true))
        }
        #expect(first.place?.checkIns.map(\.id) == [active.id])
        let retry = fixture.page([active, older]) // Deduplicate a record that straddles pages.
        MapCacheProtocol.install { operation in
            let cursor = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            #expect(cursor == "older-visits")
            operation.respond(retry)
        }
        let loaded = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: first)
        #expect(Set(loaded.place?.checkIns.map(\.id) ?? []) == [active.id, older.id])
        #expect(loaded.place?.checkIns.count == 2)
        #expect(loaded.nextCursor == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func placeHistoryRejectsUnboundedPagesAndRepeatedCursorsBeforeProjection() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let active = fixture.poiMemory()
        let initial = fixture.page([active], nextCursor: "older-visits")
        MapCacheProtocol.install { $0.respond(initial) }
        let first = try await fixture.store.loadPlaceHistory(placeID: active.place!.id)
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: first) { _ in
                Issue.record("Repeated cursors must not replace verified history")
            }
            Issue.record("Repeated cursor should fail without fetching infinitely")
        } catch {}
        let oversized = fixture.page(Array(repeating: active, count: 13))
        MapCacheProtocol.install { $0.respond(oversized) }
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id) { _ in
                Issue.record("Oversized metadata response must fail before preparing media")
            }
            Issue.record("Expected the 12-record bound to be enforced")
        } catch {}
        #expect(first.place?.checkIns.map(\.id) == [active.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func placeHistoryDownloadsOnlyTheRequestedPageAndKeepsItsVerifiedMetadataOnMediaFailure() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let firstMediaID = UUID()
        let secondMediaID = UUID()
        let firstMedia = BackendMedia(id: firstMediaID, mimeType: "video/mp4", byteCount: 20_000_000,
            path: "/v1/media/\(firstMediaID.uuidString.lowercased())")
        let secondMedia = BackendMedia(id: secondMediaID, mimeType: "video/mp4", byteCount: 20_000_000,
            path: "/v1/media/\(secondMediaID.uuidString.lowercased())")
        let active = fixture.poiMemory(media: [firstMedia])
        var older = fixture.poiMemory(publishedAt: .now.addingTimeInterval(-30 * 86_400), media: [secondMedia])
        older.place = active.place
        let firstData = fixture.page([active], nextCursor: "older-visits")
        MapCacheProtocol.install { operation in
            if operation.request.url?.path == firstMedia.path { operation.respond(Data(), status: 503) }
            else {
                let query = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.contains { $0.name == "cursor" } == false, "Initial load must not follow older cursors")
                operation.respond(firstData)
            }
        }
        var first: BackendStore.PlaceHistoryPage?
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id) { first = $0 }
            Issue.record("Expected simulated video download failure")
        } catch {}
        let verified = try #require(first)
        #expect(verified.place?.checkIns.map(\.id) == [active.id])
        #expect(verified.nextCursor == "older-visits")
        let secondData = fixture.page([older])
        MapCacheProtocol.install { operation in
            let path = operation.request.url?.path
            #expect(path != firstMedia.path, "Appending may prepare only the new page's media")
            if path == secondMedia.path || path == firstMedia.path { operation.respond(Data(), status: 503) }
            else { operation.respond(secondData) }
        }
        var appended: BackendStore.PlaceHistoryPage?
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: verified) { appended = $0 }
            Issue.record("Expected simulated video download failure")
        } catch {}
        #expect(Set(appended?.place?.checkIns.map(\.id) ?? []) == [active.id, older.id])
        #expect(appended?.nextCursor == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func placeHistoryCannotAppendAcrossStoreScopesOrWithdrawalRevisions() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let active = fixture.poiMemory()
        try await fixture.seed(mine: [active], feed: [active])
        let initial = fixture.page([active], nextCursor: "older-visits")
        MapCacheProtocol.install { $0.respond(initial) }
        let first = try await fixture.store.loadPlaceHistory(placeID: active.place!.id)
        let otherStore = fixture.makeStore()
        defer { otherStore.clearLocalMedia() }
        MapCacheProtocol.install { _ in Issue.record("A page from another login/store must not fetch") }
        do {
            _ = try await otherStore.loadPlaceHistory(placeID: active.place!.id, after: first)
            Issue.record("Expected scope invalidation")
        } catch { #expect(error is CancellationError) }
        MapCacheProtocol.install { $0.respond(Data()) }
        try await fixture.store.deletePost(memoryID: active.id, refreshAfterward: false)
        MapCacheProtocol.install { _ in Issue.record("An invalidated history page must not fetch") }
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id, after: first)
            Issue.record("Expected withdrawal revision invalidation")
        } catch { #expect(error is CancellationError) }
    }

    @Test(.timeLimit(.minutes(1)))
    func unavailableOrMalformedPlaceHistoryNeverClaimsAnEmptyCompleteResult() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let active = fixture.poiMemory()
        try await fixture.seed(mine: [active], feed: [active])
        MapCacheProtocol.install { $0.respond(Data("{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}".utf8), status: 404) }
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id)
            Issue.record("An older backend must not be represented as complete empty place history")
        } catch let error as BackendClientError {
            guard case let .http(status, _, _) = error else { Issue.record("Expected original HTTP error"); return }
            #expect(status == 404)
        }
        fixture.replyMap([fixture.poiMemory()])
        do {
            _ = try await fixture.store.loadPlaceHistory(placeID: active.place!.id)
            Issue.record("Wrong-place records must be rejected")
        } catch {}
        #expect(fixture.store.feedRecords.value.map(\.id) == [active.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func cachedFeedAndSelectedSnapshotsCannotRestoreExcludedMapContent() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let reel = fixture.memory(latitude: 37)
        let poi = fixture.poiMemory()
        let history = fixture.poiMemory(publishedAt: .now.addingTimeInterval(-90 * 3_600))
        let records = [reel, poi, history]
        try await fixture.seed(mine: records, feed: records)
        fixture.failMap()
        let repository = BackendPOIRepository(store: fixture.store)
        let environment = AppEnvironment(build: .init(configuration: .debug, featureFlags: []),
            location: MapCacheLocationService(), notifications: NotificationServiceImpl(),
            activePOIRepo: repository, poiRepo: repository,
            realRepo: BackendRealRepository(store: fixture.store),
            myMapArchive: fixture.store.archive, backend: fixture.store)
        let model = MapTalkViewModel(environment: environment)
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        let selectedReel = try #require(fixture.store.feedReels.value.first)
        let selectedPOI = try #require(fixture.store.feedPOIs.value.first { $0.id == poi.place?.id })
        #expect(model.mapRenderReels(retaining: nil).contains { $0.id == reel.id })
        #expect(model.mapRenderPOIs(retaining: nil).contains { $0.id == poi.place?.id })

        fixture.replyMap([])
        _ = try await fixture.store.loadMap(fixture.region)
        #expect(fixture.store.excludedMapMemoryIDs == Set(records.map(\.id)))
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.region).reels.isEmpty)
        model.refreshFreshness(asOf: .now)
        #expect(model.mapRenderReels(retaining: reel.id, selectedMapReel: selectedReel).isEmpty)
        #expect(model.mapRenderPOIs(retaining: selectedPOI.id, selectedMapPOI: selectedPOI).isEmpty)
        #expect(model.friendFootprints.isEmpty)
        #expect(fixture.store.feedReels.value.map(\.id) == [reel.id],
                "Map absence must not destructively rewrite the independent feed cache")
        #expect(Set(fixture.store.feedRecords.value.map(\.id)) == Set(records.map(\.id)))
        #expect(Set(model.friendStoryRecords?.map(\.id) ?? []) == [reel.id, poi.id],
                "Person stories exclude expired records but must not disappear when the viewport changes")
        #expect(fixture.store.archive.privateReels.map(\.id) == [reel.id])
        #expect(fixture.store.archive.privatePOIs.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func storyMetadataNeverAdoptsPrivateQueuedDeletedOrBlockedCachedRecords() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let visible = fixture.memory(latitude: 37)
        let privatePost = fixture.memory(latitude: 37, visibility: "private")
        let pending = fixture.memory(latitude: 37, moderation: "local_pending")
        let deleted = fixture.memory(latitude: 37)
        let queued = fixture.memory(latitude: 37)
        let blockedID = UUID()
        let blocked = BackendMemory(id: UUID(), ownerId: blockedID, owner: .init(id: blockedID, handle: "blocked"),
            kind: "reel", visibility: "public", location: .init(latitude: 37, longitude: -122), caption: "", place: nil,
            media: [], createdAt: .now, publishedAt: .now, expiresAt: .now.addingTimeInterval(86_400))
        let input = BackendMemoryInput(id: queued.id, kind: "reel", visibility: "public", location: queued.location)
        let state = BackendLocalState(ownerID: fixture.owner.id, server: fixture.api.baseURL.absoluteString,
            user: fixture.owner, mine: [visible, privatePost, pending, deleted, queued],
            feed: [visible, privatePost, pending, deleted, queued, blocked],
            queued: [.init(input: input, record: queued, photos: [])], deleted: [deleted.id], blocked: [blockedID])
        try await BackendLocalStateDisk(directory: fixture.directory).save(state, revision: 0)
        #expect(await fixture.store.restoreCachedState())
        #expect(fixture.store.feedRecords.value.map(\.id) == [visible.id])
        fixture.replyMap([fixture.memory(latitude: 37)])
        _ = try await fixture.store.loadMap(fixture.region)
        #expect(fixture.store.feedRecords.value.map(\.id) == [visible.id], "A viewport is never a Feed source")
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyAuthoritativeViewportDoesNotResurrectOfflineOrEraseArchive() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let inside = fixture.memory(latitude: 37)
        let outside = fixture.memory(latitude: 40)
        try await fixture.seed(mine: [inside, outside], feed: [inside, outside])
        fixture.replyMap([])
        #expect(try await fixture.store.loadMap(fixture.region).reels.isEmpty)
        #expect(Set(fixture.store.archive.privateReels.map(\.id)) == [inside.id, outside.id])
        #expect(Set(fixture.store.ownPublicReels.map(\.id)) == [inside.id, outside.id])
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.wideRegion).reels.map(\.id) == [outside.id])

        let restored = fixture.makeStore()
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        #expect(restored.excludedMapMemoryIDs == [inside.id])
        #expect(try await restored.loadMap(fixture.wideRegion).reels.map(\.id) == [outside.id])
        #expect(Set(restored.archive.privateReels.map(\.id)) == [inside.id, outside.id])
        #expect(Set(restored.ownPublicReels.map(\.id)) == [inside.id, outside.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func partialPageFailureCannotEvictKnownMapRecords() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let original = fixture.memory(latitude: 37)
        try await fixture.seed(mine: [original], feed: [original])
        let firstPage = fixture.page([], nextCursor: "page-two")
        MapCacheProtocol.install { operation in
            let cursor = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            if cursor == nil { operation.respond(firstPage) }
            else { operation.respond(Data(), status: 503) }
        }
        #expect(try await fixture.store.loadMap(fixture.region).reels.map(\.id) == [original.id])
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.region).reels.map(\.id) == [original.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementWaitsForAllPagesAndOnlyExcludesAbsentRecords() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let first = fixture.memory(latitude: 37)
        let second = fixture.memory(latitude: 37)
        let removed = fixture.memory(latitude: 37)
        try await fixture.seed(mine: [first, second, removed], feed: [first, second, removed])
        let firstPage = fixture.page([first], nextCursor: "page-two")
        let secondPage = fixture.page([second])
        MapCacheProtocol.install { operation in
            let cursor = URLComponents(url: operation.request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            operation.respond(cursor == nil ? firstPage : secondPage)
        }
        #expect(Set(try await fixture.store.loadMap(fixture.region).reels.map(\.id)) == [first.id, second.id])
        fixture.failMap()
        #expect(Set(try await fixture.store.loadMap(fixture.region).reels.map(\.id)) == [first.id, second.id])
        #expect(fixture.store.archive.privateReels.count == 3)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func freshPublicReadCanMakeAnExcludedRecordEligibleAgain(isProfile: Bool) async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let record = fixture.memory(latitude: 37)
        try await fixture.seed(mine: [record], feed: [record])
        fixture.replyMap([])
        _ = try await fixture.store.loadMap(fixture.region)
        fixture.replyRefresh([record])
        if isProfile { _ = try await fixture.store.loadProfile(userID: fixture.owner.id) }
        else { try await fixture.store.refresh() }
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.region).reels.map(\.id) == [record.id])
        let restored = fixture.makeStore()
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        #expect(try await restored.loadMap(fixture.region).reels.map(\.id) == [record.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func staleInflightFeedCannotUndoANewerMapAbsence() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let record = fixture.memory(latitude: 37)
        try await fixture.seed(mine: [record], feed: [record])
        let (requests, continuation) = AsyncStream<MapCacheProtocol>.makeStream()
        defer { continuation.finish() }
        let identity = fixture.identityData
        let page = fixture.page([record])
        let empty = fixture.page([])
        MapCacheProtocol.install { operation in
            switch operation.request.url?.path {
            case "/v1/feed": continuation.yield(operation)
            case "/v1/map/memories": operation.respond(empty)
            case "/v1/me": operation.respond(identity)
            default: operation.respond(page)
            }
        }
        let refresh = Task { try await fixture.store.refresh() }
        defer { refresh.cancel() }
        var iterator = requests.makeAsyncIterator()
        let heldFeed = try #require(await iterator.next())
        _ = try await fixture.store.loadMap(fixture.region)
        heldFeed.respond(page)
        try await refresh.value
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.region).reels.isEmpty)
        #expect(fixture.store.archive.privateReels.map(\.id) == [record.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyCachedExpiryUsesPublicationBased72HoursWithoutDeletingHistory() async throws {
        let fixture = try MapCacheFixture()
        defer { fixture.finish() }
        let recent = fixture.memory(latitude: 37, publishedAt: .now.addingTimeInterval(-48 * 3_600))
        let expired = fixture.memory(latitude: 37, publishedAt: .now.addingTimeInterval(-80 * 3_600))
        try await fixture.seed(mine: [recent, expired], feed: [recent, expired])
        let projected = try #require(fixture.store.archive.privateReels.first { $0.id == recent.id })
        #expect(StoryReadKeys.freshWindow == 72 * 3_600)
        #expect(projected.expiresAt == recent.publishedAt!.addingTimeInterval(StoryReadKeys.freshWindow))
        #expect(recent.expiresAt < .now, "Fixture must contain the legacy 24-hour expiry")
        fixture.failMap()
        #expect(try await fixture.store.loadMap(fixture.region).reels.map(\.id) == [recent.id])
        #expect(fixture.store.archive.privateReels.count == 2)
    }
}

@MainActor
private final class MapCacheFixture {
    let owner = BackendUser(id: UUID(), handle: "map_cache")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("map-cache-\(UUID())")
    let region = MKCoordinateRegion(center: .init(latitude: 37, longitude: -122), span: .init(latitudeDelta: 1, longitudeDelta: 1))
    let wideRegion = MKCoordinateRegion(center: .init(latitude: 38, longitude: -122), span: .init(latitudeDelta: 10, longitudeDelta: 10))
    let session: URLSession
    let api: BackendAPI
    lazy var store = makeStore()

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapCacheProtocol.self]
        session = URLSession(configuration: configuration)
        api = BackendAPI(baseURL: URL(string: "https://map-cache-test.invalid")!, session: session)
        api.token = "isolated-map-cache-token"
    }

    func makeStore() -> BackendStore {
        BackendStore(user: .init(id: owner.id, handle: owner.handle, avatarURL: nil), api: api,
                     storageDirectory: directory, automaticallySync: false, observesConnectivity: false)
    }

    func seed(mine: [BackendMemory], feed: [BackendMemory]) async throws {
        let state = BackendLocalState(ownerID: owner.id, server: api.baseURL.absoluteString, user: owner,
                                      mine: mine, profile: mine, feed: feed)
        try await BackendLocalStateDisk(directory: directory).save(state, revision: 0)
        #expect(await store.restoreCachedState())
    }

    func memory(latitude: Double, publishedAt: Date = .now, visibility: String = "public",
                moderation: String = "approved") -> BackendMemory {
        BackendMemory(id: UUID(), ownerId: owner.id, owner: owner, kind: "reel", visibility: visibility,
                      location: .init(latitude: latitude, longitude: -122), caption: "Cached post", place: nil,
                      media: [], createdAt: publishedAt.addingTimeInterval(-86_400), publishedAt: publishedAt,
                      expiresAt: publishedAt.addingTimeInterval(86_400), moderationStatus: moderation)
    }

    func poiMemory(publishedAt: Date = .now, media: [BackendMedia] = []) -> BackendMemory {
        let coordinate = BackendCoordinate(latitude: 37, longitude: -122)
        return BackendMemory(id: UUID(), ownerId: owner.id, owner: owner, kind: "poi", visibility: "public",
            location: coordinate, caption: "", place: .init(id: UUID(), sourceId: nil, name: "Cached café",
                category: "coffee", coordinate: coordinate), media: media, createdAt: publishedAt,
            publishedAt: publishedAt, expiresAt: publishedAt.addingTimeInterval(86_400), moderationStatus: "approved")
    }

    func page(_ items: [BackendMemory], nextCursor: String? = nil) -> Data {
        struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(Page(items: items, nextCursor: nextCursor))
    }

    var identityData: Data { Data("{\"user\":{\"id\":\"\(owner.id)\",\"handle\":\"map_cache\"}}".utf8) }

    func replyMap(_ records: [BackendMemory]) {
        let data = page(records)
        MapCacheProtocol.install { $0.respond(data) }
    }

    func failMap() { MapCacheProtocol.install { $0.respond(Data(), status: 503) } }

    func replyRefresh(_ records: [BackendMemory]) {
        let identity = identityData
        let data = page(records)
        let profilePath = "/v1/users/\(owner.id.uuidString)"
        MapCacheProtocol.install { operation in
            let path = operation.request.url?.path
            operation.respond(path == "/v1/me" || path == profilePath ? identity : data)
        }
    }

    func finish() {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        MapCacheProtocol.install(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MapCacheLocationService: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)
    func requestWhenInUse() {}
}

private final class MapCacheProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (MapCacheProtocol) -> Void)?
    static func install(_ value: (@Sendable (MapCacheProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

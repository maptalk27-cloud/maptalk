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
        #expect(fixture.store.archive.privateReels.map(\.id) == [reel.id])
        #expect(fixture.store.archive.privatePOIs.count == 2)
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

    func memory(latitude: Double, publishedAt: Date = .now) -> BackendMemory {
        BackendMemory(id: UUID(), ownerId: owner.id, owner: owner, kind: "reel", visibility: "public",
                      location: .init(latitude: latitude, longitude: -122), caption: "Cached post", place: nil,
                      media: [], createdAt: publishedAt.addingTimeInterval(-86_400), publishedAt: publishedAt,
                      expiresAt: publishedAt.addingTimeInterval(86_400), moderationStatus: "approved")
    }

    func poiMemory(publishedAt: Date = .now) -> BackendMemory {
        let coordinate = BackendCoordinate(latitude: 37, longitude: -122)
        return BackendMemory(id: UUID(), ownerId: owner.id, owner: owner, kind: "poi", visibility: "public",
            location: coordinate, caption: "", place: .init(id: UUID(), sourceId: nil, name: "Cached café",
                category: "coffee", coordinate: coordinate), media: [], createdAt: publishedAt,
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

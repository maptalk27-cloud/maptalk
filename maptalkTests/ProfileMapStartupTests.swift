import Combine
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct ProfileMapStartupTests {
    @Test
    func ownMapStartsWithTheVisiblePublicProfileBeforeAnyNetworkResponse() throws {
        let context = makeContext()
        defer { context.finish() }
        let post = makePost(ownerID: context.store.user.id, visibility: .publicAll)
        var place = PreviewData.sampleRatedPOIs[0]
        place.checkIns = [.init(userId: context.store.user.id, createdAt: .now, media: [])]
        context.store.ownPublicSnapshots.send((pois: [place], reels: [post]))
        let privatePost = makePost(ownerID: context.store.user.id, visibility: .privateOnly)
        context.store.archive.saveReel(privatePost, audience: .privateMyMap)

        // Deliberately no await: the first map frame must already have both
        // published kinds, not wait for loadProfile to return from the server.
        let model = MapTalkViewModel(environment: .connected(to: context.store),
                                     scope: .user(context.store.user))
        #expect(model.ratedPOIs.map(\.id) == [place.id])
        #expect(model.reals.map(\.id) == [post.id])
        #expect(Set(model.activeFeedItems.map(\.id)) == [place.id, post.id])
        #expect(!model.activeFeedItems.contains { $0.id == privatePost.id })
        let expected = try #require(UserMapViewModel.region(forCoordinates: [place.poi.coordinate, post.center]))
        #expect(model.region.center.latitude == expected.center.latitude)
        #expect(model.region.center.longitude == expected.center.longitude)
        #expect(model.region.span.latitudeDelta == expected.span.latitudeDelta)
    }

    @Test
    func anEmptyPublicProfileDoesNotBorrowPrivateArchiveContent() {
        let context = makeContext()
        defer { context.finish() }
        context.store.archive.saveReel(makePost(ownerID: context.store.user.id, visibility: .privateOnly),
                                       audience: .privateMyMap)
        let model = MapTalkViewModel(environment: .connected(to: context.store),
                                     scope: .user(context.store.user))
        #expect(model.reals.isEmpty)
        #expect(model.ratedPOIs.isEmpty)
        #expect(model.activeFeedItems.isEmpty)
    }

    @Test
    func anotherPersonsMapNeverStartsWithTheOwnersCachedProfile() {
        let context = makeContext()
        defer { context.finish() }
        context.store.ownPublicSnapshots.send((pois: [], reels: [
            makePost(ownerID: context.store.user.id, visibility: .publicAll)
        ]))
        let other = User(id: UUID(), handle: "another-person", avatarURL: nil)
        let model = MapTalkViewModel(environment: .connected(to: context.store), scope: .user(other))
        #expect(model.reals.isEmpty)
        #expect(model.activeFeedItems.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundProfileResponseUpdatesContentWithoutMovingTheSeededCamera() async throws {
        let owner = BackendUser(id: UUID(), handle: "profile-owner")
        let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let refreshed = BackendMemory(id: UUID(), ownerId: owner.id, owner: owner,
            kind: "reel", visibility: "public", location: .init(latitude: 21.3, longitude: -157.8),
            caption: "Newer server content", media: [], createdAt: date,
            publishedAt: date, expiresAt: date.addingTimeInterval(72 * 3_600))
        struct Identity: Encodable { let user: BackendUser }
        struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let identityData = try encoder.encode(Identity(user: owner))
        let pageData = try encoder.encode(Page(items: [refreshed]))
        ProfileMapStartupURLProtocol.install { request in
            request.respond(request.request.url?.path.hasSuffix("/memories") == true ? pageData : identityData)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileMapStartupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://profile-map-refresh-test.invalid")!, session: session)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-map-refresh-\(UUID())")
        let store = BackendStore(user: owner.user, api: api, storageDirectory: directory,
                                 automaticallySync: false, observesConnectivity: false)
        defer {
            store.clearLocalMedia()
            session.invalidateAndCancel()
            ProfileMapStartupURLProtocol.install(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        let cached = makePost(ownerID: owner.id, visibility: .publicAll)
        store.ownPublicSnapshots.send((pois: [], reels: [cached]))
        let model = MapTalkViewModel(environment: .connected(to: store), scope: .user(store.user))
        #expect(model.reals.map(\.id) == [cached.id])
        let explored = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.7, longitude: -74),
                                          span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
        model.region = explored
        for await posts in model.$reals.values {
            if posts.contains(where: { $0.id == refreshed.id }) { break }
        }
        #expect(model.region.center.latitude == explored.center.latitude)
        #expect(model.region.center.longitude == explored.center.longitude)
        #expect(model.region.span.latitudeDelta == explored.span.latitudeDelta)
        #expect(model.activeFeedReels.map(\.id) == [refreshed.id])
    }

    private func makePost(ownerID: UUID, visibility: RealPost.Visibility) -> RealPost {
        // Old published posts remain valid in the profile's mixed View Map flow.
        let date = Date.now.addingTimeInterval(-10 * 86_400)
        return RealPost(id: UUID(), userId: ownerID,
            center: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
            radiusMeters: 80, message: "A saved public post", attachments: [],
            likes: [], comments: [], visibility: visibility,
            createdAt: date, expiresAt: date.addingTimeInterval(72 * 3_600))
    }

    private func makeContext() -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-map-start-\(UUID())")
        let user = User(id: UUID(), handle: "profile-owner", avatarURL: nil)
        let api = BackendAPI(baseURL: URL(string: "https://profile-map-start-test.invalid")!)
        return Context(store: BackendStore(user: user, api: api, storageDirectory: directory,
                                           automaticallySync: false, observesConnectivity: false),
                       directory: directory)
    }

    private struct Context {
        let store: BackendStore
        let directory: URL

        @MainActor
        func finish() {
            // Synchronous tests finish before the scheduled refresh starts;
            // invalidation makes it exit without performing a network request.
            store.clearLocalMedia()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private final class ProfileMapStartupURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (ProfileMapStartupURLProtocol) -> Void)?

    static func install(_ value: (@Sendable (ProfileMapStartupURLProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}

    func respond(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

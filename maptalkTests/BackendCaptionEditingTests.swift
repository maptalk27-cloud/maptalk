import Foundation
import Combine
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendCaptionEditingTests {
    @Test
    func emptyCaptionsNeverSynthesizeMediaOrVisibilityText() {
        #expect(PostCaption.visibleText(nil) == nil)
        #expect(PostCaption.visibleText("") == nil)
        #expect(PostCaption.visibleText(" \n\t ") == nil)
        #expect(PostCaption.visibleText("  A day outside \n") == "A day outside")
        var post = PreviewData.sampleReals[0]
        post.message = nil
        let view = ExperienceDetailView(mode: .real(post, nil))
        #expect(view.highlightText(for: post, message: nil) == nil)
    }

    @Test
    func oneContributorPerPersonStartsWithLatestVisitAndKeepsItsMediaOrder() throws {
        let now = Date(timeIntervalSince1970: 1_792_670_400)
        let person = UUID()
        let friend = UUID()
        let oldMedia = RatedPOI.Media(kind: .photo(URL(fileURLWithPath: "/tmp/older.jpg")))
        let newestPhoto = RatedPOI.Media(kind: .photo(URL(fileURLWithPath: "/tmp/newest.jpg")))
        let newestVideo = RatedPOI.Media(kind: .video(url: URL(fileURLWithPath: "/tmp/newest.mp4"), poster: nil))
        var place = PreviewData.sampleRatedPOIs[0]
        // Capture time can be older when a saved visit is shared later.
        let latest = RatedPOI.CheckIn(userId: person, createdAt: now.addingTimeInterval(-86_400),
            media: [newestPhoto, newestVideo], publishedAt: now)
        place.checkIns = [
            .init(userId: person, createdAt: now.addingTimeInterval(-3_600), media: [oldMedia]),
            .init(userId: friend, createdAt: now.addingTimeInterval(-1_800), media: [oldMedia]), latest
        ]
        let contributors = ExperienceDetailView(mode: .poi(place)).poiStoryContributors(for: place)
        #expect(contributors.count == 2)
        let first = try #require(contributors.first)
        #expect(first.userId == person)
        #expect(first.items.map(\.id) == [newestPhoto.id, newestVideo.id, oldMedia.id])
        #expect(first.items.first?.timestamp == latest.activityDate)
        #expect(first.items.first?.readKey == StoryReadKeys.poiStoryPage(poiId: place.id,
            checkInId: latest.id, mediaId: newestPhoto.id, timestamp: latest.activityDate))
    }

    @Test
    func confirmedEditUpdatesExistingArchiveAndFeedWithoutRepublishing() async throws {
        let fixture = CaptionFixture()
        let (store, session, directory) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        let original = try #require(store.ownedMemories[fixture.record.id])
        let saved = try await store.updateCaption(memoryID: original.id, caption: "  New caption  ")
        #expect(saved.caption == "New caption")
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.publishedAt == original.publishedAt)
        #expect(saved.expiresAt == original.expiresAt)
        #expect(store.archive.privateReels.first?.message == "New caption")
        #expect(store.feedReels.value.first?.message == "New caption")
        #expect(store.ownPublicReels.first?.message == "New caption")
        #expect(store.pendingMemoryMutations.isEmpty)
        #expect(fixture.patchBody == ["caption": "New caption"])
        #expect(fixture.publishCount == 0)

        let restored = BackendStore(user: fixture.user.user, api: store.api, storageDirectory: directory,
                                    automaticallySync: false, observesConnectivity: false)
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privateReels.first?.message == "New caption")
        restored.clearLocalMedia()
    }

    @Test
    func unconfirmedOrOfflineEditsNeverPretendToSave() async throws {
        for behavior in [CaptionFixture.Behavior.ignoreEdit, .offline] {
            let fixture = CaptionFixture(behavior: behavior)
            let (store, session, _) = makeStore(fixture)
            try await store.refresh()
            do {
                _ = try await store.updateCaption(memoryID: fixture.record.id, caption: "Keep this draft")
                Issue.record("An unconfirmed edit must not report success")
            } catch {
                #expect(store.ownedMemories[fixture.record.id]?.caption == "Original caption")
                #expect(store.archive.privateReels.first?.message == "Original caption")
                #expect(store.feedReels.value.first?.message == "Original caption")
                #expect(store.pendingMemoryMutations.isEmpty)
            }
            finish(store, session)
        }
    }

    @Test
    func anotherPersonsPostCannotBeEdited() async throws {
        let fixture = CaptionFixture(otherOwner: true)
        let (store, session, _) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        do {
            _ = try await store.updateCaption(memoryID: fixture.record.id, caption: "Not mine")
            Issue.record("A different person's record must not be editable")
        } catch {
            #expect(fixture.patchBody == nil)
            #expect(store.pendingMemoryMutations.isEmpty)
        }
    }

    private func makeStore(_ fixture: CaptionFixture) -> (BackendStore, URLSession, URL) {
        CaptionURLProtocol.install { fixture.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://caption-edit-test.invalid")!, session: session)
        api.token = "caption-edit-session"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caption-edit-\(UUID())")
        return (BackendStore(user: fixture.user.user, api: api, storageDirectory: directory,
                             automaticallySync: false, observesConnectivity: false), session, directory)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        CaptionURLProtocol.install(nil)
    }
}

private final class CaptionFixture: @unchecked Sendable {
    enum Behavior { case save, ignoreEdit, offline }
    let user = BackendUser(id: UUID(), handle: "caption_owner")
    let record: BackendMemory
    private let lock = NSLock()
    private let behavior: Behavior
    private var current: BackendMemory
    private var body: [String: String]?
    private var posts = 0
    var patchBody: [String: String]? { lock.withLock { body } }
    var publishCount: Int { lock.withLock { posts } }

    init(behavior: Behavior = .save, otherOwner: Bool = false) {
        self.behavior = behavior
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let author = otherOwner ? BackendUser(id: UUID(), handle: "another_person") : user
        record = BackendMemory(id: UUID(), ownerId: author.id, owner: author, kind: "reel", visibility: "public",
            location: .init(latitude: 37.3, longitude: -122.0), caption: "Original caption", media: [],
            createdAt: date, publishedAt: date, expiresAt: date.addingTimeInterval(72 * 3600))
        current = record
    }

    func respond(to operation: CaptionURLProtocol) {
        do {
            let reply: (Int, Data) = try lock.withLock {
                let request = operation.request
                let method = request.httpMethod ?? "GET"
                let path = request.url!.path
                if method == "POST" { posts += 1 }
                if method == "PATCH" {
                    if behavior == .offline { throw URLError(.notConnectedToInternet) }
                    let data: Data
                    if let bytes = request.httpBody { data = bytes }
                    else if let stream = request.httpBodyStream {
                        stream.open()
                        defer { stream.close() }
                        var bytes = Data()
                        var buffer = [UInt8](repeating: 0, count: 1024)
                        while stream.hasBytesAvailable {
                            let count = stream.read(&buffer, maxLength: buffer.count)
                            if count <= 0 { break }
                            bytes.append(contentsOf: buffer.prefix(count))
                        }
                        data = bytes
                    } else { data = Data() }
                    body = try JSONDecoder().decode([String: String].self, from: data)
                    if behavior == .save {
                        current = BackendMemory(id: record.id, ownerId: record.ownerId, owner: record.owner,
                            kind: record.kind, visibility: record.visibility, location: record.location,
                            caption: body?["caption"] ?? "", media: record.media, createdAt: record.createdAt,
                            publishedAt: record.publishedAt, expiresAt: record.expiresAt)
                    }
                    return (200, try encode(current))
                }
                if path == "/v1/me" {
                    struct Identity: Encodable { let user: BackendUser }
                    return (200, try encode(Identity(user: user)))
                }
                struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                if path == "/v1/feed" { return (200, try encode(Page(items: [current]))) }
                if path == "/v1/me/memories" || path == "/v1/users/\(user.id.uuidString)/memories" {
                    return (200, try encode(Page(items: current.ownerId == user.id ? [current] : [])))
                }
                return (404, Data())
            }
            operation.respond(status: reply.0, data: reply.1)
        } catch { operation.client?.urlProtocol(operation, didFailWithError: error) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class CaptionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (CaptionURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (CaptionURLProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

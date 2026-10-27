import Combine
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendProgressiveLoadingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func mapAndProfileShowMetadataAndPhotosBeforeTheVideoFinishes(isProfile: Bool) async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        var snapshots: [BackendStore.Snapshot] = []
        let operation = Task {
            if isProfile {
                return try await context.store.loadProfile(userID: context.authorID) { snapshots.append($0) }
            }
            return try await context.store.loadMap(context.region) { snapshots.append($0) }
        }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        #expect(photo.request.url?.path == context.photoPath, "Small photos must not wait behind a full video")
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.reels.map(\.id) == [context.recordID])
        #expect(snapshots.first?.reels.first?.attachments.isEmpty == true)
        photo.respond(context.photo, contentType: "image/png")

        let video = try #require(await requests.next())
        #expect(video.request.url?.path == context.videoPath)
        #expect(video.request.value(forHTTPHeaderField: "Authorization") == "Bearer progressive-test-token")
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.reels.first?.attachments.map(\.id) == [context.photoID])
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        let final = try await operation.value
        // A video-first post retains its original media order when complete;
        // prioritizing the small download must not rewrite the person's Reel.
        #expect(final.reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(snapshots.last?.reels.first?.attachments.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledMapOrProfileCannotPublishLateVideoSnapshots(isProfile: Bool) async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        var updates = 0
        let operation = Task {
            if isProfile {
                return try await context.store.loadProfile(userID: context.authorID) { _ in updates += 1 }
            }
            return try await context.store.loadMap(context.region) { _ in updates += 1 }
        }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        let video = try #require(await requests.next())
        #expect(updates == 2)
        operation.cancel()
        video.respond(Data("cancelled transport".utf8), contentType: "video/mp4")
        do { _ = try await operation.value; Issue.record("Cancelled search must not return a stale result") }
        catch is CancellationError {}
        #expect(updates == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func withdrawalDuringDownloadCannotResurrectBlockedOrDeletedContent(deleteOwnPost: Bool) async throws {
        let context = try ProgressiveLoadingContext(ownPost: deleteOwnPost)
        defer { context.finish() }
        var updates = 0
        let operation = Task { try await context.store.loadMap(context.region) { _ in updates += 1 } }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        _ = try #require(await requests.next())
        #expect(updates == 2)
        if deleteOwnPost { try await context.store.deletePost(memoryID: context.recordID) }
        else { try await context.store.blockUser(id: context.authorID) }
        do { _ = try await operation.value; Issue.record("Withdrawal must invalidate the in-flight snapshot") }
        catch is CancellationError {}
        #expect(updates == 2)
        #expect(context.store.feedReels.value.isEmpty)
        #expect(!context.store.ownedMemories.keys.contains(context.recordID))
    }
}

@MainActor
private final class ProgressiveLoadingContext {
    let currentUserID = UUID()
    let authorID: UUID
    let recordID = UUID()
    let videoID = UUID()
    let photoID = UUID()
    let photo = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=")!
    let region = MKCoordinateRegion(center: .init(latitude: 37.3, longitude: -122),
                                   span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
    let mediaRequests: AsyncStream<ProgressiveMediaProtocol>
    private let continuation: AsyncStream<ProgressiveMediaProtocol>.Continuation
    private let session: URLSession
    let store: BackendStore
    var photoPath: String { "/v1/media/\(photoID.uuidString.lowercased())" }
    var videoPath: String { "/v1/media/\(videoID.uuidString.lowercased())" }

    init(ownPost: Bool = false) throws {
        authorID = ownPost ? currentUserID : UUID()
        (mediaRequests, continuation) = AsyncStream.makeStream()
        let mediaContinuation = continuation
        let author = authorID, current = currentUserID
        // This suite tests progressive loading, not expiry. A fixed calendar
        // date quietly made only its map variant stop returning the Reel once
        // that date crossed the active-feed window.
        let publicationDate = Date.now.addingTimeInterval(-60)
        let publishedAt = publicationDate.ISO8601Format()
        let expiresAt = publicationDate.addingTimeInterval(StoryReadKeys.freshWindow).ISO8601Format()
        let page = Data("""
        {"items":[{"id":"\(recordID)","ownerId":"\(author)",
        "owner":{"id":"\(author)","handle":"video_person"},"kind":"reel","visibility":"public",
        "location":{"latitude":37.3,"longitude":-122},"caption":"A slow video","place":null,
        "media":[{"id":"\(videoID)","mimeType":"video/mp4","byteCount":1024,"path":"/v1/media/\(videoID.uuidString.lowercased())"},
        {"id":"\(photoID)","mimeType":"image/png","byteCount":\(photo.count),"path":"/v1/media/\(photoID.uuidString.lowercased())"}],
        "createdAt":"\(publishedAt)","publishedAt":"\(publishedAt)","expiresAt":"\(expiresAt)"}],"nextCursor":null}
        """.utf8)
        ProgressiveMediaProtocol.install { operation in
            let path = operation.request.url?.path ?? ""
            let method = operation.request.httpMethod ?? "GET"
            if method == "GET", path.hasPrefix("/v1/media/") { mediaContinuation.yield(operation) }
            else if path == "/v1/me" {
                operation.respond(Data("{\"user\":{\"id\":\"\(current)\",\"handle\":\"viewer\"}}".utf8))
            } else if path == "/v1/users/\(author.uuidString)" {
                operation.respond(Data("{\"user\":{\"id\":\"\(author)\",\"handle\":\"video_person\"}}".utf8))
            } else if path == "/v1/map/memories" || (author != current && path == "/v1/users/\(author.uuidString)/memories") {
                operation.respond(page)
            } else if method == "POST" || method == "DELETE" { operation.respond(Data("{}".utf8)) }
            else { operation.respond(Data("{\"items\":[],\"nextCursor\":null}".utf8)) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveMediaProtocol.self]
        session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://progressive-test.invalid")!, session: session)
        api.token = "progressive-test-token"
        store = BackendStore(user: .init(id: current, handle: "viewer", avatarURL: nil), api: api, automaticallySync: false)
    }

    func finish() {
        store.clearLocalMedia()
        continuation.finish()
        session.invalidateAndCancel()
        ProgressiveMediaProtocol.install(nil)
    }
}

private final class ProgressiveMediaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (ProgressiveMediaProtocol) -> Void)?
    static func install(_ value: (@Sendable (ProgressiveMediaProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(_ data: Data, contentType: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

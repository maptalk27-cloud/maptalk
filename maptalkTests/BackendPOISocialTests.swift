import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendPOISocialTests {
    @Test(.timeLimit(.minutes(1)))
    func visitCountRerequestWinsAfterInvalidationEvenWhenOldResponseArrivesLast() async throws {
        let fixture = SocialTestContext()
        defer { fixture.finish() }
        let placeID = UUID()
        let ownerID = fixture.ownerID
        var requests = fixture.requests.makeAsyncIterator()
        #expect(fixture.store.visiblePOIVisitDayCount(placeID: placeID, authorID: ownerID) == nil)
        let earlier = Task {
            await fixture.store.ensurePOIVisitDayCounts(placeID: placeID, ownerIDs: [ownerID])
        }
        defer { earlier.cancel() }
        let oldRequest = try #require(await requests.next())
        let revision = fixture.store.poiVisitCountRevision
        // Blocking a different person invalidates the read generation, while
        // this still-allowed owner/place key must be free to request again.
        try await fixture.store.blockUser(id: fixture.peerID)
        #expect(fixture.store.poiVisitCountRevision > revision)
        #expect(fixture.store.visiblePOIVisitDayCount(placeID: placeID, authorID: ownerID) == nil)
        let latest = Task {
            await fixture.store.ensurePOIVisitDayCounts(placeID: placeID, ownerIDs: [ownerID])
        }
        defer { latest.cancel() }
        let newRequest = try #require(await requests.next())
        newRequest.respond("""
        {"items":[{"placeId":"\(placeID)","ownerId":"\(ownerID)","count":7}],"dayPolicy":"place-iana-v1"}
        """)
        await latest.value
        #expect(fixture.store.visiblePOIVisitDayCount(placeID: placeID, authorID: ownerID) == 7)
        oldRequest.respond("""
        {"items":[{"placeId":"\(placeID)","ownerId":"\(ownerID)","count":99}],"dayPolicy":"place-iana-v1"}
        """)
        await earlier.value
        #expect(fixture.store.visiblePOIVisitDayCount(placeID: placeID, authorID: ownerID) == 7)
    }

    @Test(.timeLimit(.minutes(1)))
    func blockedScopeDoesNotAcceptAnEarlierLikeAcknowledgement() async throws {
        let fixture = SocialTestContext()
        defer { fixture.finish() }
        let key = BackendMediaLikeKey(memoryID: UUID(), mediaID: UUID())
        var requests = fixture.requests.makeAsyncIterator()
        let write = Task { try await fixture.store.setMediaLiked(key, liked: true) }
        defer { write.cancel() }
        let pending = try #require(await requests.next())
        try await fixture.store.blockUser(id: fixture.peerID)
        pending.respond(#"{"liked":true,"count":1}"#)
        _ = try? await write.value
        #expect(fixture.store.mediaLikes[key] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func blockedRecipientDoesNotReceiveALateSendAcknowledgementInTheUI() async throws {
        let fixture = SocialTestContext()
        defer { fixture.finish() }
        let messageID = UUID()
        var requests = fixture.requests.makeAsyncIterator()
        let send = Task {
            try await fixture.store.sendDirectMessage(to: fixture.peerID, id: messageID,
                text: "Hello", context: nil)
        }
        defer { send.cancel() }
        let pending = try #require(await requests.next())
        try await fixture.store.blockUser(id: fixture.peerID)
        pending.respond("""
        {"id":"\(messageID)","senderId":"\(fixture.ownerID)","recipientId":"\(fixture.peerID)",
         "text":"Hello","createdAt":"2026-11-24T12:00:00Z","context":null}
        """)
        do {
            _ = try await send.value
            Issue.record("A pre-block send acknowledgement must not be returned to append to the open thread")
        } catch is CancellationError { }
        catch let error as BackendClientError {
            #expect(error.localizedDescription.contains("available"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func lateSavedListCannotUndoANewerConfirmedUnsave() async throws {
        let fixture = SocialTestContext()
        defer { fixture.finish() }
        let placeID = UUID()
        var requests = fixture.requests.makeAsyncIterator()
        let listing = Task { try await fixture.store.loadSavedPlaces() }
        defer { listing.cancel() }
        let listRequest = try #require(await requests.next())
        let removing = Task { try await fixture.store.setPlaceSaved(placeID, saved: false) }
        defer { removing.cancel() }
        let removeRequest = try #require(await requests.next())
        removeRequest.respond(#"{"saved":false}"#)
        try await removing.value
        listRequest.respond("""
        {"items":[{"place":{"id":"\(placeID)","sourceId":null,"name":"Old saved place",
        "category":"viewpoint","coordinate":{"latitude":47.6,"longitude":-122.3}},
        "savedAt":"2026-11-24T12:00:00Z"}],"nextCursor":null}
        """)
        try await listing.value
        #expect(fixture.store.savedPlaceStates[placeID] == false)
        #expect(!fixture.store.savedPlaces.contains { $0.id == placeID })
    }
}

@MainActor
private struct SocialTestContext {
    let ownerID = UUID()
    let peerID = UUID()
    let store: BackendStore
    let requests: AsyncStream<SocialTestProtocol>
    private let continuation: AsyncStream<SocialTestProtocol>.Continuation
    private let session: URLSession
    private let directory: URL

    init() {
        let (requests, continuation) = AsyncStream<SocialTestProtocol>.makeStream()
        self.requests = requests
        self.continuation = continuation
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("poi-social-\(UUID())")
        SocialTestProtocol.install { request in
            let path = request.request.url?.path ?? ""
            if path == "/v1/blocks" {
                request.respond("{}")
            } else if path.hasPrefix("/v1/messages") || path.hasSuffix("/like")
                        || path.hasSuffix("/saved") || path == "/v1/me/saved-places"
                        || path == "/v1/places/visit-counts" {
                continuation.yield(request)
            } else {
                // A block's best-effort map refresh is unrelated to these
                // controlled social responses and must never use the network.
                request.respond(#"{"error":{"message":"Fixture has no map data"}}"#, status: 503)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialTestProtocol.self]
        session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "http://127.0.0.1:8787")!, session: session)
        api.token = "isolated-social-fixture"
        store = BackendStore(user: .init(id: ownerID, handle: "social_test", avatarURL: nil),
            api: api, storageDirectory: directory, automaticallySync: false, observesConnectivity: false)
    }

    func finish() {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        continuation.finish()
        SocialTestProtocol.install(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SocialTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (SocialTestProtocol) -> Void)?
    static func install(_ value: (@Sendable (SocialTestProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() { }
    func respond(_ json: String, status: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                            headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

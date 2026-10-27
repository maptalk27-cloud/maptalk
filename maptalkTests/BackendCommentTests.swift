import Combine
import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendCommentTests {
    @Test
    func draftRetriesTheSameTextOnceAndPreservesUnsentEdits() throws {
        var draft = ExperienceCommentDraft()
        #expect(draft.submission() == nil)
        draft.text = "  Is this place open on Sunday?\n"
        let originalSubmission = draft.submission()
        let original = try #require(originalSubmission)
        #expect(original.text == "Is this place open on Sunday?")
        #expect(draft.submission() == original)
        draft.text = "Is this place open on Sunday?"
        #expect(draft.submission() == original)
        draft.text = "Is parking available?"
        let editedSubmission = draft.submission()
        let edited = try #require(editedSubmission)
        #expect(edited.id != original.id)
        draft.didSend(original)
        #expect(draft.text == edited.text)
        draft.didSend(edited)
        #expect(draft.text.isEmpty)
        draft.text = edited.text
        #expect(draft.submission()?.id != edited.id)
    }

    @Test
    func draftRejectsBlankOrOverlongTextWithoutSilentlyTruncatingIt() {
        var draft = ExperienceCommentDraft()
        draft.text = " \n\t "
        #expect(!draft.isValid)
        draft.text = String(repeating: "a", count: 1_000)
        #expect(draft.isValid)
        draft.text += "a"
        #expect(!draft.isValid)
        #expect(draft.submission() == nil)
        #expect(draft.text.count == 1_001)
        draft.text = String(repeating: "🙂", count: 501)
        #expect(!draft.isValid, "Client and server both count UTF-16 units")
    }

    @Test
    func onlyPublicPostModesProvideACommentTarget() {
        var reel = PreviewData.sampleReals[0]
        reel.visibility = .publicAll
        #expect(ExperienceDetailView.Mode.real(reel, nil).commentTarget == .memory(reel.id))
        reel.visibility = .privateOnly
        #expect(ExperienceDetailView.Mode.real(reel, nil).commentTarget == nil)
        let place = PreviewData.sampleRatedPOIs[0]
        #expect(ExperienceDetailView.Mode.poi(place).commentTarget == .place(place.id))
        #expect(ExperienceDetailView.Mode.journey(PreviewData.sampleJourneys[0]).commentTarget == nil)
    }

    @Test
    func textOnlyCommentAddsNoVisitAndNeverRevivesExpiredMapActivity() async throws {
        let fixture = CommentFixture(kind: "poi", age: 4 * 86_400)
        let (store, session) = try await makeStore(fixture)
        defer { finish(store, session) }
        let target = BackendCommentTarget.place(fixture.place.id)
        let original = try #require(store.ownedMemories[fixture.record.id])
        let visits = store.archive.privatePOIs.first?.checkIns.count
        var feedUpdates = 0
        let observation = store.feedPOIs.dropFirst().sink { _ in feedUpdates += 1 }
        defer { observation.cancel() }
        #expect(store.canComment(on: target), "Expired map activity still allows discussion")
        #expect(store.cachedCommentCount(for: target) == nil)
        let requestID = UUID()
        let saved = try await store.addComment(to: target, text: "  Is it busy here?  ", requestID: requestID)
        #expect(saved.id == requestID)
        #expect(store.comments(for: target).map(\.text) == ["Is it busy here?"])
        #expect(store.cachedCommentCount(for: target) == 1)
        #expect(fixture.lastPostKeys == Set(["id", "text"]))
        #expect(fixture.postedPaths == [target.path])
        #expect(store.archive.privatePOIs.first?.checkIns.count == visits)
        #expect(store.ownedMemories.count == 1)
        #expect(!store.hasPendingSyncWork)
        #expect(store.ownedMemories[original.id]?.createdAt == original.createdAt)
        #expect(store.ownedMemories[original.id]?.publishedAt == original.publishedAt)
        #expect(store.ownedMemories[original.id]?.expiresAt == original.expiresAt)
        #expect(feedUpdates == 0)
    }

    @Test
    func retryAfterLostResponseCreatesOnlyOneComment() async throws {
        let fixture = CommentFixture()
        fixture.loseFirstPostResponse = true
        let (store, session) = try await makeStore(fixture)
        defer { finish(store, session) }
        let target = BackendCommentTarget.memory(fixture.record.id)
        let id = UUID()
        do {
            try await store.addComment(to: target, text: "Looks lovely", requestID: id)
            Issue.record("The lost response must not pretend to confirm Send")
        } catch {
            #expect(store.comments(for: target).isEmpty)
        }
        try await store.addComment(to: target, text: "Looks lovely", requestID: id)
        #expect(fixture.savedComments.count == 1)
        #expect(fixture.postedIDs == [id, id])
        #expect(store.comments(for: target).count == 1)
        try await store.loadComments(for: target)
        #expect(store.comments(for: target).count == 1)
    }

    @Test
    func privateAndPendingPostsNeverOfferOrSendComments() async throws {
        for fixture in [CommentFixture(visibility: "private"), CommentFixture(status: "local_pending")] {
            let (store, session) = try await makeStore(fixture)
            let target = BackendCommentTarget.memory(fixture.record.id)
            #expect(!store.canComment(on: target))
            do {
                try await store.addComment(to: target, text: "Not yet public", requestID: UUID())
                Issue.record("Private or pending posts cannot accept a public discussion")
            } catch { #expect(fixture.postedPaths.isEmpty) }
            finish(store, session)
        }
    }

    @Test
    func loadedCommentsRemainReadableOnNetworkFailureAndAreClearedOnSignOut() async throws {
        let fixture = CommentFixture()
        let (store, session) = try await makeStore(fixture)
        defer { finish(store, session) }
        let target = BackendCommentTarget.memory(fixture.record.id)
        try await store.addComment(to: target, text: "A text-only discussion", requestID: UUID())
        fixture.failReads = true
        do { try await store.loadComments(for: target); Issue.record("Expected offline load failure") }
        catch { #expect(store.comments(for: target).count == 1) }
        store.clearLocalMedia()
        #expect(store.comments(for: target).isEmpty)
        #expect(!store.canComment(on: target))
    }

    @Test
    func invalidTextIsRejectedBeforeAnyNetworkMutation() async throws {
        let fixture = CommentFixture()
        let (store, session) = try await makeStore(fixture)
        defer { finish(store, session) }
        let target = BackendCommentTarget.memory(fixture.record.id)
        for text in [" \n ", String(repeating: "x", count: 1_001)] {
            do {
                try await store.addComment(to: target, text: text, requestID: UUID())
                Issue.record("Invalid comments must not be sent")
            } catch { #expect(fixture.postedPaths.isEmpty) }
        }
    }

    @Test
    func lateReadCannotEraseACommentSentWhileItWasInFlight() async throws {
        for denied in [false, true] {
            let fixture = CommentFixture()
            let (store, session) = try await makeStore(fixture)
            let target = BackendCommentTarget.memory(fixture.record.id)
            try await store.addComment(to: target, text: "First comment", requestID: UUID())
            fixture.holdCommentReads = true
            fixture.refuseCommentReads = denied
            let read = Task { try await store.loadComments(for: target) }
            for _ in 0..<100 where !fixture.hasHeldRead {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(fixture.hasHeldRead)
            try await store.addComment(to: target, text: "Sent during the read", requestID: UUID())
            fixture.releaseCommentReads()
            do {
                try await read.value
                #expect(!denied)
            } catch { #expect(denied) }
            #expect(Set(store.comments(for: target).map(\.text)) == ["First comment", "Sent during the read"])
            finish(store, session)
        }
    }

    private func makeStore(_ fixture: CommentFixture) async throws -> (BackendStore, URLSession) {
        CommentURLProtocol.install { fixture.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://comment-test.invalid")!, session: session)
        api.token = "comment-test-session"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("comment-test-\(UUID())")
        let store = BackendStore(user: fixture.user.user, api: api, storageDirectory: directory,
                                 automaticallySync: false, observesConnectivity: false)
        try await store.refresh()
        return (store, session)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        CommentURLProtocol.install(nil)
    }
}

private final class CommentFixture: @unchecked Sendable {
    let user = BackendUser(id: UUID(), handle: "commenter")
    let place = BackendPlace(id: UUID(), sourceId: nil, name: "A place", category: "park",
                             coordinate: .init(latitude: 37.3, longitude: -122.0))
    let record: BackendMemory
    private let lock = NSLock()
    private var comments: [UUID: BackendComment] = [:]
    private var paths: [String] = []
    private var ids: [UUID] = []
    private var keys: Set<String> = []
    private var postResponseLost = false
    private var heldReads: [(CommentURLProtocol, Int, Data)] = []
    var loseFirstPostResponse = false
    var failReads = false
    var holdCommentReads = false
    var refuseCommentReads = false
    var hasHeldRead: Bool { lock.withLock { !heldReads.isEmpty } }
    var savedComments: [BackendComment] { lock.withLock { Array(comments.values) } }
    var postedPaths: [String] { lock.withLock { paths } }
    var postedIDs: [UUID] { lock.withLock { ids } }
    var lastPostKeys: Set<String> { lock.withLock { keys } }

    func releaseCommentReads() {
        let reads = lock.withLock {
            let result = heldReads
            heldReads.removeAll()
            return result
        }
        for (operation, status, data) in reads { operation.respond(status: status, data: data) }
    }

    init(kind: String = "reel", visibility: String = "public", status: String = "approved", age: TimeInterval = 0) {
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - age))
        record = BackendMemory(id: UUID(), ownerId: user.id, owner: user, kind: kind, visibility: visibility,
            location: .init(latitude: 37.3, longitude: -122.0), caption: "A post", place: kind == "poi" ? place : nil,
            media: [], createdAt: date, publishedAt: date, expiresAt: date.addingTimeInterval(72 * 3_600),
            moderationStatus: status)
    }

    func respond(to operation: CommentURLProtocol) {
        do {
            let response: (Int, Data) = try lock.withLock {
                let request = operation.request
                let path = request.url!.path
                if path.hasSuffix("/comments") {
                    if request.httpMethod == "POST" {
                        let body = try JSONDecoder().decode([String: String].self, from: body(of: request))
                        keys = Set(body.keys)
                        let id = UUID(uuidString: body["id"]!)!
                        paths.append(path); ids.append(id)
                        let saved = comments[id] ?? BackendComment(id: id, userId: user.id, text: body["text"]!,
                                                                   createdAt: Date(), author: user)
                        comments[id] = saved
                        if loseFirstPostResponse && !postResponseLost {
                            postResponseLost = true
                            throw URLError(.networkConnectionLost)
                        }
                        return (201, try encode(saved))
                    }
                    if failReads { throw URLError(.notConnectedToInternet) }
                    if refuseCommentReads {
                        return (403, Data("{\"error\":{\"code\":\"forbidden\",\"message\":\"Not available\"}}".utf8))
                    }
                    struct Page: Encodable { let items: [BackendComment]; let nextCursor: String? = nil }
                    return (200, try encode(Page(items: Array(comments.values))))
                }
                if path == "/v1/me" {
                    struct Identity: Encodable { let user: BackendUser }
                    return (200, try encode(Identity(user: user)))
                }
                if path == "/v1/feed" || path == "/v1/me/memories" || path.hasSuffix("/memories") {
                    struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                    return (200, try encode(Page(items: [record])))
                }
                return (404, Data())
            }
            if operation.request.url!.path.hasSuffix("/comments"), operation.request.httpMethod != "POST",
               lock.withLock({
                   guard holdCommentReads else { return false }
                   heldReads.append((operation, response.0, response.1))
                   return true
               }) {
                return
            }
            operation.respond(status: response.0, data: response.1)
        } catch { operation.client?.urlProtocol(operation, didFailWithError: error) }
    }

    private func body(of request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class CommentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (CommentURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (CommentURLProtocol) -> Void)?) { lock.withLock { handler = value } }
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

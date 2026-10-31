import CoreLocation
import Combine
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendPublishRetryTests {
    private let originalLocation = CLLocation(latitude: 37.3688, longitude: -122.0363)

    @Test(arguments: [422, 401, 403])
    func definitiveRejectionAllowsCorrectedDraftWithSameRequestID(status: Int) async throws {
        let fixture = PublishRetryFixture(outcomes: [.http(status), .success])
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let id = UUID()
        do {
            _ = try await store.publish(draft("Original caption"), audience: .livePublic,
                                        location: originalLocation, requestID: id)
            Issue.record("The first request should be rejected")
        } catch let error as BackendClientError {
            #expect(error.confirmsPublishRejection)
            if status != 401 {
                guard case let .http(actualStatus, _, _) = error else {
                    Issue.record("HTTP refusals must retain their status")
                    return
                }
                #expect(actualStatus == status)
            }
        }
        let result = try await store.publish(draft("Corrected caption"), audience: .livePublic,
                                             location: originalLocation, requestID: id)
        guard case let .reel(reel) = result else {
            Issue.record("Expected a saved Reel")
            return
        }
        #expect(reel.message == "Corrected caption")
        #expect(fixture.inputs.map(\.id) == [id, id])
        #expect(fixture.inputs.map(\.caption) == ["Original caption", "Corrected caption"])
    }

    @Test(arguments: [408, 409, 503])
    func uncertainHTTPResponseProtectsDraftAndReusesExactInput(status: Int) async throws {
        try await verifyUncertainRetry(firstOutcome: .http(status))
    }

    @Test
    func interruptedResponseProtectsDraftAndReusesExactInput() async throws {
        try await verifyUncertainRetry(firstOutcome: .networkFailure)
    }

    @Test
    func definitiveRefusalAfterNetworkFailureUnlocksCorrection() async throws {
        let fixture = PublishRetryFixture(outcomes: [.networkFailure, .http(422), .success])
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let id = UUID()
        do {
            _ = try await store.publish(draft("Invalid caption"), audience: .privateMyMap,
                                        location: originalLocation, requestID: id)
            Issue.record("Expected an uncertain save")
        } catch let error as BackendClientError {
            guard case .publishPending = error else {
                Issue.record("A network failure must keep the pending save")
                return
            }
        }
        do {
            _ = try await store.publish(draft("Invalid caption"), audience: .privateMyMap,
                                        location: originalLocation, requestID: id)
            Issue.record("Expected explicit refusal")
        } catch let error as BackendClientError {
            #expect(error.confirmsPublishRejection)
        }
        _ = try await store.publish(draft("Corrected caption"), audience: .privateMyMap,
                                    location: originalLocation, requestID: id)
        #expect(fixture.inputs.map(\.caption) == ["Invalid caption", "Invalid caption", "Corrected caption"])
    }

    @Test(.timeLimit(.minutes(1)))
    func confirmedSaveReturnsWithoutWaitingForRefresh() async throws {
        // All GET requests intentionally remain unanswered. A confirmed POST
        // must close the composer without waiting for these background reads.
        let fixture = PublishRetryFixture(outcomes: [.success])
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let id = UUID()
        let result = try await store.publish(draft("Saved immediately"), audience: .livePublic,
                                             location: originalLocation, requestID: id)
        guard case let .reel(reel) = result else {
            Issue.record("Expected the confirmed Reel")
            return
        }
        #expect(reel.id == id)
        #expect(store.archive.privateReels.contains { $0.id == id })
        #expect(store.ownPublicReels.contains { $0.id == id })
        #expect(store.feedReels.value.contains { $0.id == id })
    }

    @Test
    func pendingPublicPublishStaysInMyMapWithoutBrieflyAppearingInFeed() async throws {
        let fixture = PublishRetryFixture(outcomes: [.success], moderationStatus: "pending")
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let id = UUID()
        _ = try await store.publish(draft("Awaiting review"), audience: .livePublic,
            location: originalLocation, requestID: id)
        #expect(store.archive.privateReels.map(\.id) == [id])
        #expect(store.ownPublicReels.isEmpty)
        #expect(store.feedReels.value.isEmpty)
        #expect(store.archive.publicReelOverlays.isEmpty)
        #expect(store.manageableMemories(for: .reel(id)).first?.moderationStatus == "pending")
    }

    private func verifyUncertainRetry(firstOutcome: PublishRetryFixture.Outcome) async throws {
        let fixture = PublishRetryFixture(outcomes: [firstOutcome, .success])
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let id = UUID()
        do {
            _ = try await store.publish(draft("Keep this caption"), audience: .livePublic,
                                        location: originalLocation, requestID: id)
            Issue.record("Expected an uncertain save")
        } catch let error as BackendClientError {
            guard case .publishPending = error else {
                Issue.record("An uncertain result must lock the draft")
                return
            }
        }
        do {
            _ = try await store.publish(draft("Changed caption"), audience: .livePublic,
                                        location: originalLocation, requestID: id)
            Issue.record("An unresolved save must not accept a changed draft")
        } catch let error as BackendClientError {
            guard case .publishPending = error else {
                Issue.record("The unresolved save must remain protected")
                return
            }
        }
        #expect(fixture.inputs.count == 1)
        _ = try await store.publish(draft("Keep this caption"), audience: .livePublic,
                                    location: CLLocation(latitude: 47.6062, longitude: -122.3321),
                                    requestID: id)
        let sent = fixture.inputs
        #expect(sent.count == 2)
        #expect(sent.map(\.id) == [id, id])
        #expect(sent.map(\.caption) == ["Keep this caption", "Keep this caption"])
        #expect(sent.first?.capturedAt != nil)
        #expect(sent.first?.capturedAt == sent.last?.capturedAt)
        #expect(sent.last?.location.latitude == originalLocation.coordinate.latitude)
        #expect(sent.last?.location.longitude == originalLocation.coordinate.longitude)
    }

    private func draft(_ text: String) -> MapTalkPublishDraft {
        .reel(.init(text: text, attachments: [], bubbleSource: nil))
    }

    private func makeStore(_ fixture: PublishRetryFixture) -> (BackendStore, URLSession) {
        PublishRetryURLProtocol.install { fixture.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublishRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(session: session)
        api.token = "test-session"
        return (BackendStore(user: .init(id: fixture.userID, handle: "retry_test", avatarURL: nil), api: api), session)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        PublishRetryURLProtocol.install(nil)
    }
}

private struct PublishRetryInput: Decodable {
    struct Coordinate: Decodable {
        let latitude: Double
        let longitude: Double
    }
    let id: UUID
    let visibility: String
    let caption: String?
    let location: Coordinate
    let capturedAt: String?
}

private final class PublishRetryFixture: @unchecked Sendable {
    enum Outcome { case http(Int), networkFailure, success }
    let userID = UUID()
    private let lock = NSLock()
    private var remaining: [Outcome]
    private var sent: [PublishRetryInput] = []
    private let moderationStatus: String?
    var inputs: [PublishRetryInput] { lock.withLock { sent } }

    init(outcomes: [Outcome], moderationStatus: String? = nil) {
        remaining = outcomes
        self.moderationStatus = moderationStatus
    }

    func handle(_ operation: PublishRetryURLProtocol) {
        // Hold background refreshes open until the test cancels the session.
        guard operation.request.httpMethod == "POST" else { return }
        do {
            let input = try JSONDecoder().decode(PublishRetryInput.self, from: body(of: operation.request))
            let outcome = lock.withLock {
                sent.append(input)
                return remaining.isEmpty ? Outcome.http(500) : remaining.removeFirst()
            }
            switch outcome {
            case let .http(status):
                operation.respond(status: status, data: Data("{\"error\":{\"message\":\"Test refusal\"}}".utf8))
            case .networkFailure:
                operation.fail(URLError(.networkConnectionLost))
            case .success:
                let output: [String: Any] = [
                    "id": input.id.uuidString,
                    "ownerId": userID.uuidString,
                    "owner": ["id": userID.uuidString, "handle": "retry_test"],
                    "kind": "reel", "visibility": input.visibility,
                    "location": ["latitude": input.location.latitude, "longitude": input.location.longitude],
                    "caption": input.caption ?? "", "place": NSNull(), "media": [],
                    "createdAt": "2026-10-17T12:00:00Z",
                    "publishedAt": input.visibility == "public" ? "2026-10-17T12:00:00Z" as Any : NSNull(),
                    "expiresAt": "2026-10-18T12:00:00Z",
                    "moderationStatus": moderationStatus.map { $0 as Any } ?? NSNull()
                ]
                operation.respond(status: 201, data: try JSONSerialization.data(withJSONObject: output))
            }
        } catch {
            operation.fail(error)
        }
    }

    private func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}

private final class PublishRetryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (PublishRetryURLProtocol) -> Void)?

    static func install(_ value: (@Sendable (PublishRetryURLProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}

    func respond(status: Int, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}

@MainActor
@Suite(.serialized)
struct BackendPostWithdrawalTests {
    @Test
    func makePrivateWithdrawsFromFeedMapAndProfileButKeepsMyMap() async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        var withdrawn = Set<UUID>()
        let subscription = store.publicContentChanges.sink { withdrawn.formUnion($0) }
        defer { subscription.cancel() }

        try await store.makePrivate(memoryID: fixture.reelID)

        #expect(store.archive.privateReels.first?.visibility == .privateOnly)
        #expect(store.ownPublicReels.isEmpty)
        #expect(store.feedReels.value.isEmpty)
        #expect(withdrawn == [fixture.reelID])
        #expect(fixture.record(fixture.reelID)?.visibility == "private")
        let map = try await store.loadMap(.init(center: .init(latitude: 37.3, longitude: -122),
            span: .init(latitudeDelta: 1, longitudeDelta: 1)))
        #expect(map.reels.isEmpty)
        #expect(store.manageableMemories(for: .reel(fixture.reelID)).first?.visibility == "private")
    }

    @Test
    func deletingOneVisitPreservesOtherVisitsAtTheSharedPlace() async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        #expect(Set(store.manageableMemories(for: .poi(fixture.placeID)).map(\.id)) == [fixture.visitID, fixture.secondVisitID])

        try await store.deletePost(memoryID: fixture.visitID)

        #expect(fixture.record(fixture.visitID) == nil)
        #expect(fixture.record(fixture.secondVisitID) != nil)
        #expect(fixture.record(fixture.otherVisitID) != nil)
        #expect(store.archive.privatePOIs.first?.checkIns.map(\.id) == [fixture.secondVisitID])
        #expect(Set(store.feedPOIs.value.first?.checkIns.map(\.id) ?? []) == [fixture.secondVisitID, fixture.otherVisitID])
        #expect(fixture.mutations == ["DELETE /v1/memories/\(fixture.visitID.uuidString)"])
    }

    @Test(arguments: [403, 500])
    func failedWithdrawalDoesNotPretendThePostIsPrivate(status: Int) async throws {
        let fixture = WithdrawalFixture(mutationStatus: status)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        do {
            try await store.makePrivate(memoryID: fixture.reelID)
            Issue.record("A refused mutation must fail")
        } catch { }
        #expect(fixture.record(fixture.reelID)?.visibility == "public")
        #expect(store.ownPublicReels.map(\.id) == [fixture.reelID])
        #expect(store.feedReels.value.map(\.id) == [fixture.reelID])
        #expect(store.pendingMemoryMutations.isEmpty)
    }

    @Test
    func anotherPersonsCheckInCannotBeMutatedThroughTheStore() async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        do {
            try await store.deletePost(memoryID: fixture.otherVisitID)
            Issue.record("The client must refuse another person's check-in")
        } catch { }
        #expect(fixture.mutations.isEmpty)
        #expect(fixture.record(fixture.otherVisitID) != nil)
    }

    @Test
    func confirmedDeletePurgesPhotoCacheAndCollectionReference() async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        let photoURL = backendMediaCacheDirectory(userID: fixture.ownerID, baseURL: store.api.baseURL)
            .appendingPathComponent("\(fixture.mediaID.uuidString).image")
        #expect(FileManager.default.fileExists(atPath: photoURL.path))
        let folder = store.archive.createJourneyFolder(title: "Test", memberReferences: [.reel(fixture.reelID)])
        defer { store.archive.deleteJourneyFolder(id: folder.id) }

        try await store.deletePost(memoryID: fixture.reelID)

        #expect(!FileManager.default.fileExists(atPath: photoURL.path))
        #expect(store.archive.privateReels.isEmpty)
        #expect(store.ownPublicReels.isEmpty)
        #expect(store.archive.journeyFolders.first?.memberReferences.isEmpty == true)
        #expect(store.manageableMemories(for: .reel(fixture.reelID)).isEmpty)
    }

    @Test
    func refreshFailureAfterConfirmedWithdrawalCannotRestorePublicPost() async throws {
        let fixture = WithdrawalFixture(failRefreshAfterMutation: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        try await store.makePrivate(memoryID: fixture.reelID)
        #expect(store.ownPublicReels.isEmpty)
        #expect(store.feedReels.value.isEmpty)
        #expect(store.archive.privateReels.first?.visibility == .privateOnly)
        #expect(store.issue?.contains("Your post was updated") == true)
    }

    @Test
    func blockPrunesOnlyOtherOwnerAndRejectsStaleRefreshResults() async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        let root = backendMediaCacheDirectory(userID: fixture.ownerID, baseURL: store.api.baseURL)
        let otherPhoto = root.appendingPathComponent("\(fixture.otherMediaID.uuidString).image")
        #expect(FileManager.default.fileExists(atPath: otherPhoto.path))
        try await store.blockUser(id: fixture.otherID)
        // The fixture deliberately keeps returning the old public record.
        #expect(!store.feedPOIs.value.flatMap(\.checkIns).contains { $0.userId == fixture.otherID })
        #expect(store.ownPublicReels.map(\.id) == [fixture.reelID])
        #expect(store.archive.privatePOIs.first?.checkIns.count == 2)
        #expect(!FileManager.default.fileExists(atPath: otherPhoto.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(fixture.mediaID.uuidString).image").path))
        #expect(store.isActive)
    }

    @Test(arguments: ["private", "delete", "block"])
    func delayedMapResponseCannotRestoreWithdrawnContent(action: String) async throws {
        let fixture = WithdrawalFixture()
        let (store, session) = makeStore(fixture)
        let (responses, continuation) = AsyncStream<(WithdrawalURLProtocol, Data)>.makeStream()
        defer { continuation.finish(); finish(store, session) }
        try await store.refresh()
        fixture.pauseNextMapResponse { request, data in continuation.yield((request, data)) }
        let oldRead = Task {
            try await store.loadMap(.init(center: .init(latitude: 37.3, longitude: -122),
                span: .init(latitudeDelta: 1, longitudeDelta: 1)))
        }
        var iterator = responses.makeAsyncIterator()
        let delayed = try #require(await iterator.next())
        switch action {
        case "private": try await store.makePrivate(memoryID: fixture.reelID)
        case "delete": try await store.deletePost(memoryID: fixture.reelID)
        default: try await store.blockUser(id: fixture.otherID)
        }
        // Complete the GET with its pre-mutation public snapshot only after
        // the mutation and all fresh reads have already succeeded.
        delayed.0.respond(status: 200, data: delayed.1)
        let staleMap = try await oldRead.value
        if action == "block" {
            #expect(!staleMap.pois.flatMap(\.checkIns).contains { $0.userId == fixture.otherID })
        } else {
            #expect(staleMap.reels.isEmpty)
            #expect(store.feedReels.value.isEmpty)
            #expect(store.ownPublicReels.isEmpty)
        }
        if action != "private" {
            let mediaID = action == "block" ? fixture.otherMediaID : fixture.mediaID
            let cached = backendMediaCacheDirectory(userID: fixture.ownerID, baseURL: store.api.baseURL)
                .appendingPathComponent("\(mediaID.uuidString).image")
            #expect(!FileManager.default.fileExists(atPath: cached.path))
        }
    }

    private func makeStore(_ fixture: WithdrawalFixture) -> (BackendStore, URLSession) {
        WithdrawalURLProtocol.install { fixture.respond(to: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WithdrawalURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = BackendAPI(session: session)
        api.token = "test-session"
        return (BackendStore(user: .init(id: fixture.ownerID, handle: "owner", avatarURL: nil), api: api), session)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        WithdrawalURLProtocol.install(nil)
    }
}

private final class WithdrawalFixture: @unchecked Sendable {
    let ownerID = UUID()
    let otherID = UUID()
    let reelID = UUID()
    let visitID = UUID()
    let secondVisitID = UUID()
    let otherVisitID = UUID()
    let placeID = UUID()
    let mediaID = UUID()
    let otherMediaID = UUID()
    private let lock = NSLock()
    private var records: [UUID: BackendMemory] = [:]
    private var sentMutations: [String] = []
    private var pausedMapHandler: (@Sendable (WithdrawalURLProtocol, Data) -> Void)?
    private let mutationStatus: Int?
    private let failRefreshAfterMutation: Bool
    private let photo = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=")!
    var mutations: [String] { lock.withLock { sentMutations } }
    func record(_ id: UUID) -> BackendMemory? { lock.withLock { records[id] } }
    func pauseNextMapResponse(_ handler: @escaping @Sendable (WithdrawalURLProtocol, Data) -> Void) {
        lock.withLock { pausedMapHandler = handler }
    }

    init(mutationStatus: Int? = nil, failRefreshAfterMutation: Bool = false) {
        self.mutationStatus = mutationStatus
        self.failRefreshAfterMutation = failRefreshAfterMutation
        let coordinate = BackendCoordinate(latitude: 37.3, longitude: -122)
        let place = BackendPlace(id: placeID, sourceId: nil, name: "Shared café", category: "coffee", coordinate: coordinate)
        for (id, owner, kind) in [(reelID, ownerID, "reel"), (visitID, ownerID, "poi"),
                                   (secondVisitID, ownerID, "poi"), (otherVisitID, otherID, "poi")] {
            records[id] = BackendMemory(id: id, ownerId: owner, owner: .init(id: owner, handle: owner == ownerID ? "owner" : "other"),
                kind: kind, visibility: "public", location: coordinate, caption: kind == "reel" ? "A photo" : "",
                place: kind == "poi" ? place : nil,
                media: kind == "reel" || owner == otherID ? [.init(id: owner == otherID ? otherMediaID : mediaID,
                    mimeType: "image/png", byteCount: photo.count,
                    path: "/v1/media/\((owner == otherID ? otherMediaID : mediaID).uuidString.lowercased())")] : [],
                createdAt: .now, publishedAt: .now, expiresAt: .now.addingTimeInterval(86_400))
        }
    }

    func respond(to operation: WithdrawalURLProtocol) {
        let path = operation.request.url!.path
        let method = operation.request.httpMethod ?? "GET"
        do {
            let reply: (Int, Data) = try lock.withLock {
                if method == "POST", path == "/v1/blocks" { return (204, Data()) }
                if ["PATCH", "DELETE"].contains(method) {
                    sentMutations.append("\(method) \(path)")
                    if let mutationStatus { return (mutationStatus, Data("{\"error\":{\"message\":\"Not changed\"}}".utf8)) }
                    guard let id = UUID(uuidString: operation.request.url!.lastPathComponent), let current = records[id], current.ownerId == ownerID else {
                        return (404, Data("{\"error\":{\"message\":\"Not found\"}}".utf8))
                    }
                    if method == "DELETE" { records.removeValue(forKey: id); return (204, Data()) }
                    let privateRecord = BackendMemory(id: current.id, ownerId: current.ownerId, owner: current.owner,
                        kind: current.kind, visibility: "private", location: current.location, caption: current.caption,
                        place: current.place, media: current.media, createdAt: current.createdAt,
                        publishedAt: current.publishedAt, expiresAt: current.expiresAt, moderationStatus: current.moderationStatus)
                    records[id] = privateRecord
                    return (200, try encode(privateRecord))
                }
                if failRefreshAfterMutation, !sentMutations.isEmpty {
                    return (503, Data("{\"error\":{\"message\":\"Refresh unavailable\"}}".utf8))
                }
                if path.hasPrefix("/v1/media/") { return (200, photo) }
                if path == "/v1/me" {
                    struct Identity: Encodable { let user: BackendUser }
                    return (200, try encode(Identity(user: .init(id: ownerID, handle: "owner"))))
                }
                let values = Array(records.values).filter { record in
                    if path == "/v1/me/memories" { return record.ownerId == ownerID }
                    if path.hasPrefix("/v1/users/") { return record.ownerId == ownerID && record.visibility == "public" }
                    return record.visibility == "public"
                }
                struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                return (200, try encode(Page(items: values)))
            }
            let delayed: (@Sendable (WithdrawalURLProtocol, Data) -> Void)? = lock.withLock {
                guard method == "GET", path == "/v1/map/memories" else { return nil }
                defer { pausedMapHandler = nil }
                return pausedMapHandler
            }
            if let delayed { delayed(operation, reply.1) }
            else { operation.respond(status: reply.0, data: reply.1) }
        } catch { operation.client?.urlProtocol(operation, didFailWithError: error) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class WithdrawalURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (WithdrawalURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (WithdrawalURLProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": request.url!.path.hasPrefix("/v1/media/") ? "image/png" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

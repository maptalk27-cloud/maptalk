import Combine
import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendBatchDeletionTests {
    @Test(.timeLimit(.minutes(1)))
    func groupedDeletionRemovesEachOwnVisitBeforeOneFinalRefresh() async throws {
        let fixture = BatchDeletionFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        fixture.clearRequests()

        var feedSnapshots: [Set<UUID>] = []
        let subscription = store.feedPOIs.sink { places in
            feedSnapshots.append(Set(places.flatMap(\.checkIns).map(\.id)))
        }
        defer { subscription.cancel() }

        try await store.deletePosts(memoryIDs: fixture.ownVisitIDs)

        assertOneRefreshAfterDeletes(fixture)
        #expect(feedSnapshots.contains([fixture.secondVisitID, fixture.otherVisitID]),
                "The first confirmed deletion must immediately prune feed while the next visit remains")
        #expect(store.archive.privatePOIs.isEmpty)
        #expect(store.ownPublicPOIs.isEmpty)
        #expect(Set(store.feedPOIs.value.flatMap(\.checkIns).map(\.id)) == [fixture.otherVisitID])
        #expect(store.manageableMemories(for: .poi(fixture.placeID)).isEmpty)
        #expect(fixture.remainingIDs == [fixture.otherVisitID])
        #expect(!fixture.requests.contains("DELETE /v1/memories/\(fixture.otherVisitID.uuidString)"))
        #expect(store.pendingMemoryMutations.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func laterDeleteFailureStillRefreshesOnceWithoutRestoringEarlierSuccess() async throws {
        // A stale final GET deliberately includes the already-deleted visit.
        // Its local tombstone must still win even when the batch later fails.
        let fixture = BatchDeletionFixture(failSecondDelete: true, returnStaleReads: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        fixture.clearRequests()

        do {
            try await store.deletePosts(memoryIDs: fixture.ownVisitIDs)
            Issue.record("A refused second deletion must not be reported as a complete batch")
        } catch let error as BackendClientError {
            guard case let .http(status, _, code) = error else {
                Issue.record("Expected the second DELETE's server error, not a refresh error")
                return
            }
            #expect(status == 503)
            #expect(code == "delete_temporarily_unavailable")
        }

        assertOneRefreshAfterDeletes(fixture)
        #expect(fixture.remainingIDs == [fixture.secondVisitID, fixture.otherVisitID])
        #expect(Set(store.archive.privatePOIs.flatMap(\.checkIns).map(\.id)) == [fixture.secondVisitID])
        #expect(Set(store.ownPublicPOIs.flatMap(\.checkIns).map(\.id)) == [fixture.secondVisitID])
        #expect(Set(store.feedPOIs.value.flatMap(\.checkIns).map(\.id)) == [fixture.secondVisitID, fixture.otherVisitID])
        #expect(Set(store.manageableMemories(for: .poi(fixture.placeID)).map(\.id)) == [fixture.secondVisitID])
        #expect(store.pendingMemoryMutations.isEmpty)

        // A later stale refresh must not resurrect the successful deletion,
        // either; the failed visit remains available to retry independently.
        try await store.refresh()
        #expect(!store.feedPOIs.value.flatMap(\.checkIns).contains { $0.id == fixture.firstVisitID })
        #expect(!store.archive.privatePOIs.flatMap(\.checkIns).contains { $0.id == fixture.firstVisitID })
    }

    private func assertOneRefreshAfterDeletes(_ fixture: BatchDeletionFixture) {
        let requests = fixture.requests
        let deletes = fixture.ownVisitIDs.map { "DELETE /v1/memories/\($0.uuidString)" }
        #expect(Array(requests.prefix(deletes.count)) == deletes,
                "No archive/profile/feed/media refresh may delay the next DELETE")
        let reads = Array(requests.dropFirst(deletes.count))
        let expectedReads: Set<String> = [
            "GET /v1/me", "GET /v1/me/memories", "GET /v1/feed",
            "GET /v1/users/\(fixture.user.id.uuidString)/memories"
        ]
        #expect(reads.count == expectedReads.count, "Refresh exactly once after the batch")
        #expect(Set(reads) == expectedReads)
    }

    private func makeStore(_ fixture: BatchDeletionFixture) -> (BackendStore, URLSession) {
        BatchDeletionURLProtocol.install { fixture.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchDeletionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://batch-delete-test.invalid")!, session: session)
        api.token = "batch-delete-test-session"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maptalk-batch-delete-\(UUID().uuidString)", isDirectory: true)
        let store = BackendStore(user: fixture.user.user, api: api, storageDirectory: directory,
                                 automaticallySync: false, observesConnectivity: false)
        return (store, session)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        BatchDeletionURLProtocol.install(nil)
    }
}

private final class BatchDeletionFixture: @unchecked Sendable {
    let user = BackendUser(id: UUID(), handle: "batch_owner")
    let otherUser = BackendUser(id: UUID(), handle: "other_visitor")
    let firstVisitID = UUID()
    let secondVisitID = UUID()
    let otherVisitID = UUID()
    let placeID = UUID()
    var ownVisitIDs: [UUID] { [firstVisitID, secondVisitID] }

    private let lock = NSLock()
    private let failSecondDelete: Bool
    private let returnStaleReads: Bool
    private var initialRecords: [BackendMemory] = []
    private var records: [UUID: BackendMemory] = [:]
    private var requestLog: [String] = []
    var requests: [String] { lock.withLock { requestLog } }
    var remainingIDs: Set<UUID> { lock.withLock { Set(records.keys) } }

    init(failSecondDelete: Bool = false, returnStaleReads: Bool = false) {
        self.failSecondDelete = failSecondDelete
        self.returnStaleReads = returnStaleReads
        let coordinate = BackendCoordinate(latitude: 37.3688, longitude: -122.0363)
        let place = BackendPlace(id: placeID, sourceId: nil, name: "Shared test café",
                                 category: "coffee", coordinate: coordinate)
        let date = Date()
        let values = [(firstVisitID, user), (secondVisitID, user), (otherVisitID, otherUser)].map { id, owner in
            BackendMemory(id: id, ownerId: owner.id, owner: owner, kind: "poi", visibility: "public",
                          location: coordinate, caption: "", place: place, media: [], createdAt: date,
                          publishedAt: date, expiresAt: date.addingTimeInterval(86_400), moderationStatus: "approved")
        }
        initialRecords = values
        records = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    func clearRequests() { lock.withLock { requestLog.removeAll() } }

    func respond(to operation: BatchDeletionURLProtocol) {
        let path = operation.request.url!.path
        let method = operation.request.httpMethod ?? "GET"
        do {
            let reply: (Int, Data) = try lock.withLock {
                requestLog.append("\(method) \(path)")
                if method == "DELETE", path.hasPrefix("/v1/memories/"),
                   let id = UUID(uuidString: operation.request.url!.lastPathComponent) {
                    if failSecondDelete, id == secondVisitID {
                        return (503, Data("{\"error\":{\"code\":\"delete_temporarily_unavailable\",\"message\":\"Please retry\"}}".utf8))
                    }
                    guard let record = records[id], record.ownerId == user.id else {
                        return (404, Data("{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}".utf8))
                    }
                    records.removeValue(forKey: id)
                    return (204, Data())
                }
                guard method == "GET" else { return (500, Data()) }
                if path == "/v1/me" {
                    struct Identity: Encodable { let user: BackendUser }
                    return (200, try encode(Identity(user: user)))
                }
                let values = returnStaleReads ? initialRecords : Array(records.values)
                let visible: [BackendMemory]
                switch path {
                case "/v1/feed": visible = values
                case "/v1/me/memories", "/v1/users/\(user.id.uuidString)/memories":
                    visible = values.filter { $0.ownerId == user.id }
                default: return (500, Data())
                }
                struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                return (200, try encode(Page(items: visible)))
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

private final class BatchDeletionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (BatchDeletionURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (BatchDeletionURLProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

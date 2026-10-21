import Combine
import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendOfflineAccountTests {
    @Test(.timeLimit(.minutes(1)))
    func cachedAccountEntersOfflineAndRecoversWithoutAnotherLogin() async throws {
        let fixture = OfflineAccountFixture()
        let (api, session) = makeAPI(fixture)
        let seed = BackendStore(user: fixture.user.user, api: api)
        defer { seed.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await seed.cacheVerifiedIdentity()
        try await seed.refresh()
        fixture.mode = .offline
        let persistence = MemorySession(auth: fixture.auth)
        let account = BackendAccountController(api: api, sessions: persistence.storage)
        await account.start()
        let restored = try #require(account.environment?.backend)
        #expect(restored.archive.privateReels.map(\.id) == [fixture.reelID])
        #expect(!account.restoreFailed)
        await waitUntil { restored.issue != nil }
        #expect(account.environment?.backend === restored)
        #expect(persistence.auth?.user.id == fixture.user.id)
        fixture.mode = .online
        account.resume()
        await waitUntil { restored.issue == nil }
        #expect(account.environment?.backend === restored)
        restored.clearLocalMedia()
    }

    @Test(.timeLimit(.minutes(1)))
    func firstEntryWithoutCacheStillRequiresNetwork() async {
        let fixture = OfflineAccountFixture()
        fixture.mode = .offline
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        let persistence = MemorySession(auth: fixture.auth)
        let account = BackendAccountController(api: api, sessions: persistence.storage)
        await account.start()
        #expect(account.environment == nil)
        #expect(account.restoreFailed)
        #expect(persistence.auth != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func signOutKeepsUnresolvedPublicationsIncludingCancelledOnes(cancelBeforeSignOut: Bool) async throws {
        let fixture = OfflineAccountFixture()
        fixture.mode = .offline
        let (api, session) = makeAPI(fixture)
        let seed = BackendStore(user: fixture.user.user, api: api, automaticallySync: false)
        defer { seed.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await seed.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await seed.enqueuePublish(.reel(.init(text: "Keep this until resolved", attachments: [], bubbleSource: nil)),
            audience: .livePublic, location: CLLocation(latitude: 37.36, longitude: -122.03), requestID: id)
        // A failed POST may have reached the server. Its cancellation must
        // survive even though the deleted row no longer displays a status.
        await seed.syncPendingPublications()
        if cancelBeforeSignOut {
            try await seed.deletePost(memoryID: id)
            #expect(seed.pendingPublications.isEmpty)
        }
        #expect(seed.hasPendingSyncWork)
        let persistence = MemorySession(auth: fixture.auth)
        let account = BackendAccountController(api: api, sessions: persistence.storage)
        await account.start()
        let restored = try #require(account.environment?.backend)
        defer { restored.clearLocalMedia() }
        #expect(restored.hasPendingSyncWork)
        account.signOut()
        #expect(account.environment?.backend === restored)
        #expect(account.signOutIssue != nil)
        #expect(persistence.auth != nil)
        #expect(!fixture.requests.contains("POST /v1/auth/logout"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [OfflineAccountFixture.Mode.unauthorized, .revoked])
    func definitiveRejectionEvictsCachedAccount(mode: OfflineAccountFixture.Mode) async throws {
        let fixture = OfflineAccountFixture()
        let (api, session) = makeAPI(fixture)
        let seed = BackendStore(user: fixture.user.user, api: api)
        defer { seed.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await seed.cacheVerifiedIdentity()
        try await seed.refresh()
        fixture.mode = mode
        let persistence = MemorySession(auth: fixture.auth)
        let account = BackendAccountController(api: api, sessions: persistence.storage)
        await account.start()
        await waitUntil { account.environment == nil }
        #expect(account.environment == nil)
        if mode == .unauthorized { #expect(persistence.auth == nil) }
        else { #expect(account.betaAccess?.status == "revoked") }
        let check = BackendStore(user: fixture.user.user, api: api)
        #expect(await check.restoreCachedState() == false)
        check.clearLocalMedia()
    }

    @Test(.timeLimit(.minutes(1)))
    func expiredSessionDoesNotEnterUsingCache() async throws {
        let fixture = OfflineAccountFixture()
        let (api, session) = makeAPI(fixture)
        let seed = BackendStore(user: fixture.user.user, api: api)
        defer { seed.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await seed.cacheVerifiedIdentity()
        let expired = BackendAuth(user: fixture.user, token: "expired-test-session", expiresAt: .now.addingTimeInterval(-1))
        let persistence = MemorySession(auth: expired)
        let account = BackendAccountController(api: api, sessions: persistence.storage)
        await account.start()
        #expect(account.environment == nil)
        #expect(persistence.auth == nil)
        #expect(fixture.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func myMapDeleteWithdrawsOwnReelInsteadOfHidingArchiveRow() async throws {
        let fixture = OfflineAccountFixture()
        let (api, session) = makeAPI(fixture)
        let store = BackendStore(user: fixture.user.user, api: api)
        defer { store.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await store.refresh()
        let viewModel = UserMapViewModel(environment: .connected(to: store), context: .me, dataScope: .privateArchive)
        viewModel.removeFromMyMap(.reel(fixture.reelID))
        await waitUntil { store.archive.privateReels.isEmpty }
        #expect(fixture.requests.contains("DELETE /v1/memories/\(fixture.reelID.uuidString)"))
        #expect(!fixture.requests.contains { $0.contains("/archive") })
        #expect(store.feedReels.value.isEmpty)
        #expect(store.ownPublicReels.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func groupedPOIDeletionOnlyDeletesCurrentPersonsVisits() async throws {
        let fixture = OfflineAccountFixture()
        let (api, session) = makeAPI(fixture)
        let store = BackendStore(user: fixture.user.user, api: api)
        defer { store.clearLocalMedia(); session.invalidateAndCancel(); OfflineAccountProtocol.install(nil) }
        try await store.refresh()
        let viewModel = UserMapViewModel(environment: .connected(to: store), context: .me, dataScope: .privateArchive)
        viewModel.removeFromMyMap(.poi(fixture.placeID))
        await waitUntil { store.archive.privatePOIs.isEmpty }
        for id in fixture.ownVisitIDs {
            #expect(fixture.requests.contains("DELETE /v1/memories/\(id.uuidString)"))
        }
        #expect(!fixture.requests.contains("DELETE /v1/memories/\(fixture.otherVisitID.uuidString)"))
        #expect(store.feedPOIs.value.flatMap(\.checkIns).map(\.id) == [fixture.otherVisitID])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Expected state did not settle")
    }

    private func makeAPI(_ fixture: OfflineAccountFixture) -> (BackendAPI, URLSession) {
        OfflineAccountProtocol.install { fixture.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineAccountProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://api.maptalkapp.com")!, session: session)
        api.token = fixture.auth.token
        return (api, session)
    }
}

@MainActor
private final class MemorySession {
    var auth: BackendAuth?
    init(auth: BackendAuth?) { self.auth = auth }
    var storage: BackendSessionPersistence {
        .init(load: { self.auth }, save: { self.auth = $0 }, delete: { self.auth = nil })
    }
}

final class OfflineAccountFixture: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case online, offline, unauthorized, revoked }
    let user = BackendUser(id: UUID(), handle: "offline_test")
    let reelID = UUID()
    let placeID = UUID()
    let ownVisitIDs = [UUID(), UUID()]
    let otherVisitID = UUID()
    let otherUserID = UUID()
    private let lock = NSLock()
    private var currentMode = Mode.online
    private var deleted: Set<UUID> = []
    private var requestLog: [String] = []
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }
    var requests: [String] { lock.withLock { requestLog } }
    var auth: BackendAuth { .init(user: user, token: "offline-test-session", expiresAt: .now.addingTimeInterval(86_400)) }

    fileprivate func handle(_ operation: OfflineAccountProtocol) {
        let path = operation.request.url!.path
        let method = operation.request.httpMethod ?? "GET"
        lock.withLock { requestLog.append("\(method) \(path)") }
        switch mode {
        case .offline:
            operation.fail(URLError(.notConnectedToInternet)); return
        case .unauthorized:
            operation.respond(status: 401, json: ["error": ["code": "unauthorized", "message": "Session expired"]]); return
        case .revoked where path == "/v1/beta/access":
            operation.respond(status: 403, json: ["error": ["code": "beta_access_revoked", "message": "Access revoked"]]); return
        default: break
        }
        if path == "/v1/me" {
            operation.respond(json: ["user": ["id": user.id.uuidString, "handle": user.handle]])
        } else if path == "/v1/beta/access" {
            operation.respond(json: ["required": true, "status": "active"])
        } else if method == "DELETE", let id = UUID(uuidString: path.components(separatedBy: "/").last ?? "") {
            _ = lock.withLock { deleted.insert(id) }
            operation.respond(status: 204, json: [:])
        } else {
            var records = [record(id: reelID), record(id: ownVisitIDs[0], isPOI: true),
                           record(id: ownVisitIDs[1], isPOI: true), record(id: otherVisitID, isPOI: true, other: true)]
            let deleted = lock.withLock { self.deleted }
            records = records.filter { !deleted.contains(UUID(uuidString: $0["id"] as! String)!) }
            if path != "/v1/feed" { records = records.filter { $0["ownerId"] as? String == user.id.uuidString } }
            operation.respond(json: ["items": records, "nextCursor": NSNull()])
        }
    }

    private func record(id: UUID, isPOI: Bool = false, other: Bool = false) -> [String: Any] {
        let owner = other ? otherUserID : user.id
        var value: [String: Any] = ["id": id.uuidString, "ownerId": owner.uuidString,
            "owner": ["id": owner.uuidString, "handle": other ? "other_person" : user.handle],
            "kind": isPOI ? "poi" : "reel", "visibility": "public", "moderationStatus": "approved",
            "caption": "Saved offline memory", "location": ["latitude": 37.36, "longitude": -122.03],
            "media": [], "createdAt": Date().ISO8601Format(), "publishedAt": Date().ISO8601Format(),
            "expiresAt": Date().addingTimeInterval(86_400).ISO8601Format()]
        if isPOI {
            value["place"] = ["id": placeID.uuidString, "name": "Test place", "category": "coffee",
                              "coordinate": ["latitude": 37.36, "longitude": -122.03]]
        }
        return value
    }
}

private final class OfflineAccountProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (OfflineAccountProtocol) -> Void)?
    static func install(_ value: (@Sendable (OfflineAccountProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
    func respond(status: Int = 200, json: [String: Any]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
}

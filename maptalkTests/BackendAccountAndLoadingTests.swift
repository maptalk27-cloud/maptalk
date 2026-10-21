import AuthenticationServices
import Combine
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendAccountAndLoadingTests {
    @Test
    func tabValueRebuildsDoNotEagerlyConstructNewViewModels() {
        let environment = AppEnvironment.bootstrap()
        var constructions = 0
        func map() -> MapTalkViewModel { constructions += 1; return .init(environment: environment) }
        func archive() -> UserMapViewModel { constructions += 1; return .init(environment: environment, context: .me) }
        func chats() -> FriendsViewModel { constructions += 1; return .init(environment: environment) }
        func profile() -> UserProfileViewModel { constructions += 1; return .init(environment: environment, context: .me) }
        for _ in 0..<10 {
            _ = MapTalkView(viewModel: map())
            _ = UserMapView(viewModel: archive())
            _ = FriendsView(viewModel: chats())
            _ = UserProfileView(viewModel: profile())
        }
        #expect(constructions == 0, "StateObject must evaluate the factory only when SwiftUI installs a new view identity")
    }

    @Test
    func appleRequestUsesServerNonceAndCancellationIsQuiet() async throws {
        let fixture = AccountLoadingFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); AccountLoadingProtocol.install(nil) }
        let account = BackendAccountController(api: api)
        await account.prepareAppleSignIn()
        let initial = try #require(account.appleChallenge)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.configureAppleRequest(request)
        #expect(request.nonce == initial.nonce)
        #expect(request.state == initial.challengeId.uuidString)
        #expect(request.requestedScopes?.isEmpty == true)
        #expect(account.isSubmitting)
        #expect(!account.appleSignInReady)
        await account.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)))
        #expect(account.issue == nil)
        #expect(!account.isSubmitting)
        #expect(account.environment == nil)
        #expect(account.appleSignInReady)
        #expect(account.appleChallenge?.challengeId != initial.challengeId)
        #expect(fixture.paths.filter { $0 == "/v1/auth/apple/challenge" }.count == 2)
        #expect(!fixture.paths.contains("/v1/auth/apple"))
    }

    @Test
    func unconfiguredAppleLoginStaysSignedOutAndCanRetry() async throws {
        let fixture = AccountLoadingFixture(challengeStatus: 503)
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); AccountLoadingProtocol.install(nil) }
        let account = BackendAccountController(api: api)
        await account.prepareAppleSignIn()
        #expect(!account.appleSignInReady)
        #expect(!account.isPreparingApple)
        #expect(account.environment == nil)
        #expect(account.issue == "Apple sign-in is not configured on this development server yet.")
        fixture.challengeStatus = 200
        await account.prepareAppleSignIn()
        #expect(account.appleSignInReady)
        #expect(account.issue == nil)
    }

    @Test
    func expiredChallengeNeverEnablesAppleAuthorization() async throws {
        let fixture = AccountLoadingFixture(challengeLifetime: -1)
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); AccountLoadingProtocol.install(nil) }
        let account = BackendAccountController(api: api)
        await account.prepareAppleSignIn()
        #expect(!account.appleSignInReady)
        #expect(account.appleChallenge == nil)
        #expect(account.environment == nil)
        #expect(account.issue == "This sign-in attempt expired. Please try again.")
    }

    @Test
    func concurrentRefreshAndImmediateReentryReuseOneSnapshot() async throws {
        let fixture = AccountLoadingFixture()
        let (api, session) = makeAPI(fixture)
        let store = BackendStore(user: .init(id: fixture.userID, handle: "loading_test", avatarURL: nil), api: api)
        defer { store.clearLocalMedia(); session.invalidateAndCancel(); AccountLoadingProtocol.install(nil) }
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        try await first
        try await second
        try await store.refreshIfNeeded()
        #expect(fixture.paths.count == 4, "Login and immediate map appearance must not read the profile and three lists twice")
        #expect(store.archive.privatePOIs.isEmpty && store.archive.privateReels.isEmpty)
        // Explicit user refresh still reads new server content.
        try await store.refresh()
        #expect(fixture.paths.count == 8)
    }

    @Test
    func diskCacheCannotWriteAfterAccountInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendMediaDisk(directory: directory)
        let id = UUID()
        #expect(try await disk.cachedURL(for: id) == nil)
        let url = try await disk.write(Data([1, 2, 3]), for: id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        disk.invalidate()
        do {
            _ = try await disk.write(Data([4]), for: id)
            Issue.record("A late download recreated a signed-out cache")
        } catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeAPI(_ fixture: AccountLoadingFixture) -> (BackendAPI, URLSession) {
        AccountLoadingProtocol.install { fixture.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountLoadingProtocol.self]
        let session = URLSession(configuration: configuration)
        return (BackendAPI(session: session), session)
    }
}

private final class AccountLoadingFixture: @unchecked Sendable {
    let userID = UUID()
    private let lock = NSLock()
    private var requests: [String] = []
    private var status: Int
    private let challengeLifetime: TimeInterval
    var paths: [String] { lock.withLock { requests } }
    var challengeStatus: Int {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }

    init(challengeStatus: Int = 200, challengeLifetime: TimeInterval = 300) {
        status = challengeStatus
        self.challengeLifetime = challengeLifetime
    }

    func handle(_ operation: AccountLoadingProtocol) {
        let path = operation.request.url!.path
        lock.withLock { requests.append(path) }
        if path == "/v1/auth/apple/challenge" {
            if challengeStatus != 200 {
                operation.respond(status: challengeStatus, json: """
                {"error":{"message":"Apple sign-in is not configured on this development server yet."}}
                """)
            } else {
                let expires = Date().addingTimeInterval(challengeLifetime).ISO8601Format()
                operation.respond(status: 200, json: """
                {"challengeId":"\(UUID())","nonce":"\(UUID())","expiresAt":"\(expires)"}
                """)
            }
        } else if path == "/v1/me" {
            operation.respond(status: 200, json: "{\"user\":{\"id\":\"\(userID)\",\"handle\":\"loading_test\"}}")
        } else {
            operation.respond(status: 200, json: "{\"items\":[],\"nextCursor\":null}")
        }
    }
}

private final class AccountLoadingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (AccountLoadingProtocol) -> Void)?
    static func install(_ value: (@Sendable (AccountLoadingProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(status: Int, json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite(.serialized)
struct BackendProfileTests {
    @Test func olderUserPayloadStillDecodesWithoutAnAvatar() throws {
        let id = UUID()
        let decoded = try BackendAPI.decoder.decode(BackendUser.self,
            from: Data("{\"id\":\"\(id)\",\"handle\":\"profile_test\"}".utf8))
        #expect(decoded.avatar == nil)
        #expect(decoded.user.avatarURL == nil)
    }

    @Test func handleOnlySaveKeepsAvatarAndOmitsAvatarField() async throws {
        let fixture = ProfileFixture(hasAvatar: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        let originalURL = try #require(store.user.avatarURL)
        try await store.updateProfile(handle: "Updated_Name", avatarData: nil)
        #expect(store.user.handle == "updated_name")
        #expect(store.user.avatarURL == originalURL)
        #expect(store.user(for: fixture.userID) == store.user)
        #expect(fixture.requests.filter { $0 == "POST /v1/media" }.isEmpty)
        #expect(fixture.patchBodies.count == 1)
        let body = try #require(try JSONSerialization.jsonObject(with: fixture.patchBodies[0]) as? [String: Any])
        #expect(body["avatarMediaId"] == nil)
        #expect(body["handle"] as? String == "Updated_Name")
    }

    @Test func avatarSaveUploadsThenPatchesAndDownloadsAuthenticatedNormalizedBytes() async throws {
        let fixture = ProfileFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        var identities: [User] = []
        let subscription = store.$user.sink { identities.append($0) }
        defer { subscription.cancel() }
        try await store.updateProfile(handle: "new_name", avatarData: Data([137, 80, 78, 71, 9]))
        let local = try #require(store.user.avatarURL)
        #expect(local.isFileURL)
        #expect(try Data(contentsOf: local) == fixture.normalizedPhoto)
        #expect(store.user.handle == "new_name")
        #expect(identities.last == store.user)
        #expect(fixture.requests == ["POST /v1/media", "PATCH /v1/me", "GET /v1/media/\(fixture.avatarID.uuidString.lowercased())"])
        #expect(fixture.authorizations.allSatisfy { $0 == "Bearer profile-test-token" })
        let body = try #require(try JSONSerialization.jsonObject(with: fixture.patchBodies[0]) as? [String: Any])
        #expect((body["avatarMediaId"] as? String)?.lowercased() == fixture.avatarID.uuidString.lowercased())
    }

    @Test func profileConflictLeavesCurrentIdentityAndDoesNotDeleteUploadedMedia() async throws {
        let fixture = ProfileFixture(patchStatus: 409)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        do {
            try await store.updateProfile(handle: "taken_name", avatarData: Data([1]))
            Issue.record("A username conflict must fail the profile change")
        } catch let error as BackendClientError {
            guard case .http(status: 409, message: _) = error else { Issue.record("Expected HTTP 409"); return }
        }
        #expect(store.user.handle == "profile_test")
        #expect(store.user.avatarURL == nil)
        #expect(!fixture.requests.contains { $0.hasPrefix("DELETE") })
    }

    @Test func lostPatchResponseNeverDeletesCommittedAvatarAndRefreshRecoversIdentity() async throws {
        let fixture = ProfileFixture(losePatchResponse: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        do {
            try await store.updateProfile(handle: "saved_remotely", avatarData: Data([1]))
            Issue.record("A lost PATCH response must not claim a confirmed save")
        } catch { }
        #expect(store.user.handle == "profile_test")
        #expect(!fixture.requests.contains { $0.hasPrefix("DELETE") })
        try await store.refresh()
        #expect(store.user.handle == "saved_remotely")
        #expect(store.user.avatarURL?.isFileURL == true)
    }

    @Test func avatarReadFailureDoesNotMisreportConfirmedProfileSave() async throws {
        let fixture = ProfileFixture(failAvatar: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.updateProfile(handle: "confirmed_name", avatarData: Data([1]))
        #expect(store.user.handle == "confirmed_name")
        #expect(store.issue?.hasPrefix("Your profile was saved.") == true)
        fixture.failAvatar = false
        try await store.refresh()
        #expect(store.user.avatarURL?.isFileURL == true)
        #expect(store.issue == nil)
    }

    @Test func refreshAndEmptyOtherProfileLoadAvatarsWithoutAnyPosts() async throws {
        let fixture = ProfileFixture(hasAvatar: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        #expect(store.user.avatarURL?.isFileURL == true)
        #expect(store.archive.privateReels.isEmpty)
        let empty = try await store.loadProfile(userID: fixture.otherID)
        #expect(empty.pois.isEmpty && empty.reels.isEmpty)
        #expect(store.user(for: fixture.otherID)?.handle == "other_profile")
        #expect(store.user(for: fixture.otherID)?.avatarURL?.isFileURL == true)
        // Recreating the store represents a restored session. Identity is
        // fetched again, while immutable media IDs can reuse account disk cache.
        let restored = BackendStore(user: .init(id: fixture.userID, handle: "stale_keychain", avatarURL: nil), api: store.api)
        defer { restored.clearLocalMedia() }
        try await restored.refresh()
        #expect(restored.user.handle == "profile_test")
        #expect(restored.user.avatarURL == store.user.avatarURL)
        #expect(fixture.requests.filter { $0 == "GET /v1/media/\(fixture.avatarID.uuidString.lowercased())" }.count == 1)
    }

    @Test func unavailableAvatarDoesNotDiscardVisibleOrDurablePostMetadata() async throws {
        let fixture = ProfileFixture(hasAvatar: true, failAvatar: true, includeOwnMemories: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        #expect(store.archive.privateReels.map(\.id) == [fixture.ownMemoryID])
        #expect(store.feedReels.value.map(\.id) == [fixture.ownMemoryID])
        #expect(store.user.avatarURL == nil)
        #expect(store.issue?.contains("photos or videos couldn't load") == true)
        let restored = BackendStore(user: store.user, api: store.api, automaticallySync: false)
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privateReels.map(\.id) == [fixture.ownMemoryID])
    }

    @Test func feedOwnerAvatarIsDownloadedOnceAndNeverExposedAsRemoteURL() async throws {
        let fixture = ProfileFixture(includeFeedOwner: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        #expect(store.feedReels.value.count == 1)
        let owner = try #require(store.user(for: fixture.otherID))
        #expect(owner.handle == "other_profile")
        #expect(owner.avatarURL?.isFileURL == true)
        _ = try await store.loadProfile(userID: fixture.otherID)
        #expect(fixture.requests.filter { $0 == "GET /v1/media/\(fixture.otherAvatarID.uuidString.lowercased())" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func saveWithExistingOwnPostsAndLiveProfileSubscribers(replaceAvatar: Bool) async throws {
        let fixture = ProfileFixture(includeFeedOwner: true, includeOwnMemories: true)
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        try await store.refresh()
        #expect(store.ownedMemories.count == 1)
        #expect(store.archive.privateReels.count == 1)
        #expect(store.ownPublicReels.count == 1)
        #expect(store.feedReels.value.count == 2)

        // Keep the same MyMap -> profile subscriptions that exist while the
        // editor sheet is presented. Synchronous reads emulate dependent card
        // and menu evaluation during Combine's willChange delivery.
        let environment = AppEnvironment.connected(to: store)
        let myMap = UserMapViewModel(environment: environment, context: .me, dataScope: .privateArchive)
        let profile = UserProfileViewModel(environment: environment, context: .me)
        var observations = 0
        var subscriptions = Set<AnyCancellable>()
        let observe = {
            observations += 1
            _ = store.manageableMemories(for: .reel(fixture.ownMemoryID))
            _ = store.user(for: fixture.userID)
            _ = myMap.userProvider(for: fixture.userID)
            _ = profile.userProvider(for: fixture.userID)
            _ = profile.historyActivities
            _ = profile.stats
        }
        store.objectWillChange.sink { observe() }.store(in: &subscriptions)
        myMap.objectWillChange.sink { observe() }.store(in: &subscriptions)
        profile.objectWillChange.sink { observe() }.store(in: &subscriptions)
        store.$ownedMemories.sink { _ in observe() }.store(in: &subscriptions)
        defer { subscriptions.removeAll() }

        // Match the real caller: let the sheet initializer infer the stored
        // async closure's MainActor isolation. Directly calling the model would
        // bypass the reabstraction thunk that crashed on the physical device.
        let sheet = ConnectedEditProfileSheet(user: profile.user) { handle, avatar in
            try await profile.saveConnectedProfile(handle: handle, avatarData: avatar)
        }
        let avatar = replaceAvatar ? Data([137, 80, 78, 71, 12, 34]) : nil
        try await sheet.submitProfile(handle: "existing_posts_user", avatarData: avatar)
        #expect(observations > 0)
        #expect(store.user.handle == "existing_posts_user")
        #expect(myMap.identity.user == store.user)
        #expect(profile.user == store.user)
        #expect(store.ownedMemories[fixture.ownMemoryID]?.owner.handle == "existing_posts_user")
        #expect(myMap.reels.map(\.id) == [fixture.ownMemoryID])
        #expect(profile.reels.map(\.id) == [fixture.ownMemoryID])
        #expect(store.feedReels.value.count == 2)
        #expect(store.user(for: fixture.otherID)?.handle == "other_profile")
        #expect(store.user.avatarURL?.isFileURL == (replaceAvatar ? true : nil))
        #expect(fixture.uploadBodies == (avatar.map { [$0] } ?? []))
        let patch = try #require(fixture.patchBodies.last)
        let body = try #require(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(body["handle"] as? String == "existing_posts_user")
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedRefreshCannotRevertConfirmedProfileSave() async throws {
        let fixture = ProfileFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let (responses, continuation) = AsyncStream<(ProfileProtocol, Data)>.makeStream()
        fixture.pauseNextMe { operation, data in continuation.yield((operation, data)) }
        defer { continuation.finish() }
        let oldRefresh = Task { try await store.refresh() }
        var iterator = responses.makeAsyncIterator()
        let paused = try #require(await iterator.next())
        try await store.updateProfile(handle: "latest_name", avatarData: nil)
        paused.0.respond(data: paused.1)
        do { try await oldRefresh.value } catch is CancellationError { }
        #expect(store.user.handle == "latest_name")
        #expect(store.user(for: fixture.userID)?.handle == "latest_name")
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedMapOwnersCannotRevertUpdatedOwnIdentity() async throws {
        let fixture = ProfileFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        let (responses, continuation) = AsyncStream<(ProfileProtocol, Data)>.makeStream()
        fixture.pauseNextMap { operation, data in continuation.yield((operation, data)) }
        defer { continuation.finish() }
        let oldMap = Task { try await store.loadMap(.init(center: .init(latitude: 37, longitude: -122),
            latitudinalMeters: 10_000, longitudinalMeters: 10_000)) }
        var iterator = responses.makeAsyncIterator()
        let paused = try #require(await iterator.next())
        try await store.updateProfile(handle: "latest_name", avatarData: nil)
        paused.0.respond(data: paused.1)
        _ = try await oldMap.value
        #expect(store.user(for: fixture.userID)?.handle == "latest_name")
        #expect(store.ownedMemories.values.allSatisfy { $0.owner.handle == "latest_name" })
    }

    @Test func invalidHandleOrOversizedAvatarMakesNoRequests() async throws {
        let fixture = ProfileFixture()
        let (store, session) = makeStore(fixture)
        defer { finish(store, session) }
        for handle in ["ab", "contains space", "name\n", String(repeating: "a", count: 33)] {
            do { try await store.updateProfile(handle: handle, avatarData: nil); Issue.record("Invalid username was sent") }
            catch { }
        }
        do {
            try await store.updateProfile(handle: "valid_name", avatarData: Data(repeating: 0, count: 10 * 1024 * 1024 + 1))
            Issue.record("Oversized photo was sent")
        } catch { }
        #expect(fixture.requests.isEmpty)
    }

    private func makeStore(_ fixture: ProfileFixture) -> (BackendStore, URLSession) {
        ProfileProtocol.install { fixture.handle($0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileProtocol.self]
        let session = URLSession(configuration: config)
        let api = BackendAPI(baseURL: URL(string: "https://profile-tests.example")!, session: session)
        api.token = "profile-test-token"
        return (BackendStore(user: .init(id: fixture.userID, handle: "profile_test", avatarURL: nil), api: api), session)
    }

    private func finish(_ store: BackendStore, _ session: URLSession) {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        ProfileProtocol.install(nil)
    }
}

private final class ProfileFixture: @unchecked Sendable {
    let userID = UUID()
    let otherID = UUID()
    let avatarID = UUID()
    let otherAvatarID = UUID()
    let ownMemoryID = UUID()
    let otherMemoryID = UUID()
    let normalizedPhoto = Data([255, 216, 255, 1, 2, 3, 255, 217])
    private let lock = NSLock()
    private var storedHandle = "profile_test"
    private var hasAvatar: Bool
    private let patchStatus: Int
    private let losePatchResponse: Bool
    private let includeFeedOwner: Bool
    private let includeOwnMemories: Bool
    private var avatarFailure: Bool
    private var recordedRequests: [String] = []
    private var recordedAuthorizations: [String] = []
    private var recordedBodies: [Data] = []
    private var recordedUploads: [Data] = []
    private var pausedMe: (@Sendable (ProfileProtocol, Data) -> Void)?
    private var pausedMap: (@Sendable (ProfileProtocol, Data) -> Void)?
    var requests: [String] { lock.withLock { recordedRequests } }
    var authorizations: [String] { lock.withLock { recordedAuthorizations } }
    var patchBodies: [Data] { lock.withLock { recordedBodies } }
    var uploadBodies: [Data] { lock.withLock { recordedUploads } }
    var failAvatar: Bool {
        get { lock.withLock { avatarFailure } }
        set { lock.withLock { avatarFailure = newValue } }
    }

    init(hasAvatar: Bool = false, patchStatus: Int = 200, losePatchResponse: Bool = false,
         failAvatar: Bool = false, includeFeedOwner: Bool = false, includeOwnMemories: Bool = false) {
        self.hasAvatar = hasAvatar
        self.patchStatus = patchStatus
        self.losePatchResponse = losePatchResponse
        self.avatarFailure = failAvatar
        self.includeFeedOwner = includeFeedOwner
        self.includeOwnMemories = includeOwnMemories
    }

    func pauseNextMe(_ handler: @escaping @Sendable (ProfileProtocol, Data) -> Void) { lock.withLock { pausedMe = handler } }
    func pauseNextMap(_ handler: @escaping @Sendable (ProfileProtocol, Data) -> Void) { lock.withLock { pausedMap = handler } }

    func handle(_ operation: ProfileProtocol) {
        let path = operation.request.url!.path
        let method = operation.request.httpMethod ?? "GET"
        do {
            let response: (Int, Data, (@Sendable (ProfileProtocol, Data) -> Void)?) = try lock.withLock {
                recordedRequests.append("\(method) \(path)")
                recordedAuthorizations.append(operation.request.value(forHTTPHeaderField: "Authorization") ?? "")
                if method == "POST", path == "/v1/media" {
                    recordedUploads.append(operation.body())
                    return (201, try encode(media(avatarID)), nil)
                }
                if method == "PATCH", path == "/v1/me" {
                    let body = operation.body()
                    recordedBodies.append(body)
                    if patchStatus != 200 { return (patchStatus, Data("{\"error\":{\"message\":\"Username is already taken.\"}}".utf8), nil) }
                    let input = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                    storedHandle = (input["handle"] as! String).lowercased()
                    if input["avatarMediaId"] != nil { hasAvatar = true }
                    return (200, try identity(userID), nil)
                }
                if path.hasPrefix("/v1/media/") {
                    return (avatarFailure ? 503 : 200, avatarFailure ? Data("{\"error\":{\"message\":\"Photo unavailable\"}}".utf8) : normalizedPhoto, nil)
                }
                if path == "/v1/me" {
                    defer { pausedMe = nil }
                    return (200, try identity(userID), pausedMe)
                }
                if path == "/v1/users/\(otherID.uuidString)" { return (200, try identity(otherID), nil) }
                if path == "/v1/users/\(userID.uuidString)" { return (200, try identity(userID), nil) }
                struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                if path == "/v1/map/memories" {
                    defer { pausedMap = nil }
                    return (200, try encode(Page(items: [memory(ownerID: userID)])), pausedMap)
                }
                var records = includeFeedOwner && (path == "/v1/feed" || path == "/v1/users/\(otherID.uuidString)/memories")
                    ? [memory(ownerID: otherID)] : []
                if includeOwnMemories, ["/v1/feed", "/v1/me/memories", "/v1/users/\(userID.uuidString)/memories"].contains(path) {
                    records.append(memory(ownerID: userID))
                }
                return (200, try encode(Page(items: records)), nil)
            }
            if method == "PATCH", losePatchResponse { operation.fail(URLError(.networkConnectionLost)) }
            else if let paused = response.2 { paused(operation, response.1) }
            else { operation.respond(status: response.0, data: response.1) }
        } catch { operation.fail(error) }
    }

    private func media(_ id: UUID) -> BackendMedia {
        .init(id: id, mimeType: "image/jpeg", byteCount: normalizedPhoto.count, path: "/v1/media/\(id.uuidString.lowercased())")
    }

    private func profile(_ id: UUID) -> BackendUser {
        .init(id: id, handle: id == userID ? storedHandle : "other_profile",
            avatar: id == userID ? (hasAvatar ? media(avatarID) : nil) : media(otherAvatarID))
    }

    private func identity(_ id: UUID) throws -> Data {
        struct Identity: Encodable { let user: BackendUser }
        return try encode(Identity(user: profile(id)))
    }

    private func memory(ownerID: UUID) -> BackendMemory {
        .init(id: ownerID == userID ? ownMemoryID : otherMemoryID, ownerId: ownerID, owner: profile(ownerID), kind: "reel", visibility: "public",
            location: .init(latitude: 37, longitude: -122), caption: "", place: nil, media: [],
            createdAt: .now, publishedAt: .now, expiresAt: .now.addingTimeInterval(86_400), moderationStatus: "approved")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class ProfileProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (ProfileProtocol) -> Void)?
    static func install(_ value: (@Sendable (ProfileProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
    func respond(status: Int = 200, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}

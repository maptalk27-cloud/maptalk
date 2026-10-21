import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct SocialSignInTests {
    @Test
    func demoEntersWithoutCredentialsAndStaysSeparateFromRealAccounts() {
        let mock = MockAccountSession()
        #expect(mock.environment == nil)
        mock.enterDemo()
        #expect(mock.environment?.backend == nil)
        #expect(mock.environment?.myMapArchive.privateReels.isEmpty == false)
        mock.signOut()
        #expect(mock.environment == nil)
    }

    @Test
    func missingLocalConfigurationNeverOpensProviderOrSendsCredentials() async {
        let driver = SocialDriver()
        driver.configIssue = "Google needs its client IDs."
        let fixture = SocialFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        await account.signInWithSocial(provider: "google")
        #expect(account.issue == driver.configIssue)
        #expect(account.environment == nil)
        #expect(!account.isSubmitting)
        #expect(driver.authorizations == 0 && fixture.paths.isEmpty)
        await account.retrySignIn()
        #expect(driver.configuredProviders == ["google", "google"], "Retry must not silently switch to Apple")
    }

    @Test
    func missingServerConfigurationStopsBeforeOpeningNativeAuthorization() async {
        let driver = SocialDriver()
        let fixture = SocialFixture(available: false)
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        await account.signInWithSocial(provider: "wechat")
        #expect(account.issue == "Provider configuration required.")
        #expect(account.environment == nil)
        #expect(driver.authorizations == 0)
        #expect(fixture.paths == ["/v1/auth/providers"])
    }

    @Test
    func cancelledGoogleAuthorizationDoesNotExchangeOrSignIn() async {
        let driver = SocialDriver()
        driver.cancelled = true
        let fixture = SocialFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        await account.signInWithSocial(provider: "google")
        #expect(account.issue == nil && account.environment == nil)
        #expect(!account.isSubmitting)
        #expect(fixture.paths == ["/v1/auth/providers", "/v1/auth/google/challenge"])
    }

    @Test
    func incorrectWeChatStateNeverReachesExchange() async {
        let driver = SocialDriver()
        driver.wrongState = true
        let fixture = SocialFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        await account.signInWithSocial(provider: "wechat")
        #expect(driver.receivedState == fixture.state)
        #expect(account.environment == nil)
        #expect(account.issue?.contains("WeChat couldn't verify") == true)
        #expect(!fixture.paths.contains("/v1/auth/wechat"))
    }

    @Test
    func switchingToMockInvalidatesALateProviderCallback() async throws {
        let driver = SocialDriver()
        driver.holdGoogleResponse = true
        let fixture = SocialFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        let attempt = Task { await account.signInWithSocial(provider: "google") }
        for _ in 0..<1_000 where driver.pendingGoogle == nil { await Task.yield() }
        try #require(driver.pendingGoogle != nil)
        account.cancelPendingSignIn()
        // Simulate a successful native callback arriving after cancellation.
        driver.pendingGoogle?.resume(returning: "late-code")
        driver.pendingGoogle = nil
        await attempt.value
        #expect(account.environment == nil && !account.isSubmitting)
        #expect(api.token == nil)
        #expect(!fixture.paths.contains("/v1/auth/google"))
    }

    @Test
    func rejectedProviderCodeNeverCreatesSessionOrFallsBackToMock() async {
        let driver = SocialDriver()
        let fixture = SocialFixture()
        let (api, session) = makeAPI(fixture)
        defer { session.invalidateAndCancel(); SocialProtocol.handler = nil }
        let account = BackendAccountController(api: api, social: driver)
        await account.signInWithSocial(provider: "google")
        #expect(account.environment == nil)
        #expect(api.token == nil)
        #expect(account.issue == "Invalid provider authorization.")
        #expect(fixture.paths.last == "/v1/auth/google")
        #expect(fixture.exchangedCode == "unit-test-authorization-code")
    }

    private func makeAPI(_ fixture: SocialFixture) -> (BackendAPI, URLSession) {
        SocialProtocol.handler = { fixture.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialProtocol.self]
        let session = URLSession(configuration: configuration)
        return (BackendAPI(session: session), session)
    }
}

@MainActor
private final class SocialDriver: SocialSignInProviding {
    var configIssue: String?
    var configuredProviders: [String] = []
    var authorizations = 0
    var cancelled = false
    var wrongState = false
    var receivedState: String?
    var holdGoogleResponse = false
    var pendingGoogle: CheckedContinuation<String, Error>?
    func configurationIssue(for provider: String) -> String? {
        configuredProviders.append(provider)
        return configIssue
    }
    func signInGoogle() async throws -> String {
        authorizations += 1
        if cancelled { throw CancellationError() }
        if holdGoogleResponse {
            return try await withCheckedThrowingContinuation { pendingGoogle = $0 }
        }
        return "unit-test-authorization-code"
    }
    func signInWeChat(state: String) async throws -> WeChatAuthorization {
        authorizations += 1
        receivedState = state
        if cancelled { throw CancellationError() }
        return .init(code: "unit-test-authorization-code", state: wrongState ? "different-state" : state)
    }
    func signOut() {}
}

private final class SocialFixture: @unchecked Sendable {
    let state = "server-generated-test-state"
    let available: Bool
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var code: String?
    var paths: [String] { lock.withLock { recordedPaths } }
    var exchangedCode: String? { lock.withLock { code } }
    init(available: Bool = true) { self.available = available }
    func respond(to operation: SocialProtocol) {
        let path = operation.request.url!.path
        lock.withLock { recordedPaths.append(path) }
        if path == "/v1/auth/providers" {
            operation.respond(status: 200, object: ["providers": ["apple", "google", "wechat"].map {
                ["id": $0, "available": available, "reason": "Provider configuration required."] as [String: Any]
            }])
        } else if path.hasSuffix("/challenge") {
            operation.respond(status: 200, object: ["challengeId": UUID().uuidString, "state": state,
                "expiresAt": Date().addingTimeInterval(300).ISO8601Format()])
        } else {
            var bytes = operation.request.httpBody ?? Data()
            if let stream = operation.request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            lock.withLock { code = body?["code"] as? String }
            operation.respond(status: 401, object: ["error": ["message": "Invalid provider authorization."]])
        }
    }
}

private final class SocialProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (SocialProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(status: Int, object: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}

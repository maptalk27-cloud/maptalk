import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendDeploymentTests {
    @Test(arguments: [
        "http://api.example.com", "https://user:password@api.example.com",
        "https://api.example.com/v1", "https://api.example.com?token=secret",
        "https://api.example.com#fragment", "http://127.0.0.1:8787", "https://localhost"
    ])
    func releaseRejectsUnsafeServerConfiguration(address: String) {
        #expect(BackendDeploymentConfiguration.validatedURL(address, allowLocal: false) == nil)
    }

    @Test func hostedAndExplicitLocalConfigurationsAreSeparate() {
        #expect(BackendDeploymentConfiguration.validatedURL("https://api.example.com", allowLocal: false) != nil)
        #expect(BackendDeploymentConfiguration.validatedURL("http://127.0.0.1:8787", allowLocal: true) != nil)
        #expect(BackendDeploymentConfiguration.validatedURL("http://192.168.1.10:8787", allowLocal: true) == nil)
    }

    @Test func pendingMembershipDoesNotMeanPermissionToReadContent() async throws {
        DeploymentProtocol.response = (200, #"{"required":true,"status":"pending"}"#)
        let (api, session) = makeAPI()
        defer { session.invalidateAndCancel() }
        let status = try await api.betaAccess()
        #expect(!status.isActive)
        #expect(DeploymentProtocol.lastPath == "/v1/beta/access")
    }

    @Test func revokedMembershipClosesTheConnectedAppInsteadOfShowingDemo() async throws {
        DeploymentProtocol.response = (403, #"{"error":{"code":"beta_access_revoked","message":"Access revoked"}}"#)
        let (api, session) = makeAPI()
        defer { session.invalidateAndCancel() }
        let account = BackendAccountController(api: api)
        do {
            _ = try await api.allMemories(path: "/v1/feed")
            Issue.record("Revoked access must not return content")
        } catch {
            #expect(account.betaAccess?.status == "revoked")
            #expect(account.environment == nil)
            #expect(!account.isRestoring)
        }
    }

    @Test func inviteSubmissionSendsOnlyItsCode() async throws {
        DeploymentProtocol.response = (204, "")
        let (api, session) = makeAPI()
        defer { session.invalidateAndCancel() }
        try await api.redeemInvite("test-invitation")
        #expect(DeploymentProtocol.lastPath == "/v1/beta/redeem")
        let json = try #require(try JSONSerialization.jsonObject(with: DeploymentProtocol.lastBody) as? [String: String])
        #expect(json == ["code": "test-invitation"])
    }

    private func makeAPI() -> (BackendAPI, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeploymentProtocol.self]
        let session = URLSession(configuration: config)
        return (BackendAPI(baseURL: URL(string: "https://api.example.test")!, session: session), session)
    }
}

private final class DeploymentProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, String) = (200, "")
    nonisolated(unsafe) static var lastPath = ""
    nonisolated(unsafe) static var lastBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastPath = request.url?.path ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lastBody = body
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

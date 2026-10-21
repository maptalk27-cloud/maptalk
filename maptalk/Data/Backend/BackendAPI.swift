import Foundation

enum BackendClientError: LocalizedError {
    case message(String)
    case unauthorized
    case http(status: Int, message: String)
    case publishPending(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        case .unauthorized: return "Your session has expired. Sign out and sign in again."
        case let .http(_, message): return message
        case let .publishPending(message):
            return "\(message) Your draft is locked because this save isn't confirmed. Retry the same save, or close and check MyMap."
        }
    }

    /// A timeout or conflict may follow an already committed request. Only an
    /// explicit refusal known not to have saved the record unlocks editing.
    var confirmsPublishRejection: Bool {
        switch self {
        case .unauthorized: return true
        case let .http(status, _): return [400, 403, 404, 410, 413, 415, 422, 429].contains(status)
        default: return false
        }
    }
}

nonisolated struct BackendUser: Codable, Sendable {
    let id: UUID
    let handle: String
    var avatar: BackendMedia? = nil
    @MainActor var user: User { User(id: id, handle: handle, avatarURL: nil) }
}

nonisolated struct BackendAuth: Codable, Sendable {
    let user: BackendUser
    let token: String
    let expiresAt: Date
}

nonisolated struct BackendAppleChallenge: Decodable, Sendable {
    let challengeId: UUID
    let nonce: String
    let expiresAt: Date
}

nonisolated struct BackendSocialChallenge: Decodable, Sendable {
    let challengeId: UUID
    let state: String?
    let expiresAt: Date
}

nonisolated struct BackendAuthProviders: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        let id: String
        let available: Bool
        let reason: String?
    }
    let providers: [Provider]
}

nonisolated struct BackendBetaAccess: Decodable, Sendable, Equatable {
    let required: Bool
    let status: String
    var isActive: Bool { !required || status == "active" }
}

nonisolated struct BackendCoordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

nonisolated struct BackendMedia: Codable, Sendable {
    let id: UUID
    let mimeType: String
    let byteCount: Int
    let path: String
}

nonisolated struct BackendPlace: Codable, Sendable {
    let id: UUID
    let sourceId: UUID?
    let name: String
    let category: String
    let coordinate: BackendCoordinate
}

nonisolated struct BackendMemory: Codable, Sendable {
    let id: UUID
    let ownerId: UUID
    var owner: BackendUser
    let kind: String
    let visibility: String
    let location: BackendCoordinate
    let caption: String
    var place: BackendPlace?
    let media: [BackendMedia]
    let createdAt: Date
    let publishedAt: Date?
    let expiresAt: Date
    var moderationStatus: String? = nil
}

nonisolated struct BackendPlaceInput: Codable, Sendable {
    let name: String
    let category: String
    var coordinate: BackendCoordinate? = nil
    var sourceId: UUID? = nil
}

nonisolated struct BackendMemoryInput: Codable, Sendable {
    let id: UUID
    let kind: String
    let visibility: String
    let location: BackendCoordinate
    var caption: String? = nil
    var mediaIds: [UUID] = []
    var place: BackendPlaceInput? = nil
    var placeId: UUID? = nil
    var capturedAt: String? = nil
}

/// HTTPS-only outside explicit Debug loopback development. Never follows redirects.
@MainActor
final class BackendAPI {
    let baseURL: URL
    var token: String?
    var onAccessDenied: ((String) -> Void)?
    var onUnauthorized: (() -> Void)?
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://127.0.0.1:8787")!, session: URLSession? = nil) {
#if DEBUG
        let allowLocal = true
#else
        let allowLocal = false
#endif
        precondition(BackendDeploymentConfiguration.validatedURL(baseURL.absoluteString, allowLocal: allowLocal) != nil)
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration,
            delegate: BackendNoRedirectDelegate(), delegateQueue: nil)
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        // Two formatters per response, not two allocations for every timestamp.
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let seconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            if let date = try? fractional.parse(text) { return date }
            guard let date = try? seconds.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: value.codingPath, debugDescription: "Invalid timestamp"))
            }
            return date
        }
        return decoder
    }

    func authenticate(handle: String, password: String, register: Bool) async throws -> BackendAuth {
        struct Credentials: Encodable { let handle: String; let password: String }
        return try await json("/v1/auth/\(register ? "register" : "login")", method: "POST",
                              body: JSONEncoder().encode(Credentials(handle: handle, password: password)))
    }

    func appleChallenge() async throws -> BackendAppleChallenge {
        try await json("/v1/auth/apple/challenge", method: "POST", body: Data("{}".utf8))
    }

    func authenticateWithApple(challengeID: UUID, identityToken: String, authorizationCode: String? = nil) async throws -> BackendAuth {
        struct Credential: Encodable { let challengeId: UUID; let identityToken: String; let authorizationCode: String? }
        return try await json("/v1/auth/apple", method: "POST",
            body: JSONEncoder().encode(Credential(challengeId: challengeID, identityToken: identityToken, authorizationCode: authorizationCode)))
    }

    func authProviders() async throws -> BackendAuthProviders {
        try await json("/v1/auth/providers")
    }

    func socialChallenge(provider: String) async throws -> BackendSocialChallenge {
        guard ["google", "wechat"].contains(provider) else {
            throw BackendClientError.message("Unsupported sign-in provider.")
        }
        return try await json("/v1/auth/\(provider)/challenge", method: "POST", body: Data("{}".utf8))
    }

    func authenticateWithSocial(provider: String, challengeID: UUID, code: String, state: String? = nil) async throws -> BackendAuth {
        guard ["google", "wechat"].contains(provider) else {
            throw BackendClientError.message("Unsupported sign-in provider.")
        }
        struct Credential: Encodable { let challengeId: UUID; let code: String; let state: String? }
        return try await json("/v1/auth/\(provider)", method: "POST",
            body: JSONEncoder().encode(Credential(challengeId: challengeID, code: code, state: state)))
    }

    func me() async throws -> BackendUser {
        nonisolated struct Response: Decodable, Sendable { let user: BackendUser }
        let response: Response = try await json("/v1/me")
        return response.user
    }

    func profile(userID: UUID) async throws -> BackendUser {
        nonisolated struct Response: Decodable, Sendable { let user: BackendUser }
        let response: Response = try await json("/v1/users/\(userID.uuidString)")
        return response.user
    }

    func updateProfile(handle: String, avatarMediaID: UUID? = nil) async throws -> BackendUser {
        struct Input: Encodable { let handle: String; let avatarMediaId: UUID? }
        nonisolated struct Response: Decodable, Sendable { let user: BackendUser }
        let response: Response = try await json("/v1/me", method: "PATCH",
            body: JSONEncoder().encode(Input(handle: handle, avatarMediaId: avatarMediaID)))
        return response.user
    }

    func logout() async throws { _ = try await request("/v1/auth/logout", method: "POST") }

    func betaAccess() async throws -> BackendBetaAccess { try await json("/v1/beta/access") }

    func redeemInvite(_ code: String) async throws {
        struct Input: Encodable { let code: String }
        _ = try await request("/v1/beta/redeem", method: "POST", body: JSONEncoder().encode(Input(code: code)))
    }

    func deleteAccount() async throws { _ = try await request("/v1/me", method: "DELETE") }

    func report(memoryID: UUID, reason: String) async throws {
        struct Input: Encodable { let memoryId: UUID; let reason: String }
        _ = try await request("/v1/reports", method: "POST", body: JSONEncoder().encode(Input(memoryId: memoryID, reason: reason)))
    }

    func block(userID: UUID) async throws {
        struct Input: Encodable { let userId: UUID }
        _ = try await request("/v1/blocks", method: "POST", body: JSONEncoder().encode(Input(userId: userID)))
    }

    func allMemories(path: String) async throws -> [BackendMemory] {
        nonisolated struct Page: Decodable, Sendable { let items: [BackendMemory]; let nextCursor: String? }
        var cursor: String?
        var seen = Set<String>()
        var result: [BackendMemory] = []
        repeat {
            var components = URLComponents(string: path)!
            var query = components.queryItems ?? []
            query.append(URLQueryItem(name: "limit", value: "100"))
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = query
            let page: Page = try await json(components.string!)
            result.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted {
                throw BackendClientError.message("The server returned a repeated page. Please retry.")
            }
        } while cursor != nil
        return result
    }

    func publish(_ input: BackendMemoryInput) async throws -> BackendMemory {
        try await json("/v1/memories", method: "POST", body: JSONEncoder().encode(input))
    }

    func uploadPhoto(_ data: Data, mimeType: String = "image/jpeg", idempotencyKey: UUID? = nil) async throws -> BackendMedia {
        try await uploadMedia(data, mimeType: mimeType, idempotencyKey: idempotencyKey)
    }

    func uploadMedia(_ data: Data, mimeType: String, idempotencyKey: UUID? = nil) async throws -> BackendMedia {
        let bytes = try await request("/v1/media", method: "POST", body: data, contentType: mimeType,
                                      idempotencyKey: idempotencyKey, timeout: mimeType == "video/mp4" ? 240 : 30)
        return try Self.decoder.decode(BackendMedia.self, from: bytes)
    }

    func downloadMedia(_ media: BackendMedia) async throws -> Data {
        guard media.path == "/v1/media/\(media.id.uuidString.lowercased())" else {
            throw BackendClientError.message("The media address is invalid.")
        }
        return try await request(media.path, timeout: media.mimeType == "video/mp4" ? 240 : 30)
    }

    func hideArchive(kind: String, id: UUID) async throws {
        struct Input: Encodable { let kind: String; let id: UUID }
        _ = try await request("/v1/me/archive/hide", method: "POST",
                              body: JSONEncoder().encode(Input(kind: kind, id: id)))
    }

    func makeMemoryPrivate(id: UUID) async throws -> BackendMemory {
        try await json("/v1/memories/\(id.uuidString)", method: "PATCH",
                       body: Data("{\"visibility\":\"private\"}".utf8))
    }

    func deleteMemory(id: UUID, cancelPending: Bool = false) async throws {
        _ = try await request("/v1/memories/\(id.uuidString)\(cancelPending ? "?cancelPending=true" : "")", method: "DELETE")
    }

    func deleteMedia(id: UUID) async throws {
        _ = try await request("/v1/media/\(id.uuidString)", method: "DELETE")
    }

    func cancelPhotoUpload(key: UUID) async throws {
        _ = try await request("/v1/media/by-upload-key/\(key.uuidString)", method: "DELETE")
    }

    private func json<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await request(path, method: method, body: body)
        return try await Self.decode(data)
    }

    @concurrent
    private static func decode<T: Decodable & Sendable>(_ data: Data) async throws -> T {
        try Task.checkCancellation()
        return try Self.decoder.decode(T.self, from: data)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         contentType: String = "application/json", idempotencyKey: UUID? = nil,
                         timeout: TimeInterval = 30) async throws -> Data {
        guard path.hasPrefix("/v1/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port, url.scheme == baseURL.scheme else {
            throw BackendClientError.message("Invalid server address.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw BackendClientError.message(baseURL.scheme == "https"
                ? "Couldn't connect to MapTalk. Check your connection and try again."
                : "Cannot reach the local server. Start it on this Mac, then retry.")
        }
        guard let http = response as? HTTPURLResponse else { throw BackendClientError.message("Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { struct Detail: Decodable { let code: String?; let message: String }; let error: Detail }
            if http.statusCode == 401, !path.hasPrefix("/v1/auth/") {
                onUnauthorized?()
                throw BackendClientError.unauthorized
            }
            let detail = try? JSONDecoder().decode(Failure.self, from: data)
            if http.statusCode == 403, let code = detail?.error.code,
               ["beta_access_required", "beta_access_revoked"].contains(code) {
                onAccessDenied?(code == "beta_access_revoked" ? "revoked" : "pending")
            }
            throw BackendClientError.http(status: http.statusCode,
                                          message: detail?.error.message ?? "Could not save. Please retry.")
        }
        return data
    }
}

/// A moved endpoint must be configured explicitly, never receive an account's
/// token or a private upload through an automatic 30x redirect.
private final class BackendNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

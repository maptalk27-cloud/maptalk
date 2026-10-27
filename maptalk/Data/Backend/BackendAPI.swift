import Foundation
import CryptoKit

enum BackendClientError: LocalizedError {
    case message(String)
    case unauthorized
    case http(status: Int, message: String, code: String? = nil)
    case publishPending(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        case .unauthorized: return "Your session has expired. Sign out and sign in again."
        case let .http(_, message, _): return message
        case let .publishPending(message):
            return "\(message) Your draft is locked because this save isn't confirmed. Retry the same save, or close and check MyMap."
        }
    }

    /// A timeout or conflict may follow an already committed request. Only an
    /// explicit refusal known not to have saved the record unlocks editing.
    var confirmsPublishRejection: Bool {
        switch self {
        case .unauthorized: return true
        case let .http(status, _, _): return [400, 403, 404, 410, 413, 415, 422, 429].contains(status)
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

nonisolated struct BackendUploadStatus: Codable, Sendable {
    let uploadID: UUID
    let mimeType: String
    let byteCount: Int
    let receivedBytes: Int
    let chunkSize: Int
    let media: BackendMedia?
}

nonisolated struct BackendPlace: Codable, Sendable {
    let id: UUID
    let sourceId: UUID?
    let name: String
    let category: String
    let coordinate: BackendCoordinate
    var directoryKind: String? = nil
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

nonisolated struct BackendMemoryPage: Decodable, Sendable {
    let items: [BackendMemory]
    let nextCursor: String?
}

nonisolated struct BackendPlaceInput: Codable, Sendable {
    let name: String
    let category: String
    var coordinate: BackendCoordinate? = nil
    var sourceId: UUID? = nil
    var directoryKind: String? = nil
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

nonisolated enum BackendCommentTarget: Hashable, Sendable {
    case memory(UUID)
    case place(UUID)

    var path: String {
        switch self {
        case let .memory(id): return "/v1/memories/\(id.uuidString)/comments"
        case let .place(id): return "/v1/places/\(id.uuidString)/comments"
        }
    }
}

nonisolated struct BackendComment: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let text: String
    let createdAt: Date
    let author: BackendUser
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

    static let placeHistoryPageSize = 12

    /// A deliberate place visit fetches one bounded page, never all history.
    func placeMemories(placeID: UUID, cursor: String? = nil) async throws -> BackendMemoryPage {
        var components = URLComponents(string: "/v1/places/\(placeID.uuidString)/memories")!
        components.queryItems = [URLQueryItem(name: "limit", value: String(Self.placeHistoryPageSize))]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: BackendMemoryPage = try await json(components.string!)
        guard page.items.count <= Self.placeHistoryPageSize else {
            throw BackendClientError.message("Couldn't load these visits. Please try again.")
        }
        return page
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

    /// The server's acknowledged offset is authoritative after every retry or
    /// process restart. A lost PATCH response never makes us resend the clip.
    /// Keep the ordinary no-redirect session: background URLSession ignores
    /// redirect delegates and must not receive our bearer token/private media.
    func uploadVideo(at file: URL, idempotencyKey: UUID,
                     checkActive: @MainActor () throws -> Void = {},
                     onProgress: @MainActor (Double) -> Void = { _ in },
                     onProcessing: @MainActor () -> Void = {}) async throws -> BackendMedia {
        let source = try await Self.videoUploadMetadata(at: file)
        try Task.checkCancellation()
        try checkActive()
        let path = "/v1/media/uploads/\(idempotencyKey.uuidString.lowercased())"
        struct Input: Encodable { let mimeType: String; let byteCount: Int; let sha256: String }
        var status: BackendUploadStatus
        do {
            status = try await json(path, method: "PUT", body: JSONEncoder().encode(
                Input(mimeType: "video/mp4", byteCount: source.bytes, sha256: source.hash)))
        } catch let error as BackendClientError {
            if case .http(status: 404, message: _, code: _) = error {
                // An older server cannot resume. Preserve the local clip until
                // the compatible server is deployed, rather than uploading it
                // all over again through the legacy endpoint.
                throw BackendClientError.message("Video upload is waiting for a server update. Your video is saved on this phone.")
            }
            throw error
        }
        try validateUpload(status, id: idempotencyKey, bytes: source.bytes)
        onProgress(Double(status.receivedBytes) / Double(source.bytes))
        if let media = status.media { return media }
        while status.receivedBytes < source.bytes {
            try Task.checkCancellation()
            try checkActive()
            let offset = status.receivedBytes
            let count = min(status.chunkSize, source.bytes - offset)
            let chunk = try await Self.videoUploadChunk(at: file, offset: offset, count: count)
            try Task.checkCancellation()
            try checkActive()
            let response = try await request(path, method: "PATCH", body: chunk,
                contentType: "application/octet-stream", timeout: 90,
                additionalHeaders: ["Upload-Offset": String(offset)])
            let acknowledged: BackendUploadStatus = try await Self.decode(response)
            try validateUpload(acknowledged, id: idempotencyKey, bytes: source.bytes)
            guard acknowledged.receivedBytes >= offset + count else {
                throw BackendClientError.message("Video upload paused before the server confirmed this part. It will retry automatically.")
            }
            status = acknowledged
            onProgress(Double(status.receivedBytes) / Double(source.bytes))
            if let media = status.media { return media }
        }
        try Task.checkCancellation()
        try checkActive()
        onProcessing()
        let completedBytes = try await request(path + "/complete", method: "POST", body: Data("{}".utf8), timeout: 240)
        let completed: BackendUploadStatus = try await Self.decode(completedBytes)
        try validateUpload(completed, id: idempotencyKey, bytes: source.bytes)
        guard let media = completed.media else {
            throw BackendClientError.message("Your video is still being prepared. It will retry automatically.")
        }
        return media
    }

    private func validateUpload(_ value: BackendUploadStatus, id: UUID, bytes: Int) throws {
        guard value.uploadID == id, value.mimeType == "video/mp4", value.byteCount == bytes,
              value.receivedBytes >= 0, value.receivedBytes <= bytes,
              value.chunkSize > 0, value.chunkSize <= 512 * 1_024,
              value.media == nil || (value.receivedBytes == bytes && value.media?.mimeType == "video/mp4") else {
            throw BackendClientError.message("The server returned an invalid video upload status. Your video is still saved on this phone.")
        }
    }

    @concurrent
    private static func videoUploadMetadata(at file: URL) async throws -> (bytes: Int, hash: String) {
        guard file.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= PublishVideoNormalizer.maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var read = 0
        while let chunk = try handle.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            read += chunk.count
            guard read <= bytes else { throw CocoaError(.fileReadCorruptFile) }
            hash.update(data: chunk)
        }
        guard read == bytes else { throw CocoaError(.fileReadCorruptFile) }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    @concurrent
    private static func videoUploadChunk(at file: URL, offset: Int, count: Int) async throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return data
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

    func updateMemoryCaption(id: UUID, caption: String) async throws -> BackendMemory {
        struct Input: Encodable { let caption: String }
        return try await json("/v1/memories/\(id.uuidString)", method: "PATCH",
                              body: JSONEncoder().encode(Input(caption: caption)))
    }

    func comments(for target: BackendCommentTarget) async throws -> [BackendComment] {
        nonisolated struct Page: Decodable, Sendable {
            let items: [BackendComment]
            let nextCursor: String?
        }
        let page: Page = try await json("\(target.path)?limit=100")
        return page.items
    }

    func addComment(to target: BackendCommentTarget, text: String, requestID: UUID) async throws -> BackendComment {
        struct Input: Encodable { let id: UUID; let text: String }
        return try await json(target.path, method: "POST",
            body: JSONEncoder().encode(Input(id: requestID, text: text)))
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
                         timeout: TimeInterval = 30, additionalHeaders: [String: String] = [:]) async throws -> Data {
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
        for (name, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
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
                                          message: detail?.error.message ?? "Could not save. Please retry.",
                                          code: detail?.error.code)
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

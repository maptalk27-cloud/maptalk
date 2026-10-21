import CryptoKit
import Foundation

/// Mirror the account-and-server boundary rather than asserting that logout
/// removes the parent directory shared by another configured backend.
func backendMediaCacheDirectory(userID: UUID, baseURL: URL) -> URL {
    let server = SHA256.hash(data: Data(baseURL.absoluteString.utf8))
        .prefix(12).map { String(format: "%02x", $0) }.joined()
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BackendMedia/\(userID.uuidString)/\(server)", isDirectory: true)
}

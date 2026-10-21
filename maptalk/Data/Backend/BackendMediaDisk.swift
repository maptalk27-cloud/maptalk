import Foundation

/// File IO runs on the concurrent executor. The short lock coordinates only
/// account lifetime with writes, preventing a late download after sign-out.
nonisolated final class BackendMediaDisk: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var active = true

    init(directory: URL) { self.directory = directory }

    @concurrent
    func cachedURL(for id: UUID, mimeType: String = "image/jpeg") async throws -> URL? {
        try Task.checkCancellation()
        return try lock.withLock {
            guard active else { throw CancellationError() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(for: id, mimeType: mimeType)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    @concurrent
    func write(_ data: Data, for id: UUID, mimeType: String = "image/jpeg") async throws -> URL {
        try Task.checkCancellation()
        let url = try lock.withLock {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(for: id, mimeType: mimeType)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            return url
        }
        if mimeType == "video/mp4" {
            // Preview failure must not discard an otherwise playable download.
            if let poster = try? await PublishVideoNormalizer.posterJPEG(at: url) {
                try Task.checkCancellation()
                try lock.withLock {
                    try Task.checkCancellation()
                    guard active else { throw CancellationError() }
                    try poster.write(to: posterURL(for: id),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
        }
        try Task.checkCancellation()
        return try lock.withLock {
            guard active else { throw CancellationError() }
            return url
        }
    }

    @concurrent
    func cachedPosterURL(for id: UUID) async throws -> URL? {
        try lock.withLock {
            guard active else { throw CancellationError() }
            let url = posterURL(for: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func invalidate() {
        lock.withLock {
            active = false
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Removing a post must also remove its account-scoped cached bytes. A
    /// cancelled writer cannot recreate them after this lock is released.
    func remove(_ ids: Set<UUID>) {
        lock.withLock {
            for id in ids {
                try? FileManager.default.removeItem(at: fileURL(for: id))
                try? FileManager.default.removeItem(at: fileURL(for: id, mimeType: "video/mp4"))
                try? FileManager.default.removeItem(at: posterURL(for: id))
            }
        }
    }

    private func fileURL(for id: UUID, mimeType: String = "image/jpeg") -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(mimeType == "video/mp4" ? "mp4" : "image")
    }

    private func posterURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("poster.jpg")
    }
}

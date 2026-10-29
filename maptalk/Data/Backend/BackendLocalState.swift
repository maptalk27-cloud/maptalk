import Foundation

enum PendingPublicationStatus: Equatable {
    case waiting
    case uploading
    case processing
    case failed(String)
}

nonisolated struct QueuedPublication: Codable, Sendable, Identifiable {
    struct Photo: Codable, Sendable {
        let id: UUID
        var uploaded: BackendMedia?
        // Keep the persisted `photos` key and make the new field optional so
        // an app update can still resume every pre-video photo publication.
        var mimeType: String? = nil
        var contentType: String { mimeType ?? "image/jpeg" }
        var isVideo: Bool { contentType == "video/mp4" }
    }
    struct ClusterPreview: Codable, Sendable {
        var mediaID: UUID
        let file: Photo
    }
    var id: UUID { input.id }
    var input: BackendMemoryInput
    var record: BackendMemory
    var photos: [Photo]
    var attemptedPost = false
    var cancelled = false
    var failure: String?
    // Optional so every pre-cluster queue remains decodable. These are local
    // preview copies of selected sources, never another upload or quota charge.
    var clusterPreviews: [ClusterPreview]? = nil
}

nonisolated struct BackendLocalState: Codable, Sendable {
    let ownerID: UUID
    let server: String
    var user: BackendUser
    var mine: [BackendMemory] = []
    var profile: [BackendMemory] = []
    var feed: [BackendMemory] = []
    var queued: [QueuedPublication] = []
    var deleted: Set<UUID> = []
    var privateOverrides: [BackendMemory] = []
    var blocked: Set<UUID> = []
    // Missing in older caches. These are map-only negative lookups, not post
    // tombstones: a successful fresh public read can make an ID eligible again.
    var mapExcludedMemoryIDs: Set<UUID>? = nil
}

/// Account- and server-scoped durable metadata. No tokens are stored here.
/// A single short file lock orders atomic replacements against logout, while
/// revision numbers prevent a slow old refresh from overwriting a newer queue.
nonisolated final class BackendLocalStateDisk: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var active = true
    private var revision = 0

    init(directory: URL) { self.directory = directory }

    @concurrent
    func load() async throws -> BackendLocalState? {
        try lock.withLock {
            guard active else { throw CancellationError() }
            let url = directory.appendingPathComponent("state.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(BackendLocalState.self, from: Data(contentsOf: url))
        }
    }

    @concurrent
    func save(_ state: BackendLocalState, revision incoming: Int) async throws {
        let data = try JSONEncoder().encode(state)
        try lock.withLock {
            guard active else { throw CancellationError() }
            guard incoming >= revision else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resource = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
            try data.write(to: directory.appendingPathComponent("state.json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            revision = incoming
        }
    }

    func photoURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg") }

    func mediaURL(_ item: QueuedPublication.Photo) -> URL {
        item.isVideo ? directory.appendingPathComponent(item.id.uuidString).appendingPathExtension("mp4") : photoURL(item.id)
    }

    func posterURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("poster.jpg")
    }

    @concurrent
    func copyMedia(_ sources: [URL], items: [QueuedPublication.Photo], posters: [URL?]) async throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            guard sources.count == items.count, posters.count == items.count else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var copied: [URL] = []
            do {
                for (index, pair) in zip(sources, items).enumerated() {
                    let (source, item) = pair
                    try Task.checkCancellation()
                    guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                    guard let bytes = attributes[.size] as? NSNumber,
                          bytes.intValue > 0, bytes.intValue <= (item.isVideo ? 20 : 10) * 1_024 * 1_024 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let destination = mediaURL(item)
                    try FileManager.default.copyItem(at: source, to: destination)
                    copied.append(destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                         ofItemAtPath: destination.path)
                    if item.isVideo, let poster = posters[index], poster.isFileURL {
                        let posterBytes = try poster.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard posterBytes > 0, posterBytes <= 10 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                        let destination = posterURL(item.id)
                        try FileManager.default.copyItem(at: poster, to: destination)
                        copied.append(destination)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                             ofItemAtPath: destination.path)
                    }
                }
            } catch {
                copied.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
        }
    }

    func removePhotos(_ ids: [UUID]) {
        lock.withLock {
            for id in ids {
                try? FileManager.default.removeItem(at: photoURL(id))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4"))
                try? FileManager.default.removeItem(at: posterURL(id))
            }
        }
    }

    func invalidate(preserving state: BackendLocalState? = nil) {
        lock.withLock {
            active = false
            if let state, !state.queued.isEmpty {
                if let data = try? JSONEncoder().encode(state) {
                    try? data.write(to: directory.appendingPathComponent("state.json"),
                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            } else {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}

import CoreLocation
import Combine
import Foundation
import Testing
import UIKit
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendClusterTests {
    private let location = CLLocation(latitude: 37.3, longitude: -122)

    @Test
    func captionEditorCanRemoveCaptionWhenAClusterKeepsTheReelNonempty() {
        let fixture = ClusterFixture()
        var parent = fixture.memory(caption: "Caption to remove")
        #expect(!BackendCaptionEditor.canSave(caption: "", for: parent, isSaving: false))
        parent.cluster = .init(id: parent.id, title: "Trip", members: [fixture.memory(caption: "A memory")])
        #expect(BackendCaptionEditor.canSave(caption: " \n ", for: parent, isSaving: false))
        #expect(!BackendCaptionEditor.canSave(caption: "", for: parent, isSaving: true))
        #expect(!BackendCaptionEditor.canSave(caption: parent.caption, for: parent, isSaving: false))
        #expect(!BackendCaptionEditor.canSave(caption: String(repeating: "a", count: 2_201), for: parent, isSaving: false))
    }

    @Test
    func legacyRequestsAndQueuesKeepTheirEncodingAndFingerprint() throws {
        let fixture = ClusterFixture()
        let record = fixture.memory(caption: "Existing")
        let input = BackendMemoryInput(id: record.id, kind: "reel", visibility: "private", location: record.location)
        let queue = QueuedPublication(input: input, record: record, photos: [])
        let bytes = try JSONEncoder().encode(queue)
        let decoded = try JSONDecoder().decode(QueuedPublication.self, from: bytes)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((json["input"] as? [String: Any])?["cluster"] == nil)
        #expect((json["record"] as? [String: Any])?["cluster"] == nil)
        #expect(json["clusterPreviews"] == nil)
        #expect(decoded.record.cluster == nil)
        #expect(decoded.input.cluster == nil)
        #expect(decoded.clusterPreviews == nil)
        let legacy = ["reel", "private", "", "", "", "", ""].joined(separator: "\u{0}")
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) == legacy)
        var clustered = input
        clustered.cluster = .init(title: "Trip", memoryIds: [UUID(), UUID()])
        let first = BackendStore.publicationFingerprint(for: clustered, urls: [], contentTypes: [])
        clustered.cluster = .init(title: "Trip", memoryIds: Array(clustered.cluster!.memoryIds.reversed()))
        #expect(BackendStore.publicationFingerprint(for: clustered, urls: [], contentTypes: []) != first)
    }

    @Test
    func folderSelectionFreezesOwnVisitIDsAndOrderAcrossRestart() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        let reel = context.fixture.memory(caption: "Private source")
        let place = context.fixture.place()
        let oldVisit = context.fixture.memory(place: place, age: 200)
        let recentVisit = context.fixture.memory(place: place, age: 20)
        let foreign = context.fixture.memory(place: place, owner: .init(id: UUID(), handle: "other"), visibility: "public")
        context.fixture.seed([reel, oldVisit, recentVisit, foreign])
        try await store.refresh()
        let folder = store.archive.createJourneyFolder(title: "Trip", memberReferences: [.reel(reel.id), .poi(place.id)])
        let parentID = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "", attachments: [], bubbleSource: .folder(folder.id))),
            audience: .livePublic, location: location, requestID: parentID)
        store.archive.deleteJourneyFolder(id: folder.id)
        let preview = try #require(store.journey(for: parentID))
        #expect(preview.title == "Trip")
        #expect(preview.orderedMemberReferences == [.reel(reel.id), .poi(place.id)])
        #expect(preview.pois.first?.checkIns.map(\.id) == [recentVisit.id, oldVisit.id])
        #expect(store.journey(for: parentID, publicOnly: true) == nil)
        #expect(store.feedReels.value.isEmpty)
        let queued = try context.readQueue().first { $0.id == parentID }
        #expect(queued?.input.cluster?.memoryIds == [reel.id, recentVisit.id, oldVisit.id])
        #expect(queued?.record.cluster?.members.contains { $0.id == foreign.id } == false)

        store.clearLocalMedia(preservePendingPublications: true)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privateBubbleCatalog.first?.id == parentID)
        #expect(restored.journey(for: parentID)?.title == "Trip")
        #expect(restored.journey(for: parentID)?.reels.first?.message == "Private source")
        #expect(restored.journey(for: parentID, publicOnly: true) == nil)
    }

    @Test
    func pendingSourceWaitsWithoutPoisoningParentAndRemapsMediaBeforePublish() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let sourceID = UUID()
        let photo = try context.photo()
        _ = try await store.enqueuePublish(.reel(.init(text: "Source", attachments: [.init(kind: .photo(photo))],
            bubbleSource: nil)), audience: .privateMyMap, location: location, requestID: sourceID)
        let parentID = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "", attachments: [],
            bubbleSource: .memories([.reel(sourceID)]))), audience: .livePublic, location: location, requestID: parentID)
        context.fixture.failNextPost(sourceID)
        await store.syncPendingPublications()
        #expect(context.fixture.inputs.map(\.id) == [sourceID])
        #expect(store.pendingPublications[parentID] == .waiting)
        #expect(try context.readQueue().first { $0.id == parentID }?.failure == nil)

        store.clearLocalMedia(preservePendingPublications: true)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        let before = try #require(restored.journey(for: parentID)?.reels.first?.attachments.first)
        guard case let .photo(previewURL) = before.kind else { Issue.record("Missing durable cluster photo"); return }
        #expect(FileManager.default.fileExists(atPath: previewURL.path))
        try await restored.cacheVerifiedIdentity()
        await restored.syncPendingPublications()
        #expect(context.fixture.inputs.map(\.id) == [sourceID, sourceID, parentID])
        #expect(context.fixture.uploadCount == 1, "Cluster previews reuse media; they are never uploaded again")
        #expect(restored.pendingPublications.isEmpty)
        let savedSource = try #require(context.fixture.record(sourceID))
        let bubble = try #require(restored.journey(for: parentID, publicOnly: true))
        #expect(bubble.reels.first?.attachments.map(\.id) == savedSource.media.map(\.id))
        #expect(savedSource.visibility == "private", "Sharing a snapshot must not publish its source")
        #expect(restored.feedReels.value.map(\.id) == [parentID])
        let attachment = try #require(bubble.reels.first?.attachments.first)
        guard case let .photo(url) = attachment.kind else { Issue.record("Missing confirmed photo"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func lostParentResponseRetriesFrozenInputAndDoesNotRebuildSnapshot() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        let source = context.fixture.memory(caption: "Frozen words")
        context.fixture.seed([source])
        try await store.refresh()
        try await store.cacheVerifiedIdentity()
        let parentID = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "", attachments: [],
            bubbleSource: .memories([.reel(source.id)]))), audience: .livePublic, location: location, requestID: parentID)
        context.fixture.loseNextPostResponse(parentID)
        await store.syncPendingPublications()
        context.fixture.replaceCaption(source.id, text: "Later source edit")
        await store.syncPendingPublications()
        let inputs = context.fixture.inputs.filter { $0.id == parentID }
        #expect(inputs.count == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(inputs[0]) == encoder.encode(inputs[1]))
        #expect(store.journey(for: parentID, publicOnly: true)?.reels.first?.message == "Frozen words")
        #expect(store.pendingPublications.isEmpty)
    }

    @Test
    func serverSnapshotsHydrateWithoutLeakingSourcesAndFollowParentWithdrawal() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        let media = context.fixture.seedPhoto()
        var source = context.fixture.memory(caption: "Private snapshot", media: [media])
        let nestedID = UUID()
        source.cluster = .init(id: source.id, title: "Must not nest", members: [
            context.fixture.memory(id: nestedID, caption: "Nested")
        ])
        var parent = context.fixture.memory(caption: "Public parent", visibility: "public")
        parent.cluster = .init(id: parent.id, title: "Trip", members: [source])
        context.fixture.seed([parent]) // Source deliberately absent as a standalone record.
        try await store.refresh()
        #expect(store.issue == nil, "Valid server media paths must hydrate without a swallowed refresh warning")
        #expect(store.feedReels.value.map(\.id) == [parent.id])
        #expect(store.ownedMemories[source.id] == nil)
        let cluster = try #require(store.journey(for: parent.id, publicOnly: true))
        #expect(cluster.reels.first?.capsuleId == nil)
        #expect(cluster.reels.first?.attachments.map(\.id) == [media.id])
        #expect(store.archive.privateBubbleCatalog.first?.id == parent.id)
        #expect(store.archive.publicBubbleCatalog.first?.id == parent.id)
        #expect(store.journey(for: source.id) == nil)
        try await store.makePrivate(memoryID: parent.id)
        #expect(store.journey(for: parent.id, publicOnly: true) == nil)
        #expect(store.journey(for: parent.id)?.reels.first?.message == "Private snapshot")
        #expect(store.archive.publicBubbleCatalog.isEmpty)
        try await store.deletePost(memoryID: parent.id)
        #expect(store.journey(for: parent.id) == nil)
        #expect(store.archive.privateBubbleCatalog.isEmpty)
    }

    @Test
    func sourceDeletionKeepsIndependentSnapshotAndItsCachedMedia() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        let source = context.fixture.memory(caption: "Kept snapshot", media: [context.fixture.seedPhoto()])
        var parent = context.fixture.memory(caption: "Parent", visibility: "public")
        parent.cluster = .init(id: parent.id, title: "Saved", members: [source])
        context.fixture.seed([source, parent])
        try await store.refresh()
        #expect(store.issue == nil)
        try await store.deletePost(memoryID: source.id)
        let snapshot = try #require(store.journey(for: parent.id, publicOnly: true)?.reels.first)
        #expect(snapshot.message == "Kept snapshot")
        let attachment = try #require(snapshot.attachments.first)
        guard case let .photo(url) = attachment.kind else { Issue.record("Missing retained photo"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.ownedMemories[source.id] == nil)
    }

    @Test
    func foreignSourcesAndMoreThanFiftyVisitsAreRejectedBeforeQueueing() async throws {
        let context = ClusterContext()
        defer { context.finish() }
        let store = context.makeStore()
        let foreign = context.fixture.memory(owner: .init(id: UUID(), handle: "other"), visibility: "public")
        let place = context.fixture.place()
        context.fixture.seed([foreign] + (0..<51).map { context.fixture.memory(place: place, age: Double($0)) })
        try await store.refresh()
        for reference in [JourneyFolder.MemberReference.reel(foreign.id), .poi(place.id)] {
            do {
                _ = try await store.enqueuePublish(.reel(.init(text: "", attachments: [], bubbleSource: .memories([reference]))),
                    audience: .livePublic, location: location, requestID: UUID())
                Issue.record("An invalid cluster must not enter the queue")
            } catch {
                #expect(store.pendingPublications.isEmpty)
                #expect(context.fixture.inputs.isEmpty)
            }
        }
    }
}

@MainActor
private final class ClusterContext {
    let fixture = ClusterFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-test-\(UUID())")
    let session: URLSession
    let api: BackendAPI
    private var stores: [BackendStore] = []

    init() {
        let respondingFixture = fixture
        ClusterURLProtocol.install { respondingFixture.respond(to: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClusterURLProtocol.self]
        session = URLSession(configuration: config)
        api = BackendAPI(baseURL: URL(string: "https://cluster-test.invalid")!, session: session)
        api.token = "cluster-test-session"
    }

    func makeStore() -> BackendStore {
        let store = BackendStore(user: fixture.user.user, api: api, storageDirectory: directory,
            automaticallySync: false, observesConnectivity: false, retryDelay: { _ in 0.01 })
        stores.append(store)
        return store
    }

    func readQueue() throws -> [QueuedPublication] {
        try JSONDecoder().decode(BackendLocalState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json"))).queued
    }

    func photo() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.jpg")
        try ClusterFixture.photoBytes().write(to: url)
        return url
    }

    func finish() {
        stores.forEach { $0.clearLocalMedia() }
        session.invalidateAndCancel()
        ClusterURLProtocol.install(nil)
        try? FileManager.default.removeItem(at: directory)
        let folders = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendAccounts/\(fixture.user.id.uuidString)")
        try? FileManager.default.removeItem(at: folders)
    }
}

private final class ClusterFixture: @unchecked Sendable {
    let user = BackendUser(id: UUID(), handle: "cluster_owner")
    private let lock = NSLock()
    private var records: [UUID: BackendMemory] = [:]
    private var postInputs: [BackendMemoryInput] = []
    private var media: [UUID: BackendMedia] = [:]
    private var bytes: [UUID: Data] = [:]
    private var uploads = 0
    private var failedPost: UUID?
    private var lostPost: UUID?
    var inputs: [BackendMemoryInput] { lock.withLock { postInputs } }
    var uploadCount: Int { lock.withLock { uploads } }

    func place() -> BackendPlace {
        .init(id: UUID(), sourceId: nil, name: "My place", category: "coffee",
            coordinate: .init(latitude: 37.3, longitude: -122))
    }

    func memory(id: UUID = UUID(), caption: String = "", place: BackendPlace? = nil,
                owner: BackendUser? = nil, visibility: String = "private", age: TimeInterval = 0,
                media: [BackendMedia] = []) -> BackendMemory {
        let author = owner ?? user
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - age)
        return .init(id: id, ownerId: author.id, owner: author, kind: place == nil ? "reel" : "poi",
            visibility: visibility, location: .init(latitude: 37.3, longitude: -122), caption: caption,
            place: place, media: media, createdAt: date, publishedAt: visibility == "public" ? date : nil,
            expiresAt: date.addingTimeInterval(72 * 3600), moderationStatus: "approved")
    }

    func seed(_ values: [BackendMemory]) { lock.withLock { values.forEach { records[$0.id] = $0 } } }
    func record(_ id: UUID) -> BackendMemory? { lock.withLock { records[id] } }
    func failNextPost(_ id: UUID) { lock.withLock { failedPost = id } }
    func loseNextPostResponse(_ id: UUID) { lock.withLock { lostPost = id } }
    func replaceCaption(_ id: UUID, text: String) {
        lock.withLock {
            guard let old = records[id] else { return }
            records[id] = replacement(old, caption: text)
        }
    }

    @MainActor
    static func photoBytes() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.jpegData(compressionQuality: 0.8)!
    }

    @MainActor
    func seedPhoto() -> BackendMedia {
        let data = Self.photoBytes()
        return lock.withLock {
            let value = BackendMedia(id: UUID(), mimeType: "image/jpeg", byteCount: data.count, path: "/unused")
            let result = BackendMedia(id: value.id, mimeType: value.mimeType, byteCount: value.byteCount,
                path: "/v1/media/\(value.id.uuidString.lowercased())")
            media[result.id] = result
            bytes[result.id] = data
            return result
        }
    }

    private func replacement(_ old: BackendMemory, caption: String? = nil, visibility: String? = nil) -> BackendMemory {
        .init(id: old.id, ownerId: old.ownerId, owner: old.owner, kind: old.kind,
            visibility: visibility ?? old.visibility, location: old.location, caption: caption ?? old.caption,
            place: old.place, media: old.media, createdAt: old.createdAt, publishedAt: old.publishedAt,
            expiresAt: old.expiresAt, moderationStatus: old.moderationStatus, cluster: old.cluster)
    }

    func respond(to operation: ClusterURLProtocol) {
        do {
            let response: (Int, Data, Bool) = try lock.withLock {
                let request = operation.request
                let method = request.httpMethod ?? "GET"
                let path = request.url!.path
                if method == "POST", path == "/v1/media" {
                    let data = body(request)
                    let id = UUID()
                    let value = BackendMedia(id: id, mimeType: "image/jpeg", byteCount: data.count,
                        path: "/v1/media/\(id.uuidString.lowercased())")
                    media[id] = value
                    bytes[id] = data
                    uploads += 1
                    return (201, try encode(value), false)
                }
                if method == "POST", path == "/v1/memories" {
                    let input = try JSONDecoder().decode(BackendMemoryInput.self, from: body(request))
                    postInputs.append(input)
                    if failedPost == input.id { failedPost = nil; return (503, Data(), false) }
                    if let previous = records[input.id] { return (200, try encode(previous), false) }
                    let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                    var saved = BackendMemory(id: input.id, ownerId: user.id, owner: user, kind: input.kind,
                        visibility: input.visibility, location: input.location, caption: input.caption ?? "",
                        media: input.mediaIds.compactMap { media[$0] }, createdAt: date,
                        publishedAt: input.visibility == "public" ? date : nil, expiresAt: date.addingTimeInterval(72 * 3600),
                        moderationStatus: "approved")
                    if let cluster = input.cluster {
                        guard cluster.memoryIds.allSatisfy({ records[$0]?.ownerId == user.id }) else {
                            return (404, Data(), false)
                        }
                        saved.cluster = .init(id: input.id, title: cluster.title, members: cluster.memoryIds.compactMap {
                            guard var record = records[$0] else { return nil }
                            record.cluster = nil
                            return record
                        })
                    }
                    records[saved.id] = saved
                    let lose = lostPost == input.id
                    if lose { lostPost = nil }
                    return (201, try encode(saved), lose)
                }
                if path.hasPrefix("/v1/memories/"), let id = UUID(uuidString: String(path.split(separator: "/").last!)) {
                    if method == "DELETE" { records.removeValue(forKey: id); return (204, Data(), false) }
                    if method == "PATCH", let original = records[id] {
                        let input = try JSONDecoder().decode([String: String].self, from: body(request))
                        let saved = replacement(original, caption: input["caption"], visibility: input["visibility"])
                        records[id] = saved
                        return (200, try encode(saved), false)
                    }
                }
                if method == "GET", path.hasPrefix("/v1/media/"),
                   let id = UUID(uuidString: String(path.split(separator: "/").last!)), let data = bytes[id] {
                    return (200, data, false)
                }
                if path == "/v1/me" {
                    struct Identity: Encodable { let user: BackendUser }
                    return (200, try encode(Identity(user: user)), false)
                }
                struct Page: Encodable { let items: [BackendMemory]; let nextCursor: String? = nil }
                let values = Array(records.values).sorted { $0.id.uuidString < $1.id.uuidString }
                if path == "/v1/me/memories" {
                    return (200, try encode(Page(items: values.filter { $0.ownerId == user.id })), false)
                }
                if path == "/v1/feed" || path == "/v1/map/memories" {
                    return (200, try encode(Page(items: values.filter { $0.visibility == "public" })), false)
                }
                if path == "/v1/users/\(user.id.uuidString)/memories" {
                    return (200, try encode(Page(items: values.filter { $0.ownerId == user.id && $0.visibility == "public" })), false)
                }
                return (404, Data(), false)
            }
            if response.2 { operation.client?.urlProtocol(operation, didFailWithError: URLError(.networkConnectionLost)) }
            else { operation.respond(status: response.0, data: response.1) }
        } catch { operation.client?.urlProtocol(operation, didFailWithError: error) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class ClusterURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (ClusterURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (ClusterURLProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

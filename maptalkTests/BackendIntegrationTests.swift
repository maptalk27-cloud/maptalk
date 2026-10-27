import CoreLocation
import Foundation
import Combine
import Testing
@testable import maptalk

/// Opt-in integration checks against a dedicated local backend, never the mock repositories.
/// Set MAPTALK_BACKEND_TEST_URL on the test runner; ordinary unit-test runs make no requests.
@MainActor
@Suite(.serialized)
struct BackendIntegrationTests {
    private let photo = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII="
    )!

    @Test
    func collectionsPersistPerAccountWithoutSeedingMockRecords() throws {
        let ownerID = UUID()
        let otherID = UUID()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendAccounts", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(ownerID.uuidString))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(otherID.uuidString))
        }
        let archive = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        let folder = archive.createJourneyFolder(title: "Weekend")
        let restored = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        #expect(restored.journeyFolders.map(\.id) == [folder.id])
        #expect(restored.privatePOIs.isEmpty && restored.privateReels.isEmpty)
        #expect(restored.legacyJourneyCatalog.isEmpty)
        let other = MyMapArchiveStore(currentUserID: otherID, startsEmpty: true)
        #expect(other.journeyFolders.isEmpty)
        restored.deleteJourneyFolder(id: folder.id)
        #expect(MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true).journeyFolders.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["image/png", "video/mp4"])
    func signOutDuringPhotoDownloadCannotRepopulateCacheOrFeed(mimeType: String) async throws {
        let userID = UUID()
        let recordID = UUID()
        let mediaID = UUID()
        let page = Data("""
        {"items":[{"id":"\(recordID)","ownerId":"\(userID)",
        "owner":{"id":"\(userID)","handle":"logout_test"},"kind":"reel","visibility":"public",
        "location":{"latitude":37.3,"longitude":-122},"caption":"Pending download","place":null,
        "media":[{"id":"\(mediaID)","mimeType":"\(mimeType)","byteCount":\(photo.count),
        "path":"/v1/media/\(mediaID.uuidString.lowercased())"}],
        "createdAt":"2026-10-17T12:00:00Z","publishedAt":"2026-10-17T12:00:00Z",
        "expiresAt":"2026-10-18T12:00:00Z"}],"nextCursor":null}
        """.utf8)
        let (downloads, continuation) = AsyncStream<PausedBackendURLProtocol>.makeStream()
        PausedBackendURLProtocol.install { request in
            if request.request.url?.path.hasPrefix("/v1/media/") == true {
                continuation.yield(request)
            } else if request.request.url?.path == "/v1/me" {
                request.respond(with: Data("{\"user\":{\"id\":\"\(userID)\",\"handle\":\"logout_test\"}}".utf8), contentType: "application/json")
            } else {
                request.respond(with: page, contentType: "application/json")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PausedBackendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(session: session)
        api.token = "isolated-private-media-token"
        let store = BackendStore(user: .init(id: userID, handle: "logout_test", avatarURL: nil), api: api)
        defer {
            store.clearLocalMedia()
            session.invalidateAndCancel()
            continuation.finish()
            PausedBackendURLProtocol.install(nil)
        }
        let operation = Task { try await store.refresh() }
        var iterator = downloads.makeAsyncIterator()
        let pendingDownload = try #require(await iterator.next())
        #expect(pendingDownload.request.value(forHTTPHeaderField: "Authorization") == "Bearer isolated-private-media-token")
        #expect(pendingDownload.request.url?.query == nil)
        let directory = backendMediaCacheDirectory(userID: userID, baseURL: api.baseURL)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(store.archive.privateReels.map(\.id) == [recordID],
                "Metadata should be available while its photo is still downloading")
        store.clearLocalMedia()
        pendingDownload.respond(with: photo, contentType: mimeType)
        do {
            try await operation.value
            Issue.record("A signed-out store must discard a completed in-flight download")
        } catch is CancellationError {
            // The transport succeeded, but the store's account lifetime has ended.
        }
        #expect(!store.isActive)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.archive.privateReels.isEmpty)
        #expect(store.archive.privatePOIs.isEmpty)
        #expect(store.ownPublicReels.isEmpty)
        #expect(store.feedReels.value.isEmpty)
        #expect(store.feedPOIs.value.isEmpty)
        #expect(store.issue == nil)
    }

    @Test
    func signingOutPreservesTheSameUsersCacheOnAnotherBackend() async throws {
        let userID = UUID()
        let firstAPI = BackendAPI(baseURL: URL(string: "http://127.0.0.1:8787")!)
        let otherAPI = BackendAPI(baseURL: URL(string: "http://127.0.0.1:8788")!)
        let user = User(id: userID, handle: "server_scope_test", avatarURL: nil)
        let firstStore = BackendStore(user: user, api: firstAPI, automaticallySync: false)
        let otherStore = BackendStore(user: user, api: otherAPI, automaticallySync: false)
        let firstDirectory = backendMediaCacheDirectory(userID: userID, baseURL: firstAPI.baseURL)
        let otherDirectory = backendMediaCacheDirectory(userID: userID, baseURL: otherAPI.baseURL)
        let firstDisk = BackendMediaDisk(directory: firstDirectory)
        let otherDisk = BackendMediaDisk(directory: otherDirectory)
        defer { firstStore.clearLocalMedia(); otherStore.clearLocalMedia() }
        let mediaID = UUID()
        _ = try await firstDisk.cachedURL(for: mediaID)
        _ = try await otherDisk.cachedURL(for: mediaID)
        let firstPhoto = try await firstDisk.write(Data([1, 2, 3]), for: mediaID)
        let otherPhoto = try await otherDisk.write(Data([4, 5, 6]), for: mediaID)
        #expect(firstPhoto != otherPhoto)
        firstStore.clearLocalMedia()
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(FileManager.default.fileExists(atPath: otherPhoto.path))
        #expect(try Data(contentsOf: otherPhoto) == Data([4, 5, 6]))
        #expect(otherStore.isActive)
    }

    @Test
    func realHTTPAccountsPublishPrivateAndPublicMemoriesWithoutSharingPrivateHistory() async throws {
        guard let address = ProcessInfo.processInfo.environment["MAPTALK_BACKEND_TEST_URL"] else { return }
        let baseURL = try #require(URL(string: address))
        #expect(baseURL.scheme == "http")
        #expect(["127.0.0.1", "localhost"].contains(baseURL.host ?? ""))
        guard baseURL.scheme == "http", ["127.0.0.1", "localhost"].contains(baseURL.host ?? "") else { return }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let aliceAPI = BackendAPI(baseURL: baseURL, session: session)
        let bobAPI = BackendAPI(baseURL: baseURL, session: session)
        let alice = try await register(using: aliceAPI, prefix: "alice")
        let bob = try await register(using: bobAPI, prefix: "bob")
        #expect(alice.user.id != bob.user.id)
        let identity = try await aliceAPI.me()
        #expect(identity.id == alice.user.id)
        #expect(identity.handle == alice.user.handle)

        let privatePhoto = try await aliceAPI.uploadPhoto(photo, mimeType: "image/png")
        let publicPhoto = try await aliceAPI.uploadPhoto(photo, mimeType: "image/png")
        let location = BackendCoordinate(latitude: 37.3688, longitude: -122.0363)
        let landmark = BackendCoordinate(latitude: 37.3689, longitude: -122.0363)
        let sourceID = UUID()
        let place = BackendPlaceInput(name: "Integration café", category: "coffee",
                                      coordinate: landmark, sourceId: sourceID)
        let privateInput = BackendMemoryInput(id: UUID(), kind: "poi", visibility: "private",
            location: location, mediaIds: [privatePhoto.id], place: place)
        let privateVisit = try await aliceAPI.publish(privateInput)
        let publicInput = BackendMemoryInput(id: UUID(), kind: "poi", visibility: "public",
            location: location, mediaIds: [publicPhoto.id], place: place)
        let publicVisit = try await aliceAPI.publish(publicInput)
        let placeID = try #require(publicVisit.place?.id)
        #expect(privateVisit.place?.id == placeID)
        #expect(publicVisit.place?.sourceId == sourceID)
        #expect(publicVisit.owner.id == alice.user.id)
        #expect(publicVisit.owner.handle == alice.user.handle)
        #expect(publicVisit.place?.coordinate.latitude == landmark.latitude)
        #expect(publicVisit.location.latitude == location.latitude)
        #expect(privateVisit.publishedAt == nil)
        #expect(publicVisit.publishedAt != nil)

        // The server reply can be lost: retrying the exact draft must not add another check-in.
        let retried = try await aliceAPI.publish(publicInput)
        #expect(retried.id == publicVisit.id)
        var mine = try await aliceAPI.allMemories(path: "/v1/me/memories")
        #expect(Set(mine.map(\.id)) == Set([privateVisit.id, publicVisit.id]))
        let profilePath = "/v1/users/\(alice.user.id.uuidString)/memories"
        let publicProfile = try await bobAPI.allMemories(path: profilePath)
        #expect(publicProfile.map(\.id) == [publicVisit.id])
        let bobsArchive = try await bobAPI.allMemories(path: "/v1/me/memories")
        #expect(bobsArchive.isEmpty)
        let ownPhotoBytes = try await aliceAPI.downloadMedia(privatePhoto)
        let sharedPhotoBytes = try await bobAPI.downloadMedia(publicPhoto)
        #expect(ownPhotoBytes == photo)
        #expect(sharedPhotoBytes == photo)
        let forbiddenPhoto = try? await bobAPI.downloadMedia(privatePhoto)
        #expect(forbiddenPhoto == nil)
        let unauthorizedAPI = BackendAPI(baseURL: baseURL, session: session)
        let unauthenticatedPhoto = try? await unauthorizedAPI.downloadMedia(publicPhoto)
        #expect(unauthenticatedPhoto == nil)

        let privateReel = try await aliceAPI.publish(.init(id: UUID(), kind: "reel", visibility: "private",
            location: location, caption: "A private draft"))
        let publicReel = try await aliceAPI.publish(.init(id: UUID(), kind: "reel", visibility: "public",
            location: location, caption: "A public memory"))
        let store = BackendStore(user: alice.user.user, api: aliceAPI)
        let bobStore = BackendStore(user: bob.user.user, api: bobAPI)
        defer { store.clearLocalMedia(); bobStore.clearLocalMedia() }
        try await store.refresh()
        try await bobStore.refresh()
        let archivedPlace = try #require(store.archive.privatePOIs.first { $0.id == placeID })
        #expect(store.archive.privatePOIs.count == 1)
        #expect(store.canonicalPlaceID(for: sourceID) == placeID)
        #expect(Set(archivedPlace.checkIns.map(\.id)) == Set([privateVisit.id, publicVisit.id]))
        let privateCheckIn = try #require(archivedPlace.checkIns.first { $0.id == privateVisit.id })
        let publicCheckIn = try #require(archivedPlace.checkIns.first { $0.id == publicVisit.id })
        #expect(privateCheckIn.publishedAt == nil)
        #expect(publicCheckIn.publishedAt == publicVisit.publishedAt)
        #expect(publicCheckIn.activityDate == publicVisit.publishedAt)
        #expect(Set(store.archive.privateReels.map(\.id)) == Set([privateReel.id, publicReel.id]))
        #expect(store.ownPublicPOIs.first { $0.id == placeID }?.checkIns.map(\.id) == [publicVisit.id])
        #expect(store.ownPublicReels.map(\.id) == [publicReel.id])
        #expect(bobStore.archive.privatePOIs.isEmpty)
        #expect(bobStore.feedPOIs.value.first { $0.id == placeID }?.checkIns.map(\.id) == [publicVisit.id])
        #expect(bobStore.user(for: alice.user.id)?.handle == alice.user.handle)

        // A second check-in through an already-rendered card must use its canonical server place.
        let result = try await store.publish(.place(.init(target: .existing(archivedPlace), media: nil)),
            audience: .privateMyMap,
            location: CLLocation(latitude: location.latitude, longitude: location.longitude), requestID: UUID())
        guard case let .poi(revisitedPlace) = result else {
            Issue.record("A POI draft must return a POI result")
            return
        }
        #expect(revisitedPlace.id == placeID)
        #expect(store.archive.privatePOIs.count == 1)
        #expect(store.archive.privatePOIs.first?.checkIns.count == 3)

        // Removing from MyMap is a private organization action, not an unpublish action.
        try await store.hideFromArchive(.poi(placeID))
        try await aliceAPI.hideArchive(kind: "reel", id: publicReel.id)
        try await store.refresh()
        #expect(store.archive.privatePOIs.isEmpty)
        #expect(store.archive.privateReels.map(\.id) == [privateReel.id])
        #expect(store.ownPublicPOIs.first { $0.id == placeID }?.checkIns.map(\.id) == [publicVisit.id])
        #expect(store.ownPublicReels.map(\.id) == [publicReel.id])
        let afterHide = try await bobAPI.allMemories(path: profilePath)
        #expect(Set(afterHide.map(\.id)) == Set([publicVisit.id, publicReel.id]))
        let stillPublicPhoto = try await bobAPI.downloadMedia(publicPhoto)
        #expect(stillPublicPhoto == photo)

        // Recreating the adapter reloads persisted server state, without the old in-memory archive.
        let reloaded = BackendStore(user: alice.user.user, api: aliceAPI)
        defer { reloaded.clearLocalMedia() }
        try await reloaded.refresh()
        #expect(reloaded.archive.privatePOIs.isEmpty)
        #expect(reloaded.archive.privateReels.map(\.id) == [privateReel.id])
        _ = try await aliceAPI.publish(publicInput)
        mine = try await aliceAPI.allMemories(path: "/v1/me/memories")
        #expect(mine.map(\.id) == [privateReel.id], "Retry must not undo a later archive hide")

        // Publishing an earlier private check-in keeps capture time but starts a new feed clock.
        var publishLater = URLRequest(url: baseURL.appendingPathComponent("v1/memories/\(privateVisit.id.uuidString)"))
        publishLater.httpMethod = "PATCH"
        publishLater.setValue("Bearer \(alice.token)", forHTTPHeaderField: "Authorization")
        publishLater.setValue("application/json", forHTTPHeaderField: "Content-Type")
        publishLater.httpBody = Data("{\"visibility\":\"public\"}".utf8)
        let (publishedData, publishedResponse) = try await session.data(for: publishLater)
        #expect((publishedResponse as? HTTPURLResponse)?.statusCode == 200)
        let publishedLater = try BackendAPI.decoder.decode(BackendMemory.self, from: publishedData)
        let publicationTime = try #require(publishedLater.publishedAt)
        #expect(publishedLater.createdAt == privateVisit.createdAt)
        #expect(publicationTime > privateVisit.createdAt)
        #expect(publishedLater.expiresAt.timeIntervalSince(publicationTime) == StoryReadKeys.freshWindow)
        try await reloaded.refresh()
        #expect(reloaded.archive.privatePOIs.isEmpty, "Changing visibility must not undo archive hiding")
        let promotedCheckIn = try #require(reloaded.ownPublicPOIs.first { $0.id == placeID }?
            .checkIns.first { $0.id == privateVisit.id })
        #expect(promotedCheckIn.createdAt == privateVisit.createdAt)
        #expect(promotedCheckIn.publishedAt == publicationTime)
        #expect(promotedCheckIn.activityDate == publicationTime)

        // Real HTTP permission and withdrawal checks. A grouped POI is not
        // the mutation target: withdraw only this one person's check-in.
        let forbiddenWithdrawal = try? await bobAPI.makeMemoryPrivate(id: publicVisit.id)
        #expect(forbiddenWithdrawal == nil)
        let beforeWithdrawal = try await bobAPI.allMemories(path: profilePath)
        #expect(beforeWithdrawal.contains { $0.id == publicVisit.id })
        try await reloaded.makePrivate(memoryID: publicVisit.id)
        let afterWithdrawal = try await bobAPI.allMemories(path: profilePath)
        #expect(!afterWithdrawal.contains { $0.id == publicVisit.id })
        #expect(afterWithdrawal.contains { $0.id == privateVisit.id }, "Other public visits at this landmark must remain")
        let withdrawnPhoto = try? await bobAPI.downloadMedia(publicPhoto)
        #expect(withdrawnPhoto == nil)
        let ownerStillHasPhoto = try await aliceAPI.downloadMedia(publicPhoto)
        #expect(ownerStillHasPhoto == photo)

        do {
            try await bobAPI.deleteMemory(id: publicReel.id)
            Issue.record("Another account must not delete this Reel")
        } catch { }
        try await reloaded.deletePost(memoryID: publicReel.id)
        let afterDelete = try await bobAPI.allMemories(path: profilePath)
        #expect(!afterDelete.contains { $0.id == publicReel.id })
        #expect(reloaded.ownPublicReels.isEmpty)

        try await aliceAPI.logout()
        let expiredIdentity = try? await aliceAPI.me()
        #expect(expiredIdentity == nil)
        let bobsIdentity = try await bobAPI.me()
        #expect(bobsIdentity.id == bob.user.id)
    }

    @Test
    func serverTimestampsDecodeCaptureAndPublicationSeparately() throws {
        let recordID = UUID()
        let userID = UUID()
        let json = """
        {"id":"\(recordID)","ownerId":"\(userID)","owner":{"id":"\(userID)","handle":"alice"},
        "kind":"reel","visibility":"public","location":{"latitude":37.3,"longitude":-122.0},
        "caption":"Saved earlier","place":null,"media":[],"createdAt":"2026-10-15T12:00:00.123Z",
        "publishedAt":"2026-10-17T12:00:00Z","expiresAt":"2026-10-20T12:00:00.000Z"}
        """
        let memory = try BackendAPI.decoder.decode(BackendMemory.self, from: Data(json.utf8))
        let published = try #require(memory.publishedAt)
        #expect(published > memory.createdAt)
        #expect(memory.expiresAt.timeIntervalSince(published) == StoryReadKeys.freshWindow)
        #expect(memory.id == recordID)
        #expect(memory.owner.id == userID)
        #expect(memory.owner.handle == "alice")
        let reel = RealPost(id: recordID, userId: userID,
            center: .init(latitude: 37.3, longitude: -122), radiusMeters: 220,
            message: nil, attachments: [], likes: [], comments: [], visibility: .publicAll,
            createdAt: memory.createdAt, expiresAt: memory.expiresAt, publishedAt: published)
        #expect(reel.createdAt == memory.createdAt)
        #expect(RealStoriesRow.StoryItem(real: reel).timestamp == published)
    }

    private func register(using api: BackendAPI, prefix: String) async throws -> BackendAuth {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        let password = "test-only-\(UUID().uuidString)"
        let auth = try await api.authenticate(handle: "\(prefix)_\(suffix)", password: password, register: true)
        api.token = auth.token
        return auth
    }
}

/// A single test controls the final photo response, avoiding sleeps or timing assumptions.
private final class PausedBackendURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (PausedBackendURLProtocol) -> Void)?

    static func install(_ value: (@Sendable (PausedBackendURLProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let current = Self.lock.withLock { Self.handler }
        current?(self)
    }
    override func stopLoading() {}

    func respond(with data: Data, contentType: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": contentType]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

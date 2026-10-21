import CoreLocation
import Combine
import Foundation
import Testing
import UIKit
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendOutboxTests {
    private let location = CLLocation(latitude: 37.3688, longitude: -122.0363)

    @Test
    func oldPhotoQueueMetadataRemainsDecodableWithoutNewMIMEField() throws {
        let id = UUID()
        let bytes = Data("{\"id\":\"\(id.uuidString)\"}".utf8)
        let photo = try JSONDecoder().decode(QueuedPublication.Photo.self, from: bytes)
        #expect(photo.id == id)
        #expect(photo.contentType == "image/jpeg")
        #expect(!photo.isVideo)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func videoPOIAndReelSurviveOfflineRestartAndReuseTheUploadKey(isPOI: Bool) async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse, .success])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let poster = try context.photo()
        let bytes = try Data(contentsOf: source)
        let requestID = UUID()
        let draft: MapTalkPublishDraft = isPOI
            ? .place(.init(target: .new(name: "Video coffee", category: .coffee),
                media: .init(kind: .video(url: source, poster: poster))))
            : .reel(.init(text: "Video and photo", attachments: [
                .init(kind: .video(url: source, poster: poster)), .init(kind: .photo(poster))], bubbleSource: nil))
        let pending = try await store.enqueuePublish(draft, audience: .livePublic, location: location, requestID: requestID)
        let localVideo: URL
        let localPoster: URL?
        switch pending {
        case let .poi(value):
            guard case let .video(url, cover) = value.checkIns.first?.media.first?.kind else { Issue.record("Expected POI video"); return }
            localVideo = url; localPoster = cover
        case let .reel(value):
            guard case let .video(url, cover) = value.attachments.first?.kind else { Issue.record("Expected Reel video"); return }
            localVideo = url; localPoster = cover
        }
        #expect(localVideo != source)
        #expect(localVideo.pathExtension == "mp4")
        #expect(localPoster != nil)
        #expect(try Data(contentsOf: localVideo) == bytes)
        try FileManager.default.removeItem(at: source)
        await store.syncPendingPublications()
        #expect(context.fixture.uploads.count == 1)
        #expect(context.fixture.uploads.first?.mimeType == "video/mp4")
        #expect(context.fixture.inputs.isEmpty)

        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        let videoUploads = context.fixture.uploads.filter { $0.mimeType == "video/mp4" }
        #expect(videoUploads.count == 2)
        #expect(Set(videoUploads.map(\.key)).count == 1)
        #expect(videoUploads.allSatisfy { $0.bytes == bytes })
        #expect(restored.pendingPublications.isEmpty)
        #expect(context.fixture.inputs.map(\.id) == [requestID])
        #expect(!FileManager.default.fileExists(atPath: localVideo.path))
        if isPOI {
            let visit = try #require(restored.feedPOIs.value.first?.checkIns.first)
            guard case let .video(url, poster) = visit.media.first?.kind else { Issue.record("Saved POI video lost kind"); return }
            #expect(url.pathExtension == "mp4")
            #expect(poster != nil)
            #expect(try Data(contentsOf: url) == bytes)
        } else {
            let reel = try #require(restored.feedReels.value.first)
            #expect(reel.attachments.count == 2)
            guard case let .video(url, poster) = reel.attachments[0].kind else { Issue.record("Saved Reel video lost kind"); return }
            #expect(url.pathExtension == "mp4")
            #expect(poster != nil)
            #expect(try Data(contentsOf: url) == bytes)
            guard case .photo = reel.attachments[1].kind else { Issue.record("Mixed media order changed"); return }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingVideoWithLostUploadResponseRemovesDurableVideoAndCover() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let id = UUID()
        let result = try await store.enqueuePublish(.reel(.init(text: "Cancel video", attachments: [
            .init(kind: .video(url: source, poster: try context.photo()))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: id)
        guard case let .reel(reel) = result, case let .video(url, poster) = reel.attachments.first?.kind else {
            Issue.record("Expected a queued video"); return
        }
        await store.syncPendingPublications()
        context.fixture.setOffline(true)
        try await store.deletePost(memoryID: id)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        context.fixture.setOffline(false)
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        #expect(context.fixture.savedMediaCount == 0)
        #expect(context.fixture.inputs.isEmpty)
        #expect(context.fixture.cancelledUploadKeys == Set(context.fixture.uploads.map(\.key)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(poster).path))
    }

    @Test(.timeLimit(.minutes(1)))
    func enqueueCommitsLocallyWithoutAnyNetworkAndDoesNotPretendToBePublic() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        context.fixture.setOffline(true)
        let photo = try context.photo()
        let id = UUID()
        let result = try await store.enqueuePublish(draft("Waiting for Wi-Fi", photo: photo),
            audience: .livePublic, location: location, requestID: id)

        guard case let .reel(reel) = result else { Issue.record("Expected local Reel"); return }
        #expect(reel.id == id)
        #expect(store.archive.privateReels.map(\.id) == [id])
        #expect(store.pendingPublications[id] == .waiting)
        #expect(store.feedReels.value.isEmpty)
        #expect(store.ownPublicReels.isEmpty)
        #expect(context.fixture.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("state.json").path))
        let copiedPhoto = try #require(photoURL(reel))
        #expect(copiedPhoto != photo)
        #expect(try Data(contentsOf: copiedPhoto) == Data(contentsOf: photo))
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedPhotoAndIdentitySurviveComposerCleanupAndStoreRecreationOffline() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity(profile: .init(id: context.fixture.userID, handle: "cached_person"))
        let source = try context.photo()
        let bytes = try Data(contentsOf: source)
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Saved on phone", photo: source),
            audience: .livePublic, location: location, requestID: id)
        // Closing the composer removes its source. The outbox owns a durable copy.
        try FileManager.default.removeItem(at: source)
        context.fixture.setOffline(true)
        // Do not clear the first store: clearing represents logout, not an app restart.
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())

        #expect(restored.user.handle == "cached_person")
        #expect(restored.archive.privateReels.map(\.id) == [id])
        #expect(restored.pendingPublications[id] == .waiting)
        let localReel = try #require(restored.archive.privateReels.first)
        let localPhoto = try #require(photoURL(localReel))
        #expect(try Data(contentsOf: localPhoto) == bytes)
        #expect(context.fixture.requests.isEmpty)
        // Restored offline identity alone must not initiate authenticated writes.
        await restored.syncPendingPublications()
        #expect(context.fixture.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func lostPhotoResponseReusesTheSameUploadKeyAndBytesBeforePostingOnce() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse, .success])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let source = try context.photo()
        let bytes = try Data(contentsOf: source)
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Retry photo", photo: source),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        #expect(context.fixture.uploads.count == 1)
        #expect(context.fixture.inputs.isEmpty)
        #expect(store.pendingPublications[id] == .waiting)

        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        let attempts = context.fixture.uploads
        #expect(attempts.count == 2)
        #expect(Set(attempts.map(\.key)).count == 1)
        #expect(attempts.allSatisfy { $0.bytes == bytes })
        #expect(context.fixture.savedMediaCount == 1)
        #expect(context.fixture.inputs.map(\.id) == [id])
        #expect(context.fixture.inputs.first?.mediaIds.count == 1)
        #expect(restored.pendingPublications.isEmpty)
        #expect(restored.feedReels.value.map(\.id) == [id])
        #expect(restored.archive.privateReels.map(\.id) == [id])
    }

    @Test(.timeLimit(.minutes(1)))
    func lostPostResponseKeepsPostPhotoCaptionTimeAndLocationAcrossRestartAndRetry() async throws {
        let context = try OutboxTestContext(postOutcomes: [.lostResponse, .success])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let source = try context.photo()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Original caption", photo: source),
            audience: .livePublic, location: location, requestID: id)
        let savedTime = try #require(store.ownedMemories[id]?.createdAt)
        await store.syncPendingPublications()
        #expect(context.fixture.inputs.count == 1)
        #expect(store.pendingPublications[id] == .waiting)
        #expect(store.feedReels.value.isEmpty)

        try FileManager.default.removeItem(at: source)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        restored.resumeVerifiedConnection()
        // A repeated action with the same identity cannot change the original intent.
        _ = try await restored.enqueuePublish(draft("Do not replace the first caption"),
            audience: .privateMyMap, location: CLLocation(latitude: 47.6, longitude: -122.3), requestID: id)
        await restored.syncPendingPublications()
        let inputs = context.fixture.inputs
        #expect(inputs.count == 2)
        #expect(inputs.map(\.id) == [id, id])
        #expect(inputs.map(\.caption) == ["Original caption", "Original caption"])
        #expect(inputs.map(\.visibility) == ["public", "public"])
        #expect(inputs[0].capturedAt == inputs[1].capturedAt)
        let captured = try #require(inputs.first?.capturedAt)
        let decodedDate = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(captured)
        #expect(abs(decodedDate.timeIntervalSince(savedTime)) < 0.002)
        #expect(inputs.allSatisfy { $0.location.latitude == location.coordinate.latitude })
        #expect(inputs.allSatisfy { $0.location.longitude == location.coordinate.longitude })
        #expect(inputs[0].mediaIds == inputs[1].mediaIds)
        #expect(context.fixture.uploads.count == 1)
        #expect(context.fixture.savedMemoryCount == 1)
        #expect(restored.pendingPublications.isEmpty)
        #expect(restored.feedReels.value.map(\.id) == [id])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellingOfflinePersistsATombstoneAndNeverResumesThePost(hadLostPostResponse: Bool) async throws {
        let context = try OutboxTestContext(postOutcomes: [.lostResponse])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Cancel this post"),
            audience: .livePublic, location: location, requestID: id)
        if hadLostPostResponse { await store.syncPendingPublications() }
        let postsBeforeDelete = context.fixture.inputs.count
        context.fixture.setOffline(true)
        try await store.deletePost(memoryID: id)
        await store.syncPendingPublications()
        #expect(store.archive.privateReels.isEmpty)
        #expect(store.pendingPublications.isEmpty)
        #expect(store.feedReels.value.isEmpty)

        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privateReels.isEmpty)
        context.fixture.setOffline(false)
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        #expect(context.fixture.inputs.count == postsBeforeDelete)
        #expect(context.fixture.cancelledIDs == [id])
        #expect(context.fixture.savedMemoryCount == 0)
        #expect(restored.archive.privateReels.isEmpty)
        do {
            _ = try await restored.enqueuePublish(draft("Should stay deleted"),
                audience: .livePublic, location: location, requestID: id)
            Issue.record("A cancelled post ID must not re-enter the publishing queue")
        } catch { #expect(error is BackendClientError) }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationReclaimsAnUploadedPhotoEvenWhenItsResponseWasLost() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Cancel ambiguous upload", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: id)
        let reel = try #require(store.archive.privateReels.first)
        let durablePhoto = try #require(photoURL(reel))
        await store.syncPendingPublications()
        #expect(context.fixture.uploads.count == 1)
        #expect(context.fixture.savedMediaCount == 1)
        #expect(context.fixture.inputs.isEmpty)

        context.fixture.setOffline(true)
        try await store.deletePost(memoryID: id)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        context.fixture.setOffline(false)
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()

        #expect(context.fixture.cancelledIDs == [id])
        #expect(context.fixture.cancelledUploadKeys == Set(context.fixture.uploads.map(\.key)))
        #expect(context.fixture.savedMediaCount == 0)
        #expect(context.fixture.uploads.count == 1)
        #expect(context.fixture.inputs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: durablePhoto.path))
        #expect(restored.pendingPublications.isEmpty)
        #expect(restored.archive.privateReels.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedNewPlaceKeepsAllCollectionMembershipsWhenServerAssignsItsCanonicalPlaceID() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let requestID = UUID()
        let result = try await store.enqueuePublish(.place(.init(target: .new(name: "New coffee shop", category: .coffee), media: nil)),
            audience: .livePublic, location: location, requestID: requestID)
        guard case let .poi(pending) = result else { Issue.record("Expected local place"); return }
        #expect(pending.id == requestID)
        #expect(pending.id != context.fixture.canonicalPlaceID)
        let firstReel = JourneyFolder.MemberReference.reel(UUID())
        let lastReel = JourneyFolder.MemberReference.reel(UUID())
        let canonical = JourneyFolder.MemberReference.poi(context.fixture.canonicalPlaceID)
        let first = store.archive.createJourneyFolder(title: "Weekend", memberReferences:
            [firstReel, .poi(pending.id), canonical, lastReel])
        let second = store.archive.createJourneyFolder(title: "Coffee", memberReferences: [.poi(pending.id)])
        let unrelated = store.archive.createJourneyFolder(title: "Other", memberReferences: [firstReel])

        await store.syncPendingPublications()
        #expect(store.pendingPublications.isEmpty)
        #expect(store.archive.privatePOIs.map(\.id) == [context.fixture.canonicalPlaceID])
        #expect(store.archive.journeyFolders.first { $0.id == first.id }?.memberReferences == [firstReel, canonical, lastReel])
        #expect(store.archive.journeyFolders.first { $0.id == second.id }?.memberReferences == [canonical])
        #expect(store.archive.journeyFolders.first { $0.id == unrelated.id } == unrelated)

        // Replay is a no-op, and both post metadata and Collection references
        // survive process recreation under the same canonical place identity.
        try store.archive.remapPOIReference(from: pending.id, to: context.fixture.canonicalPlaceID)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privatePOIs.map(\.id) == [context.fixture.canonicalPlaceID])
        #expect(restored.archive.journeyFolders.first { $0.id == first.id }?.memberReferences == [firstReel, canonical, lastReel])
        #expect(restored.archive.journeyFolders.first { $0.id == second.id }?.memberReferences == [canonical])
    }

    @Test(.timeLimit(.minutes(1)))
    func twoOfflineVisitsToOneNewPlaceUploadWithoutLosingEitherVisitOrDuplicatingThePerson() async throws {
        let context = try OutboxTestContext(postOutcomes: [.success, .lostResponse, .success])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let firstID = UUID()
        let secondID = UUID()
        let first = try await store.enqueuePublish(.place(.init(
            target: .new(name: "Offline coffee shop", category: .coffee),
            media: .init(kind: .photo(try context.photo())))),
            audience: .livePublic, location: location, requestID: firstID)
        guard case let .poi(pendingPlace) = first else { Issue.record("Expected provisional place"); return }
        _ = try await store.enqueuePublish(.place(.init(target: .existing(pendingPlace),
            media: .init(kind: .photo(try context.photo())))),
            audience: .livePublic, location: location, requestID: secondID)
        let queued = try #require(store.archive.privatePOIs.first)
        #expect(store.archive.privatePOIs.count == 1)
        #expect(Set(queued.checkIns.map(\.id)) == [firstID, secondID])
        #expect(queued.checkInPersonCount == 1)
        #expect(context.fixture.requests.isEmpty)

        // First confirmation canonicalizes both local projections. The second
        // reply is then lost, exercising restart/replay without mutating its input.
        await store.syncPendingPublications()
        #expect(store.pendingPublications[firstID] == nil)
        #expect(store.pendingPublications[secondID] == .waiting)
        #expect(store.archive.privatePOIs.map(\.id) == [context.fixture.canonicalPlaceID])
        #expect(store.archive.privatePOIs.first?.checkIns.count == 2)
        #expect(store.feedPOIs.value.first?.checkIns.count == 1)

        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.archive.privatePOIs.map(\.id) == [context.fixture.canonicalPlaceID])
        #expect(restored.archive.privatePOIs.first?.checkIns.count == 2)
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        let inputs = context.fixture.inputs
        #expect(inputs.map(\.id) == [firstID, secondID, secondID])
        #expect(inputs.allSatisfy { $0.placeId == nil })
        #expect(inputs.allSatisfy { $0.place?.sourceId == firstID })
        #expect(inputs[1].mediaIds == inputs[2].mediaIds)
        #expect(inputs[1].capturedAt == inputs[2].capturedAt)
        #expect(context.fixture.savedPlaceCount == 1)
        #expect(context.fixture.savedMemoryCount == 2)
        #expect(context.fixture.uploads.count == 2)
        #expect(restored.pendingPublications.isEmpty)
        let confirmed = try #require(restored.feedPOIs.value.first)
        #expect(restored.feedPOIs.value.count == 1)
        #expect(Set(confirmed.checkIns.map(\.id)) == [firstID, secondID])
        // Connected POIs keep visit media on each check-in, not duplicated in
        // the landmark's separate gallery. The story viewer consumes these groups.
        #expect(confirmed.checkIns.flatMap(\.media).count == 2)
        for media in confirmed.checkIns.flatMap(\.media) {
            guard case let .photo(url) = media.kind else { Issue.record("Expected preserved photo"); continue }
            #expect(url.isFileURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try !Data(contentsOf: url).isEmpty)
        }
        #expect(confirmed.checkInPersonCount == 1)
        let contributors = ExperienceDetailView(mode: .poi(confirmed)).poiStoryContributors(for: confirmed)
        #expect(contributors.count == 1)
        #expect(contributors.first?.items.count == 2)
        let people = try #require(MapStoryFeed.poiGroup(for: confirmed, onlyRecentStories: true,
            userProvider: { restored.user(for: $0) }))
        #expect(people.sharers.count == 1)
        #expect(people.sharers.first?.readKeys.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func confirmedArchiveFeedIdentityAndPhotoRestoreOfflineAndSurviveFailedRefresh() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity(profile: .init(id: context.fixture.userID, handle: "verified_person"))
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Cached public post", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        #expect(store.pendingPublications.isEmpty)
        let confirmed = try #require(store.archive.privateReels.first)
        let confirmedURL = try #require(photoURL(confirmed))
        let bytes = try Data(contentsOf: confirmedURL)
        let requestsBeforeRestore = context.fixture.requests.count

        context.fixture.setOffline(true)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(context.fixture.requests.count == requestsBeforeRestore)
        #expect(restored.user.handle == "verified_person")
        #expect(restored.archive.privateReels.map(\.id) == [id])
        #expect(restored.feedReels.value.map(\.id) == [id])
        #expect(restored.ownPublicReels.map(\.id) == [id])
        let restoredReel = try #require(restored.archive.privateReels.first)
        let restoredURL = try #require(photoURL(restoredReel))
        #expect(try Data(contentsOf: restoredURL) == bytes)
        do {
            try await restored.refresh()
            Issue.record("Offline refresh should fail without discarding cached content")
        } catch { #expect(error is BackendClientError) }
        #expect(restored.archive.privateReels.map(\.id) == [id])
        #expect(restored.feedReels.value.map(\.id) == [id])
    }

    private func draft(_ caption: String, photo: URL? = nil) -> MapTalkPublishDraft {
        .reel(.init(text: caption, attachments: photo.map { [.init(kind: .photo($0))] } ?? [], bubbleSource: nil))
    }

    private func photoURL(_ reel: RealPost) -> URL? {
        guard let attachment = reel.attachments.first, case let .photo(url) = attachment.kind else { return nil }
        return url
    }
}

@MainActor
private final class OutboxTestContext {
    let fixture: OutboxFixture
    let directory: URL
    let session: URLSession
    let api: BackendAPI
    private var stores: [BackendStore] = []

    init(uploadOutcomes: [OutboxFixture.Outcome] = [], postOutcomes: [OutboxFixture.Outcome] = []) throws {
        let fixture = OutboxFixture(uploadOutcomes: uploadOutcomes, postOutcomes: postOutcomes)
        self.fixture = fixture
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        OutboxURLProtocol.install { fixture.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutboxURLProtocol.self]
        session = URLSession(configuration: configuration)
        api = BackendAPI(baseURL: URL(string: "https://outbox-test.invalid")!, session: session)
        api.token = "isolated-test-session"
    }

    func makeStore() -> BackendStore {
        let store = BackendStore(user: .init(id: fixture.userID, handle: "fresh_identity", avatarURL: nil),
            api: api, storageDirectory: directory, automaticallySync: false)
        stores.append(store)
        return store
    }

    func photo() throws -> URL {
        let file = directory.appendingPathComponent("composer-\(UUID()).jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        let data = try #require(image.jpegData(compressionQuality: 0.85))
        try data.write(to: file, options: .atomic)
        return file
    }

    func finish() {
        stores.forEach { $0.clearLocalMedia() }
        session.invalidateAndCancel()
        OutboxURLProtocol.install(nil)
        try? FileManager.default.removeItem(at: directory)
        // Collection files use the unique fixture user's normal account root.
        // Never touch another user's on-device archive.
        let accountDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendAccounts/\(fixture.userID.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: accountDirectory)
    }
}

private final class OutboxFixture: @unchecked Sendable {
    enum Outcome { case success, lostResponse }
    struct Upload { let key: UUID; let bytes: Data; let mimeType: String }
    let userID = UUID()
    let canonicalPlaceID = UUID()
    private let lock = NSLock()
    private var offline = false
    private var uploadOutcomes: [Outcome]
    private var postOutcomes: [Outcome]
    private var uploadAttempts: [Upload] = []
    private var postInputs: [BackendMemoryInput] = []
    private var requestLog: [String] = []
    private var media: [UUID: BackendMedia] = [:]
    private var memories: [UUID: BackendMemory] = [:]
    private var places: [UUID: BackendPlace] = [:]
    private var placeSources: [UUID: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var cancelledUploads: Set<UUID> = []
    var uploads: [Upload] { lock.withLock { uploadAttempts } }
    var inputs: [BackendMemoryInput] { lock.withLock { postInputs } }
    var requests: [String] { lock.withLock { requestLog } }
    var savedMediaCount: Int { lock.withLock { media.count } }
    var savedMemoryCount: Int { lock.withLock { memories.count } }
    var savedPlaceCount: Int { lock.withLock { places.count } }
    var cancelledIDs: Set<UUID> { lock.withLock { cancelled } }
    var cancelledUploadKeys: Set<UUID> { lock.withLock { cancelledUploads } }

    init(uploadOutcomes: [Outcome], postOutcomes: [Outcome]) {
        self.uploadOutcomes = uploadOutcomes
        self.postOutcomes = postOutcomes
    }

    func setOffline(_ value: Bool) { lock.withLock { offline = value } }

    func handle(_ operation: OutboxURLProtocol) {
        let request = operation.request
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let isOffline = lock.withLock {
            requestLog.append("\(method) \(path)")
            return offline
        }
        if isOffline { operation.fail(URLError(.notConnectedToInternet)); return }
        do {
            if method == "POST", path == "/v1/media" {
                guard let key = request.value(forHTTPHeaderField: "Idempotency-Key").flatMap(UUID.init(uuidString:)) else {
                    operation.respond(status: 400, data: Data()); return
                }
                let data = body(of: request)
                let (saved, outcome) = lock.withLock {
                    let mime = request.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
                    uploadAttempts.append(.init(key: key, bytes: data, mimeType: mime))
                    let saved = media[key] ?? BackendMedia(id: UUID(), mimeType: mime, byteCount: data.count, path: "")
                    let normalized = BackendMedia(id: saved.id, mimeType: saved.mimeType, byteCount: saved.byteCount,
                        path: "/v1/media/\(saved.id.uuidString.lowercased())")
                    media[key] = normalized
                    return (normalized, uploadOutcomes.isEmpty ? Outcome.success : uploadOutcomes.removeFirst())
                }
                if case .lostResponse = outcome { operation.fail(URLError(.networkConnectionLost)); return }
                operation.respond(status: 201, data: try encode(saved))
            } else if method == "POST", path == "/v1/memories" {
                let input = try JSONDecoder().decode(BackendMemoryInput.self, from: body(of: request))
                let captured = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(input.capturedAt ?? "")
                let place: BackendPlace? = lock.withLock {
                    postInputs.append(input)
                    if let id = input.placeId { return places[id] }
                    guard let value = input.place else { return nil }
                    if let source = value.sourceId, let id = placeSources[source], let existing = places[id] {
                        return existing
                    }
                    let id = places.isEmpty ? canonicalPlaceID : UUID()
                    let created = BackendPlace(id: id, sourceId: value.sourceId, name: value.name,
                        category: value.category, coordinate: value.coordinate ?? input.location)
                    places[id] = created
                    if let source = value.sourceId { placeSources[source] = id }
                    return created
                }
                if input.kind == "poi", place == nil {
                    operation.respond(status: 404, data: Data("{\"error\":{\"message\":\"Unknown server place ID\"}}".utf8))
                    return
                }
                let (saved, outcome) = lock.withLock {
                    let photos = input.mediaIds.compactMap { id in media.values.first { $0.id == id } }
                    let saved = memories[input.id] ?? BackendMemory(id: input.id, ownerId: userID,
                        owner: .init(id: userID, handle: "server_person"), kind: input.kind, visibility: input.visibility,
                        location: input.location, caption: input.caption ?? "", place: place, media: photos,
                        createdAt: captured, publishedAt: input.visibility == "public" ? Date() : nil,
                        expiresAt: Date().addingTimeInterval(86_400), moderationStatus: "approved")
                    memories[input.id] = saved
                    return (saved, postOutcomes.isEmpty ? Outcome.success : postOutcomes.removeFirst())
                }
                if case .lostResponse = outcome { operation.fail(URLError(.networkConnectionLost)); return }
                operation.respond(status: 201, data: try encode(saved))
            } else if method == "DELETE", path.hasPrefix("/v1/memories/"),
                      let id = UUID(uuidString: String(path.dropFirst("/v1/memories/".count))) {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard query.contains(where: { $0.name == "cancelPending" && $0.value == "true" }) else {
                    operation.respond(status: 400, data: Data()); return
                }
                lock.withLock { _ = cancelled.insert(id); memories.removeValue(forKey: id) }
                operation.respond(status: 204, data: Data())
            } else if method == "DELETE", path.hasPrefix("/v1/media/by-upload-key/"),
                      let key = UUID(uuidString: String(path.dropFirst("/v1/media/by-upload-key/".count))) {
                lock.withLock { _ = cancelledUploads.insert(key); media.removeValue(forKey: key) }
                operation.respond(status: 200, data: Data("{}".utf8))
            } else if method == "DELETE", path.hasPrefix("/v1/media/") {
                operation.respond(status: 204, data: Data())
            } else {
                // Unplanned requests fail visibly; they must never escape to a real server.
                operation.respond(status: 500, data: Data("{\"error\":{\"message\":\"Unexpected isolated test request\"}}".utf8))
            }
        } catch { operation.fail(error) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func body(of request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}

private final class OutboxURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (OutboxURLProtocol) -> Void)?
    static func install(_ value: (@Sendable (OutboxURLProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}

    func respond(status: Int, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}

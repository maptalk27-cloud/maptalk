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
        #expect(videoUploads.count == 1, "The acknowledged video bytes must not be uploaded again after a lost reply")
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
        #expect(context.fixture.stagedVideoCount == 0)
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
        let feedPost = try #require(restored.feedReels.value.first)
        let archivePost = try #require(restored.archive.privateReels.first { $0.id == id })
        #expect(feedPost.activityDate == decodedDate)
        #expect(archivePost.cardDisplayDate == feedPost.cardDisplayDate)
        #expect(abs(archivePost.activityDate.timeIntervalSince(savedTime)) < 0.002)
        #expect(feedPost.expiresAt == decodedDate.addingTimeInterval(StoryReadKeys.freshWindow))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [404, 422])
    func restoredPostRefusalWaitsForExplicitRetryAndKeepsTheExactIntent(status: Int) async throws {
        let code = status == 404 ? "not_found" : "invalid_category"
        let context = try OutboxTestContext(postOutcomes: [.http(status, code), .success])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        let source = try context.photo()
        _ = try await store.enqueuePublish(.place(.init(target: .new(name: "Original place", category: .coffee),
            media: .init(kind: .photo(source)))), audience: .livePublic, location: location, requestID: id)
        let queued = try #require(try context.state().queued.first)
        #expect(queued.lastFailure == nil, "Queues without diagnostic metadata must remain decodable")
        let durablePhoto = context.directory.appendingPathComponent(try #require(queued.photos.first).id.uuidString)
            .appendingPathExtension("jpg")
        let bytes = try Data(contentsOf: durablePhoto)
        await store.syncPendingPublications()
        guard case let .failed(reason) = store.pendingPublications[id] else {
            Issue.record("The server refusal must wait for an explicit retry"); return
        }
        let refused = try #require(try context.state().queued.first)
        #expect(refused.lastFailure?.phase == .publication)
        #expect(refused.lastFailure?.httpStatus == status)
        #expect(refused.lastFailure?.code == code)
        #expect(refused.attemptedPost)
        #expect(context.fixture.savedMemoryCount == 0)
        try FileManager.default.removeItem(at: source)

        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        #expect(restored.pendingPublications[id] == .failed(reason))
        #expect(context.fixture.inputs.count == 1, "Reconnection must not silently retry a permanent refusal")
        #expect(try Data(contentsOf: durablePhoto) == bytes)
        restored.retryPendingPublications(id: id)
        await restored.syncPendingPublications()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let inputs = context.fixture.inputs
        #expect(inputs.count == 2)
        #expect(try encoder.encode(inputs[0]) == encoder.encode(inputs[1]))
        #expect(inputs.map(\.id) == [id, id])
        #expect(context.fixture.uploads.count == 1, "Confirmed media is reused, not uploaded under a new key")
        #expect(context.fixture.savedMemoryCount == 1)
        #expect(restored.pendingPublications.isEmpty)
        #expect(try context.state().queued.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: durablePhoto.path))
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
        restored.retryPendingPublications()
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func interruptedVideoRetriesOnlyTheUnacknowledgedPart(lostAcknowledgment: Bool) async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.success,
            lostAcknowledgment ? .lostResponse : .interruptedBeforeCommit])
        defer { context.finish() }
        let bytes = Data((0..<(1_024 * 1_024 + 17)).map { UInt8($0 % 251) })
        let file = context.directory.appendingPathComponent("chunk-test.mp4")
        try bytes.write(to: file)
        let id = UUID()
        do {
            _ = try await context.api.uploadVideo(at: file, idempotencyKey: id)
            Issue.record("The second chunk must interrupt the first attempt")
        } catch { #expect(error is BackendClientError) }
        #expect(context.fixture.chunkOffsets == [0, 524_288])
        #expect(context.fixture.savedMediaCount == 0)
        // No local offset is required: a new API instance reconciles with the
        // same stable upload ID, exactly as after process recreation.
        let restoredAPI = BackendAPI(baseURL: context.api.baseURL, session: context.session)
        restoredAPI.token = "isolated-test-session"
        var progress: [Double] = []
        let saved = try await restoredAPI.uploadVideo(at: file, idempotencyKey: id,
            onProgress: { progress.append($0) })
        #expect(saved.byteCount == bytes.count)
        #expect(context.fixture.uploadStarts == [id, id])
        #expect(context.fixture.chunkOffsets == (lostAcknowledgment
            ? [0, 524_288, 1_048_576] : [0, 524_288, 524_288, 1_048_576]))
        #expect(progress.first == Double(lostAcknowledgment ? 1_048_576 : 524_288) / Double(bytes.count))
        #expect(progress.last == 1)
        #expect(context.fixture.savedMediaCount == 1)
        #expect(context.fixture.requests.allSatisfy { $0 != "POST /v1/media" })
    }

    @Test(.timeLimit(.minutes(1)))
    func lostVideoCompletionReplyReconcilesWithoutSendingAnyMoreBytes() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        context.fixture.setFinishOutcomes([.lostResponse])
        let file = context.directory.appendingPathComponent("complete-test.mp4")
        try Data(repeating: 9, count: 524_289).write(to: file)
        let id = UUID()
        do {
            _ = try await context.api.uploadVideo(at: file, idempotencyKey: id)
            Issue.record("The committed completion reply should be lost")
        } catch { #expect(error is BackendClientError) }
        #expect(context.fixture.savedMediaCount == 1)
        let chunksBefore = context.fixture.chunkOffsets
        let saved = try await context.api.uploadVideo(at: file, idempotencyKey: id)
        #expect(saved.mimeType == "video/mp4")
        #expect(context.fixture.chunkOffsets == chunksBefore)
        #expect(context.fixture.requests.filter { $0.hasSuffix("/complete") }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func quotaFailureExplainsTheProblemAndDoesNotBlockTheNextPost() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        context.fixture.setFinishOutcomes([.http(413, "media_quota")])
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let file = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let videoID = UUID()
        let photoID = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "Full video storage", attachments: [
            .init(kind: .video(url: file, poster: try context.photo()))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: videoID)
        _ = try await store.enqueuePublish(draft("Independent photo", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: photoID)
        await store.syncPendingPublications()
        guard case let .failed(reason) = store.pendingPublications[videoID] else {
            Issue.record("Quota must be actionable, not silently retried"); return
        }
        #expect(reason.contains("storage is full"))
        #expect(reason.contains("saved on this phone"))
        #expect(store.pendingPublications[photoID] == nil)
        #expect(context.fixture.inputs.map(\.id) == [photoID])
        let count = context.fixture.requests.count
        await store.syncPendingPublications()
        #expect(context.fixture.requests.count == count, "Permanent failure must wait for explicit retry")
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.pendingPublications[videoID] == .failed(reason))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["invalid_video", "unsupported_video", "unexpected_decoder_reason"])
    func videoRejectionKeepsLocalPreviewWithoutSurfacingServerDiagnostics(code: String) async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        context.fixture.setFinishOutcomes([.http(422, code)])
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let id = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "Still mine to watch", attachments: [
            .init(kind: .video(url: source, poster: try context.photo()))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        guard case let .failed(reason) = store.pendingPublications[id] else {
            Issue.record("Expected a retained failed publication"); return
        }
        #expect(reason == "Couldn't publish yet. Your post is saved on this phone. Please try again.")
        #expect(!reason.contains(code))
        #expect(store.feedReels.value.isEmpty, "Local preview must not pretend the post is public")
        let refused = try #require(try context.state().queued.first)
        #expect(refused.lastFailure?.phase == .videoProcessing)
        #expect(refused.lastFailure?.httpStatus == 422)
        #expect(refused.lastFailure?.code == code)
        #expect(refused.lastFailure?.occurredAt != nil)
        #expect(!refused.attemptedPost)
        let chunks = context.fixture.chunkOffsets
        let uploadID = try #require(refused.photos.first?.id)

        context.fixture.setOffline(true)
        let restored = context.makeStore()
        #expect(await restored.restoreCachedState())
        #expect(restored.pendingPublications[id] == .failed(reason))
        let reel = try #require(restored.archive.privateReels.first(where: { $0.id == id }))
        guard case let .video(url, poster) = reel.attachments.first?.kind else {
            Issue.record("Failed upload must keep its normal local video preview"); return
        }
        #expect(url.isFileURL)
        #expect(try Data(contentsOf: url) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: try #require(poster).path))
        #expect(context.fixture.inputs.isEmpty)

        context.fixture.setOffline(false)
        restored.resumeVerifiedConnection()
        await restored.syncPendingPublications()
        #expect(context.fixture.uploadStarts == [uploadID], "Restart must not retry a refused video automatically")
        restored.retryPendingPublications(id: id)
        await restored.syncPendingPublications()
        #expect(context.fixture.uploadStarts == [uploadID, uploadID])
        #expect(context.fixture.chunkOffsets == chunks, "Already staged video bytes must not be resent")
        #expect(context.fixture.inputs.map(\.id) == [id])
        #expect(context.fixture.savedMemoryCount == 1)
        #expect(context.fixture.savedMediaCount == 1)
        #expect(restored.pendingPublications.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["private server message", "https://private.invalid/token", String(repeating: "x", count: 81)])
    func failureDiagnosticsDoNotPersistArbitraryServerText(code: String) async throws {
        let context = try OutboxTestContext(postOutcomes: [.http(422, code)])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Keep my intent"),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        let diagnostic = try #require(try context.state().queued.first?.lastFailure)
        #expect(diagnostic.phase == .publication)
        #expect(diagnostic.httpStatus == 422)
        #expect(diagnostic.code == nil)
        #expect(try !String(decoding: JSONEncoder().encode(diagnostic), as: UTF8.self).contains(code))
    }

    @Test(.timeLimit(.minutes(1)))
    func transientVideoInterruptionDoesNotBlockAnIndependentPost() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let file = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let videoID = UUID()
        let nextID = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "Interrupted", attachments: [
            .init(kind: .video(url: file, poster: try context.photo()))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: videoID)
        _ = try await store.enqueuePublish(draft("This should not wait"), audience: .livePublic,
            location: location, requestID: nextID)
        await store.syncPendingPublications()
        #expect(store.pendingPublications[videoID] == .waiting)
        #expect(store.pendingPublications[nextID] == nil)
        #expect(context.fixture.inputs.map(\.id) == [nextID])
    }

    @Test(.timeLimit(.minutes(1)))
    func oldServerNeverFallsBackToAWholeVideoUpload() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        context.fixture.setLegacyOnly(true)
        let file = context.directory.appendingPathComponent("legacy-server.mp4")
        try Data(repeating: 1, count: 12).write(to: file)
        do {
            _ = try await context.api.uploadVideo(at: file, idempotencyKey: UUID())
            Issue.record("An older server cannot acknowledge resumable uploads")
        } catch { #expect(error.localizedDescription.contains("server update")) }
        #expect(context.fixture.requests.count == 1)
        #expect(context.fixture.requests.allSatisfy { $0.hasPrefix("PUT /v1/media/uploads/") })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBetweenChunksStopsBeforeCompletionAndTombstonePreventsResurrection() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let file = context.directory.appendingPathComponent("cancel-chunks.mp4")
        try Data(repeating: 3, count: 1_048_576).write(to: file)
        let id = UUID()
        var cancelled = false
        do {
            _ = try await context.api.uploadVideo(at: file, idempotencyKey: id,
                checkActive: { if cancelled { throw CancellationError() } },
                onProgress: { if $0 > 0 { cancelled = true } })
            Issue.record("Cancellation must stop between chunks")
        } catch { #expect(error is CancellationError) }
        #expect(context.fixture.chunkOffsets == [0])
        #expect(context.fixture.savedMediaCount == 0)
        #expect(context.fixture.requests.allSatisfy { !$0.hasSuffix("/complete") })
        try await context.api.cancelPhotoUpload(key: id)
        #expect(context.fixture.stagedVideoCount == 0)
        do {
            _ = try await context.api.uploadVideo(at: file, idempotencyKey: id)
            Issue.record("Cancelled upload identity must never restart")
        } catch {
            guard case let BackendClientError.http(status, _, code) = error else { Issue.record("Expected HTTP cancellation"); return }
            #expect(status == 410)
            #expect(code == "media_deleted")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mixedAttachmentProgressNeverRestartsForTheNextVideo() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let file = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let photo = try context.photo()
        let id = UUID()
        var progress: [Double] = []
        var statuses: [PendingPublicationStatus] = []
        let progressObserver = store.$publicationProgress.sink { values in
            if let value = values[id] { progress.append(value) }
        }
        let statusObserver = store.$pendingPublications.sink { values in
            if let value = values[id] { statuses.append(value) }
        }
        defer { progressObserver.cancel(); statusObserver.cancel() }
        _ = try await store.enqueuePublish(.reel(.init(text: "Mixed progress", attachments: [
            .init(kind: .video(url: file, poster: photo)), .init(kind: .photo(photo)),
            .init(kind: .video(url: file, poster: photo))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        #expect(store.pendingPublications[id] == nil)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        #expect(progress.contains(1.0 / 3.0))
        #expect(progress.contains(2.0 / 3.0))
        #expect(progress.last == 1)
        #expect(statuses.contains(.processing))
        #expect(statuses.last == .uploading, "Video processing must end before post confirmation")
        #expect(store.publicationProgress[id] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticSchedulerRetriesWithoutAManualSyncOrNetworkEvent() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse, .success])
        defer { context.finish() }
        let store = context.makeStore(automaticallySync: true)
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Automatic retry", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: id)
        #expect(await eventually { context.fixture.inputs.map(\.id) == [id] && store.pendingPublications[id] == nil })
        #expect(context.fixture.uploads.count == 2)
        #expect(Set(context.fixture.uploads.map(\.key)).count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticSchedulerStopsPermanentFailuresAndRetryTargetsOnlyOnePost() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.http(413, "media_quota"), .http(413, "media_quota")])
        defer { context.finish() }
        let store = context.makeStore(automaticallySync: true)
        try await store.cacheVerifiedIdentity()
        let firstID = UUID()
        let secondID = UUID()
        _ = try await store.enqueuePublish(draft("First full", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: firstID)
        _ = try await store.enqueuePublish(draft("Second full", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: secondID)
        #expect(await eventually {
            if case .failed = store.pendingPublications[firstID], case .failed = store.pendingPublications[secondID] { return true }
            return false
        })
        let attempts = context.fixture.requests.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(context.fixture.requests.count == attempts)
        store.retryPendingPublications(id: firstID)
        #expect(await eventually { context.fixture.inputs.map(\.id) == [firstID] && store.pendingPublications[firstID] == nil })
        guard case .failed = store.pendingPublications[secondID] else {
            Issue.record("Retrying one row must not retry a different failed post"); return
        }
        #expect(context.fixture.uploads.count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledCleanupRefusalBacksOffInsteadOfSpinning() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.lostResponse])
        defer { context.finish() }
        context.fixture.setCancellationOutcomes([.http(409, "media_in_use")])
        let store = context.makeStore(automaticallySync: true, retryDelay: { _ in 0.3 })
        try await store.cacheVerifiedIdentity()
        let id = UUID()
        _ = try await store.enqueuePublish(draft("Cancel after lost reply", photo: try context.photo()),
            audience: .livePublic, location: location, requestID: id)
        #expect(await eventually { context.fixture.uploads.count == 1 && store.pendingPublications[id] == .waiting })
        try await store.deletePost(memoryID: id)
        #expect(await eventually { context.fixture.cancellationAttempts == 1 })
        try await Task.sleep(for: .milliseconds(120))
        #expect(context.fixture.cancellationAttempts == 1, "Cleanup refusals must not trigger immediate retries")
        #expect(store.hasPendingSyncWork, "The cancellation tombstone must survive until acknowledged")
        #expect(await eventually { !store.hasPendingSyncWork })
        #expect(context.fixture.cancellationAttempts == 2)
        #expect(context.fixture.savedMediaCount == 0)
        #expect(store.pendingPublications.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func interruptedChunkBodyRemainsRetryableInsteadOfPermanentlyFailingTheVideo() async throws {
        let context = try OutboxTestContext(uploadOutcomes: [.http(400, "incomplete_body")])
        defer { context.finish() }
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let file = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "Interrupted body", attachments: [
            .init(kind: .video(url: file, poster: try context.photo()))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        #expect(store.pendingPublications[id] == .waiting)
        #expect(context.fixture.inputs.isEmpty)
        await store.syncPendingPublications()
        #expect(store.pendingPublications[id] == nil)
        #expect(context.fixture.chunkOffsets == [0, 0])
        #expect(context.fixture.inputs.map(\.id) == [id])
    }

    @Test(.timeLimit(.minutes(1)))
    func interruptedRetryKeepsAcknowledgedProgressWhileReconciliationIsWaiting() async throws {
        let context = try OutboxTestContext()
        defer { context.finish() }
        context.fixture.setFinishOutcomes([.interruptedBeforeCommit])
        let store = context.makeStore()
        try await store.cacheVerifiedIdentity()
        let file = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let photo = try context.photo()
        let id = UUID()
        _ = try await store.enqueuePublish(.reel(.init(text: "Keep progress while reconnecting", attachments: [
            .init(kind: .video(url: file, poster: photo)), .init(kind: .photo(photo))], bubbleSource: nil)),
            audience: .livePublic, location: location, requestID: id)
        await store.syncPendingPublications()
        #expect(store.pendingPublications[id] == .waiting)
        #expect(store.publicationProgress[id] == 0.5)
        context.fixture.holdNextUploadStart()
        let retry = Task { await store.syncPendingPublications() }
        defer { retry.cancel(); context.fixture.releaseHeldUploadStarts() }
        let isHeld = await eventually { context.fixture.heldUploadStartCount == 1 }
        #expect(isHeld)
        guard isHeld else { return }
        #expect(store.pendingPublications[id] == .uploading)
        #expect(store.publicationProgress[id] == 0.5, "A slow reconciliation must not flash back to 0%")
        context.fixture.releaseHeldUploadStarts()
        await retry.value
        #expect(store.pendingPublications[id] == nil)
        #expect(store.publicationProgress[id] == nil)
        #expect(context.fixture.inputs.map(\.id) == [id])
        #expect(context.fixture.chunkOffsets == [0], "Confirmed video bytes must not be resent")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return condition()
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

    func makeStore(automaticallySync: Bool = false,
                   retryDelay: @escaping @Sendable (Int) -> TimeInterval = { _ in 0.03 }) -> BackendStore {
        let store = BackendStore(user: .init(id: fixture.userID, handle: "fresh_identity", avatarURL: nil),
            api: api, storageDirectory: directory, automaticallySync: automaticallySync,
            observesConnectivity: false, retryDelay: retryDelay)
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

    func state() throws -> BackendLocalState {
        try JSONDecoder().decode(BackendLocalState.self,
            from: Data(contentsOf: directory.appendingPathComponent("state.json")))
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
    enum Outcome { case success, lostResponse, interruptedBeforeCommit, http(Int, String) }
    struct Upload { let key: UUID; let bytes: Data; let mimeType: String }
    struct VideoStage {
        let byteCount: Int
        let hash: String
        var bytes = Data()
        var media: BackendMedia?
    }
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
    private var videoStages: [UUID: VideoStage] = [:]
    private var offsets: [Int] = []
    private var finishOutcomes: [Outcome] = []
    private var cancellationOutcomes: [Outcome] = []
    private var cancellationRequestCount = 0
    private var starts: [UUID] = []
    private var legacyOnly = false
    private var shouldHoldNextUploadStart = false
    private var heldUploadStarts: [(OutboxURLProtocol, Data)] = []
    private var memories: [UUID: BackendMemory] = [:]
    private var places: [UUID: BackendPlace] = [:]
    private var placeSources: [UUID: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var cancelledUploads: Set<UUID> = []
    var uploads: [Upload] { lock.withLock { uploadAttempts } }
    var chunkOffsets: [Int] { lock.withLock { offsets } }
    var uploadStarts: [UUID] { lock.withLock { starts } }
    var stagedVideoCount: Int { lock.withLock { videoStages.count } }
    var cancellationAttempts: Int { lock.withLock { cancellationRequestCount } }
    var heldUploadStartCount: Int { lock.withLock { heldUploadStarts.count } }
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
    func setFinishOutcomes(_ value: [Outcome]) { lock.withLock { finishOutcomes = value } }
    func setCancellationOutcomes(_ value: [Outcome]) { lock.withLock { cancellationOutcomes = value } }
    func setLegacyOnly(_ value: Bool) { lock.withLock { legacyOnly = value } }
    func holdNextUploadStart() { lock.withLock { shouldHoldNextUploadStart = true } }
    func releaseHeldUploadStarts() {
        let held = lock.withLock {
            let result = heldUploadStarts
            heldUploadStarts.removeAll()
            return result
        }
        for (operation, response) in held { operation.respond(status: 200, data: response) }
    }

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
            if path.hasPrefix("/v1/media/uploads/") {
                if lock.withLock({ legacyOnly }) {
                    operation.respond(status: 404, data: Data()); return
                }
                let components = path.split(separator: "/")
                guard components.count >= 4, let key = UUID(uuidString: String(components[3])) else {
                    operation.respond(status: 400, data: Data()); return
                }
                if lock.withLock({ cancelledUploads.contains(key) }) {
                    operation.respond(status: 410, data: errorData("media_deleted")); return
                }
                if method == "PUT" {
                    struct Input: Decodable { let mimeType: String; let byteCount: Int; let sha256: String }
                    let input = try JSONDecoder().decode(Input.self, from: body(of: request))
                    let stage = lock.withLock {
                        starts.append(key)
                        if let existing = videoStages[key] { return existing }
                        let value = VideoStage(byteCount: input.byteCount, hash: input.sha256)
                        videoStages[key] = value
                        return value
                    }
                    guard input.mimeType == "video/mp4", stage.byteCount == input.byteCount, stage.hash == input.sha256 else {
                        operation.respond(status: 409, data: errorData("idempotency_conflict")); return
                    }
                    let response = try uploadStatus(key, stage)
                    let held = lock.withLock {
                        guard shouldHoldNextUploadStart else { return false }
                        shouldHoldNextUploadStart = false
                        heldUploadStarts.append((operation, response))
                        return true
                    }
                    if !held { operation.respond(status: 200, data: response) }
                } else if method == "PATCH" {
                    guard let offset = request.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init) else {
                        operation.respond(status: 400, data: Data()); return
                    }
                    let bytes = body(of: request)
                    let (stage, outcome) = lock.withLock { () -> (VideoStage?, Outcome) in
                        offsets.append(offset)
                        uploadAttempts.append(.init(key: key, bytes: bytes, mimeType: "video/mp4"))
                        let outcome = uploadOutcomes.isEmpty ? Outcome.success : uploadOutcomes.removeFirst()
                        guard var stage = videoStages[key], stage.bytes.count == offset else { return (nil, outcome) }
                        switch outcome {
                        case .interruptedBeforeCommit, .http: break
                        case .success, .lostResponse:
                            stage.bytes.append(bytes)
                            videoStages[key] = stage
                        }
                        return (stage, outcome)
                    }
                    guard let stage else { operation.respond(status: 409, data: errorData("upload_offset_mismatch")); return }
                    switch outcome {
                    case .lostResponse, .interruptedBeforeCommit: operation.fail(URLError(.networkConnectionLost))
                    case let .http(status, code): operation.respond(status: status, data: errorData(code))
                    case .success: operation.respond(status: 200, data: try uploadStatus(key, stage))
                    }
                } else if method == "POST", path.hasSuffix("/complete") {
                    let (stage, outcome) = lock.withLock { () -> (VideoStage?, Outcome) in
                        let outcome = finishOutcomes.isEmpty ? Outcome.success : finishOutcomes.removeFirst()
                        guard var stage = videoStages[key], stage.bytes.count == stage.byteCount else { return (nil, outcome) }
                        switch outcome {
                        case .interruptedBeforeCommit, .http: break
                        case .success, .lostResponse:
                            let mediaID = stage.media?.id ?? UUID()
                            let saved = BackendMedia(id: mediaID, mimeType: "video/mp4", byteCount: stage.bytes.count,
                                path: "/v1/media/\(mediaID.uuidString.lowercased())")
                            stage.media = saved
                            media[key] = saved
                            videoStages[key] = stage
                        }
                        return (stage, outcome)
                    }
                    guard let stage else { operation.respond(status: 409, data: errorData("upload_incomplete")); return }
                    switch outcome {
                    case .lostResponse, .interruptedBeforeCommit: operation.fail(URLError(.networkConnectionLost))
                    case let .http(status, code): operation.respond(status: status, data: errorData(code))
                    case .success: operation.respond(status: 200, data: try uploadStatus(key, stage))
                    }
                } else { operation.respond(status: 500, data: Data()) }
            } else if method == "POST", path == "/v1/media" {
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
                    let outcome = uploadOutcomes.isEmpty ? Outcome.success : uploadOutcomes.removeFirst()
                    switch outcome {
                    case .success, .lostResponse: media[key] = normalized
                    case .interruptedBeforeCommit, .http: break
                    }
                    return (normalized, outcome)
                }
                switch outcome {
                case .lostResponse, .interruptedBeforeCommit: operation.fail(URLError(.networkConnectionLost))
                case let .http(status, code): operation.respond(status: status, data: errorData(code))
                case .success: operation.respond(status: 201, data: try encode(saved))
                }
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
                    let outcome = postOutcomes.isEmpty ? Outcome.success : postOutcomes.removeFirst()
                    let photos = input.mediaIds.compactMap { id in media.values.first { $0.id == id } }
                    let saved = memories[input.id] ?? BackendMemory(id: input.id, ownerId: userID,
                        owner: .init(id: userID, handle: "server_person"), kind: input.kind, visibility: input.visibility,
                        location: input.location, caption: input.caption ?? "", place: place, media: photos,
                        createdAt: captured, publishedAt: input.visibility == "public" ? captured : nil,
                        expiresAt: captured.addingTimeInterval(StoryReadKeys.freshWindow), moderationStatus: "approved")
                    switch outcome {
                    case .success, .lostResponse: memories[input.id] = saved
                    case .interruptedBeforeCommit, .http: break
                    }
                    return (saved, outcome)
                }
                switch outcome {
                case .lostResponse, .interruptedBeforeCommit: operation.fail(URLError(.networkConnectionLost))
                case let .http(status, code): operation.respond(status: status, data: errorData(code))
                case .success: operation.respond(status: 201, data: try encode(saved))
                }
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
                let outcome = lock.withLock {
                    cancellationRequestCount += 1
                    return cancellationOutcomes.isEmpty ? Outcome.success : cancellationOutcomes.removeFirst()
                }
                if case let .http(status, code) = outcome {
                    operation.respond(status: status, data: errorData(code)); return
                }
                lock.withLock { _ = cancelledUploads.insert(key); media.removeValue(forKey: key); videoStages.removeValue(forKey: key) }
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
        // Match the API's millisecond timestamps rather than dropping the
        // fractional first-tap time in this simulated response.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return try encoder.encode(value)
    }

    private func uploadStatus(_ key: UUID, _ stage: VideoStage) throws -> Data {
        try encode(BackendUploadStatus(uploadID: key, mimeType: "video/mp4", byteCount: stage.byteCount,
            receivedBytes: stage.bytes.count, chunkSize: 512 * 1_024, media: stage.media))
    }

    private func errorData(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"\(code)\"}}".utf8)
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

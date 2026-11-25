import Combine
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendProgressiveLoadingTests {
    @Test(.timeLimit(.minutes(1)))
    func metadataRefreshPublishesCompleteBatchesInsteadOfEveryOwnedRecord() async throws {
        let context = try ProgressiveLoadingContext(ownPost: true, ownArchiveContainsRecord: true,
            additionalRecordCount: 31, includesMedia: false)
        defer { context.finish() }
        let rowActions = BackendPostActionState(store: context.store, reference: .reel(context.recordID))
        var counts: [Int] = []
        var rowUpdates = 0
        let recordsObserver = context.store.$ownedMemories.dropFirst().sink { counts.append($0.count) }
        let rowObserver = rowActions.$memories.dropFirst().sink { _ in rowUpdates += 1 }
        defer { recordsObserver.cancel(); rowObserver.cancel() }

        #expect(!context.store.hasPreparedMedia(for: context.recordID), "Unknown records are not ready")
        #expect(context.store.cachedRecords(for: [context.recordID]).isEmpty)
        try await context.store.refresh()
        #expect(context.store.hasPreparedMedia(for: context.recordID), "A known no-media record is ready")
        #expect(!context.store.hasPreparedMedia(for: UUID()))
        #expect(context.store.cachedRecords(for: [context.recordID, UUID()]).map(\.id) == [context.recordID],
            "Exact-scope metadata must not discover the other 31 records")
        #expect(!counts.isEmpty)
        #expect(counts.allSatisfy { $0 == 32 }, "Subscribers must never receive a half-filled metadata batch")
        #expect(counts.count <= 8, "Refreshing 32 owned records must not emit once per record")
        #expect(rowUpdates <= 8, "An existing row's menu must not be invalidated by every other record")
        let originalIDs = Set(context.store.ownedMemories.keys)

        counts.removeAll()
        rowUpdates = 0
        try context.replaceMetadata(caption: "Changed without republishing", ownHandle: "renamed_owner")
        try await context.store.refresh()
        #expect(Set(context.store.ownedMemories.keys) == originalIDs)
        #expect(counts.allSatisfy { $0 == 32 })
        #expect(counts.count <= 8)
        #expect(rowUpdates <= 8)
        #expect(context.store.ownedMemories.values.allSatisfy {
            $0.caption == "Changed without republishing" && $0.owner.handle == "renamed_owner"
        }, "Batching must retain same-ID content and owner changes")
        #expect(rowActions.memories.first?.caption == "Changed without republishing")
        #expect(rowActions.memories.first?.owner.handle == "renamed_owner")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func oneFailedPhotoDoesNotHideLaterBatchesOrVideoAndRetryOnlyFetchesMissingMedia(isProfile: Bool) async throws {
        let context = try ProgressiveLoadingContext(extraPhotoCount: 4)
        defer { context.finish() }
        var snapshots: [BackendStore.Snapshot] = []
        let load: () async throws -> BackendStore.Snapshot = {
            if isProfile {
                return try await context.store.loadProfile(userID: context.authorID) { snapshots.append($0) }
            }
            return try await context.store.loadMap(context.region) { snapshots.append($0) }
        }
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let operation = Task { try await load() }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photoIDs = [context.photoID] + context.extraPhotoIDs
        let failedID = try #require(photoIDs.min { $0.uuidString < $1.uuidString })
        let failedPath = "/v1/media/\(failedID.uuidString.lowercased())"
        for _ in photoIDs {
            let photo = try #require(await requests.next())
            #expect(photo.request.url?.path != context.videoPath)
            if photo.request.url?.path == failedPath { photo.respond(Data(), status: 503) }
            else { photo.respond(context.photo, contentType: "image/png") }
        }
        let video = try #require(await requests.next())
        #expect(video.request.url?.path == context.videoPath,
                "A failed photo in the first batch cannot prevent later historical videos from loading")
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        do {
            _ = try await operation.value
            Issue.record("The missing photo must remain a recoverable load failure")
        } catch BackendClientError.http(let status, _, _) { #expect(status == 503) }
        let loadedIDs = Set(snapshots.last?.reels.first?.attachments.map(\.id) ?? [])
        #expect(loadedIDs == Set(photoIDs.filter { $0 != failedID } + [context.videoID]))

        let retry = Task { try await load() }
        defer { retry.cancel() }
        let missing = try #require(await requests.next())
        #expect(missing.request.url?.path == failedPath)
        missing.respond(context.photo, contentType: "image/png")
        let complete = try await retry.value
        #expect(Set(complete.reels.first?.attachments.map(\.id) ?? []) == Set(photoIDs + [context.videoID]))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [401, 403, 404, 410])
    func mediaAccessFailureStopsBeforeStartingLaterVideos(status: Int) async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        var updates = 0
        let operation = Task { try await context.store.loadMap(context.region) { _ in updates += 1 } }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(Data(), status: status)
        do {
            _ = try await operation.value
            Issue.record("An authorization or withdrawn-media response must abort preparation")
        } catch {
            if status == 401 {
                guard case BackendClientError.unauthorized = error else { throw error }
            } else {
                guard case let BackendClientError.http(actual, _, _) = error else { throw error }
                #expect(actual == status)
            }
        }
        #expect(updates == 1, "No later photo/video projection is published after access is rejected")
    }

    @Test(.timeLimit(.minutes(1)))
    func feedStoryMetadataPrecedesMediaAndNeverChangesPageIdentityAsDownloadsArrive() async throws {
        let context = try ProgressiveLoadingContext(feedContainsRecord: true)
        defer { context.finish() }
        let environment = AppEnvironment.connected(to: context.store)
        let myMap = UserMapViewModel(environment: environment, dataScope: .privateArchive)
        let profile = UserProfileViewModel(environment: environment, context: .me)
        var archiveRefreshes = 0
        var profileRefreshes = 0
        let archiveSubscription = myMap.$summary.dropFirst().sink { _ in archiveRefreshes += 1 }
        let profileSubscription = profile.$postActivities.dropFirst().sink { _ in profileRefreshes += 1 }
        defer { archiveSubscription.cancel(); profileSubscription.cancel() }
        var metadata: [[BackendMemory]] = []
        let subscription = context.store.feedRecords.sink { metadata.append($0) }
        defer { subscription.cancel() }
        let operation = Task { try await context.store.refresh() }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        let beforeAssets = try #require(context.store.feedRecords.value.first)
        #expect(beforeAssets.id == context.recordID)
        #expect(beforeAssets.media.map(\.id) == [context.videoID, context.photoID])
        #expect(context.store.feedReels.value.first?.attachments.isEmpty == true)
        #expect(!context.store.hasPreparedMedia(for: context.recordID), "Metadata alone is not media readiness")
        #expect(context.store.cachedRecords(for: [context.recordID], publicOnly: true).first?.media.map(\.id)
            == [context.videoID, context.photoID], "Cold video retains its slot before downloading")
        photo.respond(context.photo, contentType: "image/png")
        try await operation.value
        #expect(!context.store.hasPreparedMedia(for: context.recordID), "A loaded photo cannot hide a missing video")
        #expect(context.mediaRequestPaths == [context.photoPath], "Opening the feed must not download every MP4")
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        let video = try #require(await requests.next())
        #expect(context.store.feedReels.value.first?.attachments.map(\.id) == [context.photoID])
        #expect(context.store.feedRecords.value.first?.media.map(\.id) == beforeAssets.media.map(\.id))
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        _ = try await selection.value
        #expect(metadata.filter { !$0.isEmpty }.allSatisfy {
            $0.map(\.id) == [context.recordID] && $0.first?.media.map(\.id) == [context.videoID, context.photoID]
        })
        #expect(context.store.feedReels.value.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(context.store.hasPreparedMedia(for: context.recordID))
        #expect(archiveRefreshes == 1, "Other people's feed media must not rebuild MyMap")
        #expect(profileRefreshes == 1, "Other people's feed media must not rebuild the owner's Profile")
        context.store.clearLocalMedia()
        #expect(!context.store.hasPreparedMedia(for: context.recordID), "A signed-out store is never ready")
        #expect(context.store.cachedRecords(for: [context.recordID]).isEmpty)
        #expect(context.store.feedRecords.value.isEmpty, "Sign-out must clear raw metadata as well as cards")
    }

    @Test(.timeLimit(.minutes(1)))
    func ownMediaBatchesCommitOneCompleteArchiveAndProfileSnapshotEach() async throws {
        let context = try ProgressiveLoadingContext(ownPost: true, ownArchiveContainsRecord: true)
        defer { context.finish() }
        let environment = AppEnvironment.connected(to: context.store)
        let myMap = UserMapViewModel(environment: environment, dataScope: .privateArchive)
        let profile = UserProfileViewModel(environment: environment, context: .me)
        var archiveUpdates: [[UUID]] = []
        var profileUpdates: [[UUID]] = []
        let archiveSubscription = myMap.$reels.dropFirst().sink {
            archiveUpdates.append($0.first?.attachments.map(\.id) ?? [])
        }
        let profileSubscription = profile.$postActivities.dropFirst().sink { activities in
            guard case let .post(media) = activities.first?.preview else {
                profileUpdates.append([])
                return
            }
            profileUpdates.append(media.map(\.id))
        }
        defer { archiveSubscription.cancel(); profileSubscription.cancel() }
        let operation = Task { try await context.store.refresh() }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        #expect(archiveUpdates == [[]])
        #expect(profileUpdates == [[]])
        #expect(myMap.reels.first?.id == context.recordID)
        #expect(profile.postActivities.first?.id == context.recordID)
        photo.respond(context.photo, contentType: "image/png")
        try await operation.value
        #expect(context.mediaRequestPaths == [context.photoPath])
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        let video = try #require(await requests.next())
        #expect(archiveUpdates == [[], [context.photoID]])
        #expect(profileUpdates == archiveUpdates)
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        _ = try await selection.value
        #expect(archiveUpdates == [[], [context.photoID], [context.videoID, context.photoID]])
        #expect(profileUpdates == archiveUpdates, "No duplicate final refresh after the last media batch")
        // New subscribers receive the complete current value synchronously.
        let reopened = UserProfileViewModel(environment: environment, context: .me)
        #expect(reopened.postActivities.first?.id == context.recordID)
        #expect(reopened.reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        let updateCount = profileUpdates.count
        for _ in 0..<20 { _ = profile.postActivities }
        #expect(profileUpdates.count == updateCount, "Reading cached rows must not rebuild them")
    }

    @Test(.timeLimit(.minutes(1)))
    func startupSkipsHistoricalVideosAndSelectedPrivateArchiveVideoHydratesOnce() async throws {
        let context = try ProgressiveLoadingContext(ownPost: true, ownArchiveContainsRecord: true,
            additionalRecordCount: 5, uniqueVideoPerRecord: true, visibility: "private",
            publicationAge: 60 * 60 * 24 * 30)
        defer { context.finish() }
        let operation = Task { try await context.store.refresh() }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        #expect(photo.request.url?.path == context.photoPath)
        photo.respond(context.photo, contentType: "image/png")
        try await operation.value
        #expect(context.mediaRequestPaths == [context.photoPath])
        #expect(context.store.archive.privateReels.count == 6, "Skipping bytes must not omit old records")
        #expect(context.store.ownedMemories.count == 6)
        let before = try #require(context.store.ownedMemories[context.recordID])
        #expect(before.media.map(\.id) == [context.videoID, context.photoID])
        #expect(context.store.ownPublicReels.isEmpty)
        #expect(context.store.feedReels.value.isEmpty)
        #expect(context.store.cachedSnapshot(for: [context.recordID], publicOnly: true).reels.isEmpty)
        #expect(context.store.cachedRecords(for: [context.recordID], publicOnly: true).isEmpty)
        #expect(context.store.cachedRecords(for: [context.recordID]).first?.ownerId == context.store.user.id)
        #expect(!context.store.hasPreparedMedia(for: context.recordID))

        let first = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { first.cancel() }
        let video = try #require(await requests.next())
        #expect(video.request.url?.path == context.videoPath)
        let second = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { second.cancel() }
        await Task.yield()
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(secondResult.reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(context.store.hasPreparedMedia(for: context.recordID), "The owner's prepared private archive is authorized")
        _ = try await context.store.ensureMedia(for: [context.recordID])
        #expect(context.mediaRequestPaths == [context.photoPath, context.videoPath],
            "Concurrent selection and repeat opens share the same download; unrelated historical videos stay cold")
        let after = try #require(context.store.ownedMemories[context.recordID])
        #expect(after.id == before.id && after.createdAt == before.createdAt && after.publishedAt == before.publishedAt)
        #expect(after.visibility == "private")
        #expect(context.store.archive.privateReels.count == 6)
        #expect(context.store.ownPublicReels.isEmpty && context.store.feedReels.value.isEmpty)
        #expect(context.store.postFeedRecords.value.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func passiveViewportKeepsMetadataAndPhotosAndHydratesVideoOnSelection() async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        let viewport = Task { try await context.store.loadMap(context.region, includeVideos: false) }
        defer { viewport.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        let initial = try await viewport.value
        #expect(initial.reels.map(\.id) == [context.recordID])
        #expect(initial.reels.first?.attachments.map(\.id) == [context.photoID])
        #expect(context.mediaRequestPaths == [context.photoPath])
        var changedIDs = Set<UUID>()
        let observer = context.store.mediaContentChanges.sink { changedIDs.formUnion($0) }
        defer { observer.cancel() }
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        let video = try #require(await requests.next())
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        _ = try await selection.value
        #expect(changedIDs == [context.recordID])
        #expect(context.store.cachedSnapshot(for: [context.recordID], publicOnly: true)
            .reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(context.store.feedRecords.value.isEmpty, "Viewport selection must never insert a new Feed item")
    }

    @Test(.timeLimit(.minutes(1)))
    func postPaginationPreparesPhotosButDefersVideoUntilSelection() async throws {
        let context = try ProgressiveLoadingContext(postsContainsRecord: true)
        defer { context.finish() }
        let (photosReady, continuation) = AsyncStream<Void>.makeStream()
        let observer = context.store.postFeedReels.sink { reels in
            if reels.first?.attachments.map(\.id) == [context.photoID] { continuation.yield(()) }
        }
        defer { observer.cancel(); continuation.finish() }
        try await context.store.refreshPosts()
        #expect(context.store.postFeedRecords.value.map(\.id) == [context.recordID])
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        var ready = photosReady.makeAsyncIterator()
        _ = try #require(await ready.next())
        #expect(context.mediaRequestPaths == [context.photoPath])
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        let video = try #require(await requests.next())
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        _ = try await selection.value
        #expect(context.store.postFeedReels.value.first?.attachments.map(\.id) == [context.videoID, context.photoID])
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitParentSelectionHydratesBubbleWithoutPublishingPrivateSnapshotMembers() async throws {
        let context = try ProgressiveLoadingContext(feedContainsRecord: true, includesBubbleVideo: true)
        defer { context.finish() }
        let operation = Task { try await context.store.refresh() }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        try await operation.value
        #expect(context.mediaRequestPaths == [context.photoPath])
        #expect(!context.store.hasPreparedMedia(for: context.recordID))
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = try Data(contentsOf: source)
        for _ in 0..<2 {
            let video = try #require(await requests.next())
            video.respond(bytes, contentType: "video/mp4")
        }
        _ = try await selection.value
        #expect(context.store.journey(for: context.recordID, publicOnly: true)?
            .reels.first?.attachments.map(\.id) == [context.bubbleVideoID])
        #expect(context.store.cachedSnapshot(for: [context.bubbleMemberID]).reels.isEmpty)
        #expect(context.store.hasPreparedMedia(for: context.recordID), "All attached Bubble media belongs to parent readiness")
        #expect(!context.store.hasPreparedMedia(for: context.bubbleMemberID), "Private snapshot members are not standalone authorized records")
        #expect(context.store.feedRecords.value.map(\.id) == [context.recordID])
        #expect(context.store.feedReels.value.map(\.id) == [context.recordID])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func withdrawalInvalidatesDeferredSelectionWithoutResurrectingContent(deleteOwnPost: Bool) async throws {
        let context = try ProgressiveLoadingContext(ownPost: deleteOwnPost)
        defer { context.finish() }
        let viewport = Task { try await context.store.loadMap(context.region, includeVideos: false) }
        defer { viewport.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        _ = try await viewport.value
        var mediaUpdates = 0
        let observer = context.store.mediaContentChanges.sink { _ in mediaUpdates += 1 }
        defer { observer.cancel() }
        let selection = Task { try await context.store.ensureMedia(for: [context.recordID]) }
        defer { selection.cancel() }
        _ = try #require(await requests.next())
        if deleteOwnPost { try await context.store.deletePost(memoryID: context.recordID) }
        else { try await context.store.blockUser(id: context.authorID) }
        do { _ = try await selection.value; Issue.record("Withdrawal must cancel the deferred media projection") }
        catch is CancellationError {}
        #expect(mediaUpdates == 0)
        #expect(context.store.cachedSnapshot(for: [context.recordID]).reels.isEmpty)
        #expect(!context.store.hasPreparedMedia(for: context.recordID), "Deleted or blocked records are never ready")
        #expect(context.store.cachedRecords(for: [context.recordID]).isEmpty)
        #expect(try await context.store.ensureMedia(for: [context.recordID]).reels.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func mapAndProfileShowMetadataAndPhotosBeforeTheVideoFinishes(isProfile: Bool) async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        var snapshots: [BackendStore.Snapshot] = []
        let operation = Task {
            if isProfile {
                return try await context.store.loadProfile(userID: context.authorID) { snapshots.append($0) }
            }
            return try await context.store.loadMap(context.region) { snapshots.append($0) }
        }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        #expect(photo.request.url?.path == context.photoPath, "Small photos must not wait behind a full video")
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.reels.map(\.id) == [context.recordID])
        #expect(snapshots.first?.reels.first?.attachments.isEmpty == true)
        photo.respond(context.photo, contentType: "image/png")

        let video = try #require(await requests.next())
        #expect(video.request.url?.path == context.videoPath)
        #expect(video.request.value(forHTTPHeaderField: "Authorization") == "Bearer progressive-test-token")
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.reels.first?.attachments.map(\.id) == [context.photoID])
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        video.respond(try Data(contentsOf: source), contentType: "video/mp4")
        let final = try await operation.value
        // A video-first post retains its original media order when complete;
        // prioritizing the small download must not rewrite the person's Reel.
        #expect(final.reels.first?.attachments.map(\.id) == [context.videoID, context.photoID])
        #expect(snapshots.last?.reels.first?.attachments.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledMapOrProfileCannotPublishLateVideoSnapshots(isProfile: Bool) async throws {
        let context = try ProgressiveLoadingContext()
        defer { context.finish() }
        var updates = 0
        let operation = Task {
            if isProfile {
                return try await context.store.loadProfile(userID: context.authorID) { _ in updates += 1 }
            }
            return try await context.store.loadMap(context.region) { _ in updates += 1 }
        }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        let video = try #require(await requests.next())
        #expect(updates == 2)
        operation.cancel()
        video.respond(Data("cancelled transport".utf8), contentType: "video/mp4")
        do { _ = try await operation.value; Issue.record("Cancelled search must not return a stale result") }
        catch is CancellationError {}
        #expect(updates == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func withdrawalDuringDownloadCannotResurrectBlockedOrDeletedContent(deleteOwnPost: Bool) async throws {
        let context = try ProgressiveLoadingContext(ownPost: deleteOwnPost)
        defer { context.finish() }
        var updates = 0
        let operation = Task { try await context.store.loadMap(context.region) { _ in updates += 1 } }
        defer { operation.cancel() }
        var requests = context.mediaRequests.makeAsyncIterator()
        let photo = try #require(await requests.next())
        photo.respond(context.photo, contentType: "image/png")
        _ = try #require(await requests.next())
        #expect(updates == 2)
        if deleteOwnPost { try await context.store.deletePost(memoryID: context.recordID) }
        else { try await context.store.blockUser(id: context.authorID) }
        do { _ = try await operation.value; Issue.record("Withdrawal must invalidate the in-flight snapshot") }
        catch is CancellationError {}
        #expect(updates == 2)
        #expect(context.store.feedReels.value.isEmpty)
        #expect(!context.store.ownedMemories.keys.contains(context.recordID))
    }
}

@MainActor
private final class ProgressiveLoadingContext {
    let currentUserID = UUID()
    let authorID: UUID
    let recordID = UUID()
    let videoID = UUID()
    let photoID = UUID()
    let bubbleMemberID = UUID()
    let bubbleVideoID = UUID()
    let extraPhotoIDs: [UUID]
    let photo = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=")!
    let region = MKCoordinateRegion(center: .init(latitude: 37.3, longitude: -122),
                                   span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
    let mediaRequests: AsyncStream<ProgressiveMediaProtocol>
    private let continuation: AsyncStream<ProgressiveMediaProtocol>.Continuation
    private let session: URLSession
    private let replies: ProgressivePageReplies
    let store: BackendStore
    var mediaRequestPaths: [String] { replies.mediaRequestPaths }
    var photoPath: String { "/v1/media/\(photoID.uuidString.lowercased())" }
    var videoPath: String { "/v1/media/\(videoID.uuidString.lowercased())" }

    init(ownPost: Bool = false, feedContainsRecord: Bool = false, extraPhotoCount: Int = 0,
         ownArchiveContainsRecord: Bool = false, additionalRecordCount: Int = 0,
         includesMedia: Bool = true, uniqueVideoPerRecord: Bool = false,
         visibility: String = "public", publicationAge: TimeInterval = 60,
         postsContainsRecord: Bool = false, includesBubbleVideo: Bool = false) throws {
        authorID = ownPost ? currentUserID : UUID()
        extraPhotoIDs = (0..<extraPhotoCount).map { _ in UUID() }
        (mediaRequests, continuation) = AsyncStream.makeStream()
        let mediaContinuation = continuation
        let author = authorID, current = currentUserID
        // This suite tests progressive loading, not expiry. A fixed calendar
        // date quietly made only its map variant stop returning the Reel once
        // that date crossed the active-feed window.
        let publicationDate = Date.now.addingTimeInterval(-publicationAge)
        let publishedAt = publicationDate.ISO8601Format()
        let expiresAt = publicationDate.addingTimeInterval(StoryReadKeys.freshWindow).ISO8601Format()
        let photoByteCount = photo.count
        let extraMedia = extraPhotoIDs.map { id in
            ",{\"id\":\"\(id)\",\"mimeType\":\"image/png\",\"byteCount\":\(photoByteCount),\"path\":\"/v1/media/\(id.uuidString.lowercased())\"}"
        }.joined()
        let basePage = Data("""
        {"items":[{"id":"\(recordID)","ownerId":"\(author)",
        "owner":{"id":"\(author)","handle":"video_person"},"kind":"reel","visibility":"\(visibility)",
        "location":{"latitude":37.3,"longitude":-122},"caption":"A slow video","place":null,
        "media":[{"id":"\(videoID)","mimeType":"video/mp4","byteCount":1024,"path":"/v1/media/\(videoID.uuidString.lowercased())"},
        {"id":"\(photoID)","mimeType":"image/png","byteCount":\(photo.count),"path":"/v1/media/\(photoID.uuidString.lowercased())"}\(extraMedia)],
        "createdAt":"\(publishedAt)","publishedAt":"\(publishedAt)","expiresAt":"\(expiresAt)"}],"nextCursor":null}
        """.utf8)
        var pageObject = try #require(JSONSerialization.jsonObject(with: basePage) as? [String: Any])
        var record = try #require((pageObject["items"] as? [[String: Any]])?.first)
        if !includesMedia { record["media"] = [] }
        if includesBubbleVideo {
            var member = record
            member["id"] = bubbleMemberID.uuidString
            member["visibility"] = "private"
            member["media"] = [["id": bubbleVideoID.uuidString, "mimeType": "video/mp4", "byteCount": 1024,
                                "path": "/v1/media/\(bubbleVideoID.uuidString.lowercased())"]]
            record["cluster"] = ["id": recordID.uuidString, "title": "Private snapshot", "members": [member]]
        }
        var items = [record]
        for _ in 0..<additionalRecordCount {
            var extra = record
            extra["id"] = UUID().uuidString
            if uniqueVideoPerRecord, var media = extra["media"] as? [[String: Any]], !media.isEmpty {
                let id = UUID()
                media[0]["id"] = id.uuidString
                media[0]["path"] = "/v1/media/\(id.uuidString.lowercased())"
                extra["media"] = media
            }
            items.append(extra)
        }
        pageObject["items"] = items
        replies = ProgressivePageReplies(page: try JSONSerialization.data(withJSONObject: pageObject),
            currentUserID: current, authorID: author)
        let replies = self.replies
        ProgressiveMediaProtocol.install { operation in
            let path = operation.request.url?.path ?? ""
            let method = operation.request.httpMethod ?? "GET"
            if method == "GET", path.hasPrefix("/v1/media/") {
                replies.recordMediaRequest(path)
                mediaContinuation.yield(operation)
            }
            else if path == "/v1/me" {
                operation.respond(replies.currentUser)
            } else if path == "/v1/users/\(author.uuidString)" {
                operation.respond(Data("{\"user\":{\"id\":\"\(author)\",\"handle\":\"video_person\"}}".utf8))
            } else if path == "/v1/map/memories" || (feedContainsRecord && path == "/v1/feed")
                || (postsContainsRecord && path == "/v1/posts")
                || (ownArchiveContainsRecord && (path == "/v1/me/memories"
                    || path == "/v1/users/\(current.uuidString)/memories"))
                || (author != current && path == "/v1/users/\(author.uuidString)/memories") {
                operation.respond(replies.page)
            } else if method == "POST" || method == "DELETE" { operation.respond(Data("{}".utf8)) }
            else { operation.respond(Data("{\"items\":[],\"nextCursor\":null}".utf8)) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveMediaProtocol.self]
        session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://progressive-test.invalid")!, session: session)
        api.token = "progressive-test-token"
        store = BackendStore(user: .init(id: current, handle: "viewer", avatarURL: nil), api: api, automaticallySync: false)
    }

    func replaceMetadata(caption: String, ownHandle: String) throws {
        try replies.replaceMetadata(caption: caption, ownHandle: ownHandle)
    }

    func finish() {
        store.clearLocalMedia()
        continuation.finish()
        session.invalidateAndCancel()
        ProgressiveMediaProtocol.install(nil)
    }
}

private nonisolated final class ProgressivePageReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPage: Data
    private var ownHandle = "viewer"
    private var recordedMediaPaths: [String] = []
    private let currentUserID: UUID
    private let authorID: UUID

    init(page: Data, currentUserID: UUID, authorID: UUID) {
        storedPage = page
        self.currentUserID = currentUserID
        self.authorID = authorID
    }

    var page: Data { lock.withLock { storedPage } }
    var mediaRequestPaths: [String] { lock.withLock { recordedMediaPaths } }
    func recordMediaRequest(_ path: String) { lock.withLock { recordedMediaPaths.append(path) } }
    var currentUser: Data {
        lock.withLock { Data("{\"user\":{\"id\":\"\(currentUserID)\",\"handle\":\"\(ownHandle)\"}}".utf8) }
    }

    func replaceMetadata(caption: String, ownHandle: String) throws {
        try lock.withLock {
            var object = try #require(JSONSerialization.jsonObject(with: storedPage) as? [String: Any])
            let records = try #require(object["items"] as? [[String: Any]])
            object["items"] = records.map { record in
                var updated = record
                updated["caption"] = caption
                if authorID == currentUserID {
                    updated["owner"] = ["id": currentUserID.uuidString, "handle": ownHandle]
                }
                return updated
            }
            storedPage = try JSONSerialization.data(withJSONObject: object)
            self.ownHandle = ownHandle
        }
    }
}

private final class ProgressiveMediaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (ProgressiveMediaProtocol) -> Void)?
    static func install(_ value: (@Sendable (ProgressiveMediaProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(_ data: Data, contentType: String = "application/json", status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

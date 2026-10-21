import Combine
import CoreLocation
import CryptoKit
import Foundation
import MapKit
import Network
import UIKit

enum BackendPublishResult {
    case poi(RatedPOI)
    case reel(RealPost)
}

/// Adapts real server records to the existing cards. Private and public
/// projections are built independently; sharing a place never shares history.
@MainActor
final class BackendStore: ObservableObject {
    typealias Snapshot = (pois: [RatedPOI], reels: [RealPost])
    @Published private(set) var user: User
    let api: BackendAPI
    let archive: MyMapArchiveStore
    @Published private(set) var ownPublicPOIs: [RatedPOI] = []
    @Published private(set) var ownPublicReels: [RealPost] = []
    @Published var issue: String?
    let feedPOIs = CurrentValueSubject<[RatedPOI], Never>([])
    let feedReels = CurrentValueSubject<[RealPost], Never>([])
    /// Exact check-in/Reel IDs, never a shared landmark ID.
    let publicContentChanges = PassthroughSubject<Set<UUID>, Never>()
    private(set) var publicContentRevision = 0
    @Published private(set) var ownedMemories: [UUID: BackendMemory] = [:]
    @Published private(set) var pendingMemoryMutations: Set<UUID> = []
    @Published private(set) var pendingPublications: [UUID: PendingPublicationStatus] = [:]
    /// Includes cancellations still waiting for server acknowledgement.
    var hasPendingSyncWork: Bool { !localState.queued.isEmpty }
    private var privateOverrides: [UUID: BackendMemory] = [:]
    private var deletedMemoryIDs: Set<UUID> = []
    private var mediaRevision = 0
    private var knownMemories: [UUID: BackendMemory] = [:]
    private var blockedUserIDs: Set<UUID> = []
    var onSignOut: (() -> Void)?
    var onConnectionAvailable: (() -> Void)?
    private var users: [UUID: User]
    private var profileMetadata: [UUID: BackendUser] = [:]
    private var profileRevision = 0
    private var isUpdatingProfile = false
    private var knownPlaceIDs: Set<UUID> = []
    private var placeAliases: [UUID: UUID] = [:]
    private var localMedia: [UUID: URL] = [:]
    private var localPosters: [UUID: URL] = [:]
    private var uploadedMedia: [String: BackendMedia] = [:]
    private var pendingInputs: [UUID: (fingerprint: String, input: BackendMemoryInput)] = [:]
    private var refreshGeneration = 0
    private var lastRefreshAt: Date?
    private var refreshTask: (id: UUID, task: Task<Void, Error>)?
    private(set) var isActive = true
    private let mediaDirectory: URL
    private let mediaDisk: BackendMediaDisk
    private var mediaDownloads: [UUID: Task<URL, Error>] = [:]
    private let stateDisk: BackendLocalStateDisk
    private var localState: BackendLocalState
    private var stateRevision = 0
    private var syncTask: Task<Void, Never>?
    private var syncAuthorized = false
    private let automaticallySync: Bool
    private var isEnqueuing = false
    private var isSyncing = false
    private var pathMonitor: NWPathMonitor?
    private var activationSubscription: AnyCancellable?

    init(user: User, api: BackendAPI, storageDirectory: URL? = nil, automaticallySync: Bool = true) {
        self.user = user
        self.api = api
        self.automaticallySync = automaticallySync
        users = [user.id: user]
        archive = MyMapArchiveStore(currentUserID: user.id, startsEmpty: true)
        let server = api.baseURL.absoluteString
        let namespace = SHA256.hash(data: Data(server.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        mediaDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendMedia/\(user.id.uuidString)/\(namespace)", isDirectory: true)
        mediaDisk = BackendMediaDisk(directory: mediaDirectory)
        let directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendAccounts/\(user.id.uuidString)/\(namespace)", isDirectory: true)
        stateDisk = BackendLocalStateDisk(directory: directory)
        localState = BackendLocalState(ownerID: user.id, server: server,
                                      user: BackendUser(id: user.id, handle: user.handle))
    }

    func user(for id: UUID) -> User? { users[id] }

    func canonicalPlaceID(for sourceID: UUID) -> UUID? { placeAliases[sourceID] }

    /// The upload is unreferenced until the atomic profile PATCH succeeds. A
    /// lost PATCH reply may still have committed: never delete that upload.
    func updateProfile(handle: String, avatarData: Data?) async throws {
        try requireActive()
        guard !isUpdatingProfile else { throw BackendClientError.message("Your profile is already being saved.") }
        guard handle.range(of: "\\A[A-Za-z0-9_]{3,32}\\z", options: .regularExpression) != nil else {
            throw BackendClientError.message("Use 3–32 letters, numbers, or underscores for your username.")
        }
        if let avatarData, avatarData.isEmpty || avatarData.count > 10 * 1024 * 1024 {
            throw BackendClientError.message("Choose a photo smaller than 10 MB.")
        }
        isUpdatingProfile = true
        defer { isUpdatingProfile = false }
        var avatar: BackendMedia?
        if let avatarData {
            let mime = avatarData.starts(with: [137, 80, 78, 71]) ? "image/png" : "image/jpeg"
            avatar = try await api.uploadPhoto(avatarData, mimeType: mime)
            try requireActive()
        }
        let saved = try await api.updateProfile(handle: handle, avatarMediaID: avatar?.id)
        try requireActive()
        guard saved.id == user.id else { throw BackendClientError.message("The server returned a different account. Sign in again.") }
        profileRevision += 1
        invalidateRefresh()
        applyProfile(saved)
        republishUserProjections()
        localState.user = saved
        try? await persistLocalState()
        // Download the normalized server image, never the unprocessed upload.
        // A media refresh failure cannot turn a confirmed profile save into a
        // false failure (or cause a second avatar upload on an automatic retry).
        do {
            try await prepareProfileAvatar(saved)
            try requireActive()
            applyProfile(saved)
            republishUserProjections()
            issue = nil
        } catch {
            if isActive, !(error is CancellationError) {
                issue = "Your profile was saved. Couldn't load the photo; pull to refresh."
            }
        }
    }

    private func invalidateRefresh() {
        refreshGeneration += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        lastRefreshAt = nil
    }

    private func applyProfile(_ profile: BackendUser) {
        profileMetadata[profile.id] = profile
        let identity = User(id: profile.id, handle: profile.handle,
            avatarURL: profile.avatar.flatMap { localMedia[$0.id] })
        users[profile.id] = identity
        if profile.id == user.id { user = identity }
        for id in knownMemories.keys where knownMemories[id]?.ownerId == profile.id {
            knownMemories[id]?.owner = profile
        }
        for id in ownedMemories.keys where ownedMemories[id]?.ownerId == profile.id {
            ownedMemories[id]?.owner = profile
        }
    }

    private func republishUserProjections() {
        ownPublicPOIs = ownPublicPOIs.map { $0 }
        ownPublicReels = ownPublicReels.map { $0 }
        feedPOIs.send(feedPOIs.value)
        feedReels.send(feedReels.value)
    }

    private func prepareProfileAvatar(_ profile: BackendUser) async throws {
        if let avatar = profile.avatar { try await prepareMedium(avatar, contentRevision: publicContentRevision) }
    }

    func refresh() async throws {
        if let active = refreshTask {
            try await active.task.value
            return
        }
        let id = UUID()
        let task = Task { try await performRefresh() }
        refreshTask = (id, task)
        defer { if refreshTask?.id == id { refreshTask = nil } }
        try await task.value
    }

    func refreshIfNeeded() async throws {
        guard lastRefreshAt.map({ Date().timeIntervalSince($0) < 20 }) != true else { return }
        try await refresh()
    }

    private func performRefresh() async throws {
        try requireActive()
        refreshGeneration += 1
        let generation = refreshGeneration
        let identityRevision = profileRevision
        // Commit projections only after all required reads succeeded. A failed
        // refresh must not replace a good archive with an empty screen.
        async let archiveRead = api.allMemories(path: "/v1/me/memories")
        async let profileRead = api.allMemories(path: "/v1/users/\(user.id.uuidString)/memories")
        async let feedRead = api.allMemories(path: "/v1/feed")
        async let identityRead = api.me()
        let (mine, ownPublic, feed, identity) = try await (archiveRead, profileRead, feedRead, identityRead)
        guard identity.id == user.id else { throw BackendClientError.message("The server returned a different account. Sign in again.") }
        try requireActive()
        guard generation == refreshGeneration else { return }
        if identityRevision == profileRevision, !isUpdatingProfile { applyProfile(identity) }
        localState.user = profileMetadata[user.id] ?? identity
        localState.mine = currentRecords(mine)
        localState.profile = currentRecords(ownPublic, publicOnly: true)
        localState.feed = currentRecords(feed, publicOnly: true)
        let records = localState.mine + localState.profile + localState.feed
        remember(records)
        await loadCachedMedia(records, identity: localState.user)
        try requireActive()
        guard generation == refreshGeneration else { return }
        rebuildLocalProjections()
        try await persistLocalState()
        lastRefreshAt = .now
        issue = nil
        // Metadata is already visible and durable. A missing image is not a
        // failed login or an empty archive; media fills in without blocking UI.
        do {
            try await prepareProfileAvatar(identity)
            try requireActive()
            guard generation == refreshGeneration else { return }
            if identityRevision == profileRevision, !isUpdatingProfile { applyProfile(localState.user) }
            try await prepareMedia(records) { [weak self] in
                guard let self, isActive, !Task.isCancelled, generation == refreshGeneration else { return }
                rebuildLocalProjections()
            }
        } catch {
            if isActive, !(error is CancellationError) { issue = "Some photos or videos couldn't load. They will retry when you refresh." }
        }
        try requireActive()
        guard generation == refreshGeneration else { return }
        if identityRevision == profileRevision, !isUpdatingProfile { applyProfile(localState.user) }
        rebuildLocalProjections()
    }

    func loadProfile(userID: UUID, onUpdate: ((Snapshot) -> Void)? = nil) async throws -> Snapshot {
        try requireActive()
        if blockedUserIDs.contains(userID) { return ([], []) }
        let identityRevision = profileRevision
        let contentRevision = publicContentRevision
        async let recordsRead = api.allMemories(path: "/v1/users/\(userID.uuidString)/memories")
        async let identityRead = api.profile(userID: userID)
        let (records, identity) = try await (recordsRead, identityRead)
        guard identity.id == userID else { throw BackendClientError.message("The server returned a different profile.") }
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        if userID != user.id { profileMetadata[userID] = identity }
        let visible = currentRecords(records, publicOnly: true)
        remember(visible)
        await loadCachedMedia(visible, identity: identity)
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        if userID != user.id || (identityRevision == profileRevision && !isUpdatingProfile) { applyProfile(identity) }
        onUpdate?(project(visible))
        try await prepareProfileAvatar(identity)
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        if userID != user.id || (identityRevision == profileRevision && !isUpdatingProfile) { applyProfile(identity) }
        try await prepareMedia(visible) { [weak self] in
            guard let self, isActive, !Task.isCancelled, contentRevision == publicContentRevision else { return }
            onUpdate?(project(currentRecords(visible, publicOnly: true)))
        }
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        if userID != user.id || (identityRevision == profileRevision && !isUpdatingProfile) { applyProfile(identity) }
        return project(currentRecords(records, publicOnly: true))
    }

    func loadMap(_ region: MKCoordinateRegion, onUpdate: ((Snapshot) -> Void)? = nil) async throws -> Snapshot {
        try requireActive()
        func wrapped(_ longitude: Double) -> Double {
            var value = longitude
            while value > 180 { value -= 360 }
            while value < -180 { value += 360 }
            return value
        }
        let halfWidth = min(180, region.span.longitudeDelta / 2)
        let south = max(-90, region.center.latitude - region.span.latitudeDelta / 2)
        let north = min(90, region.center.latitude + region.span.latitudeDelta / 2)
        let west = halfWidth == 180 ? -180 : wrapped(region.center.longitude - halfWidth)
        let east = halfWidth == 180 ? 180 : wrapped(region.center.longitude + halfWidth)
        let records: [BackendMemory]
        do { records = try await api.allMemories(path: "/v1/map/memories?west=\(west)&east=\(east)&south=\(south)&north=\(north)") }
        catch {
            try requireActive()
            let mayUseCache: Bool
            switch error {
            case BackendClientError.message: mayUseCache = true
            case let BackendClientError.http(status, _): mayUseCache = status >= 500
            default: mayUseCache = false
            }
            guard mayUseCache else { throw error }
            return project(currentRecords(Array(knownMemories.values), publicOnly: true).filter {
                let coordinate = $0.place?.coordinate ?? $0.location
                let inLongitude = west <= east ? (west...east).contains(coordinate.longitude)
                    : coordinate.longitude >= west || coordinate.longitude <= east
                return (south...north).contains(coordinate.latitude) && inLongitude
            })
        }
        try requireActive()
        // A GET may have started before a withdrawal. Reconcile that response
        // against today's private/deleted/blocked overrides before starting a
        // media operation, preserving the filtered-return contract. From this
        // point on, a newer withdrawal cancels every progressive update.
        let contentRevision = publicContentRevision
        let visible = currentRecords(records, publicOnly: true)
        remember(visible)
        await loadCachedMedia(visible, identity: localState.user)
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        onUpdate?(project(visible))
        try await prepareMedia(visible) { [weak self] in
            guard let self, isActive, !Task.isCancelled, contentRevision == publicContentRevision else { return }
            onUpdate?(project(currentRecords(visible, publicOnly: true)))
        }
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        return project(currentRecords(records, publicOnly: true))
    }

    /// A POI row groups visits. The menu offers each of this person's visits
    /// separately so a place-level action can never withdraw someone else's post.
    func manageableMemories(for reference: JourneyFolder.MemberReference) -> [BackendMemory] {
        ownedMemories.values.filter { record in
            guard record.ownerId == user.id, !deletedMemoryIDs.contains(record.id) else { return false }
            switch reference {
            case let .reel(id): return record.kind == "reel" && record.id == id
            case let .poi(id): return record.kind == "poi" && record.place?.id == id
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func makePrivate(memoryID: UUID) async throws {
        let original = try beginMemoryMutation(memoryID)
        defer { pendingMemoryMutations.remove(memoryID) }
        let saved = try await api.makeMemoryPrivate(id: memoryID)
        try requireActive()
        guard saved.id == memoryID, saved.ownerId == user.id, saved.visibility == "private" else {
            throw BackendClientError.message("The server didn't confirm this post is private. Please refresh and retry.")
        }
        privateOverrides[memoryID] = saved
        ownedMemories[memoryID] = saved
        knownMemories[memoryID] = saved
        finishMemoryMutation(original, deleted: false)
        try? await persistLocalState()
        // Keep the existing private archive record, with its new visibility.
        let privateProjection = project([saved])
        if let reel = privateProjection.reels.first,
           archive.privateReels.contains(where: { $0.id == memoryID }) {
            archive.saveReel(reel, audience: .privateMyMap)
        }
        await refreshAfterMemoryMutation()
    }

    func deletePost(memoryID: UUID) async throws {
        if localState.queued.contains(where: { $0.id == memoryID }) {
            try await cancelQueuedPublication(id: memoryID)
            return
        }
        let original = try beginMemoryMutation(memoryID)
        defer { pendingMemoryMutations.remove(memoryID) }
        try await api.deleteMemory(id: memoryID)
        try requireActive()
        deletedMemoryIDs.insert(memoryID)
        privateOverrides.removeValue(forKey: memoryID)
        ownedMemories.removeValue(forKey: memoryID)
        knownMemories.removeValue(forKey: memoryID)
        finishMemoryMutation(original, deleted: true)
        try? await persistLocalState()
        await refreshAfterMemoryMutation()
    }

    func blockUser(id: UUID) async throws {
        try requireActive()
        guard id != user.id else { throw BackendClientError.message("You can't block your own account.") }
        try await api.block(userID: id)
        try requireActive()
        blockedUserIDs.insert(id)
        publicContentRevision += 1
        let removedRecords = knownMemories.values.filter { $0.ownerId == id }
        let ids = Set(removedRecords.map(\.id))
        var mediaIDs = Set(removedRecords.flatMap { $0.media.map(\.id) })
        if let avatar = profileMetadata[id]?.avatar { mediaIDs.insert(avatar.id) }
        refreshGeneration += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        lastRefreshAt = nil
        mediaRevision += 1
        for mediaID in mediaIDs {
            mediaDownloads.removeValue(forKey: mediaID)?.cancel()
            localMedia.removeValue(forKey: mediaID)
            localPosters.removeValue(forKey: mediaID)
        }
        mediaDisk.remove(mediaIDs)
        knownMemories = knownMemories.filter { $0.value.ownerId != id }
        profileMetadata.removeValue(forKey: id)
        users.removeValue(forKey: id)
        feedReels.send(feedReels.value.filter { $0.userId != id })
        feedPOIs.send(Self.removingMemories(ids, from: feedPOIs.value))
        publicContentChanges.send(ids)
        try? await persistLocalState()
        await refreshAfterMemoryMutation(confirmation: "This account is blocked.")
    }

    private func beginMemoryMutation(_ id: UUID) throws -> BackendMemory {
        try requireActive()
        guard let record = ownedMemories[id], record.ownerId == user.id, !deletedMemoryIDs.contains(id) else {
            throw BackendClientError.message("You can only change your own posts. Refresh and try again.")
        }
        guard pendingMemoryMutations.insert(id).inserted else {
            throw BackendClientError.message("This post is already being updated.")
        }
        return record
    }

    private func currentRecords(_ records: [BackendMemory], publicOnly: Bool = false) -> [BackendMemory] {
        records.compactMap { record in
            guard !deletedMemoryIDs.contains(record.id), !blockedUserIDs.contains(record.ownerId) else { return nil }
            let current = privateOverrides[record.id] ?? record
            return publicOnly && !Self.isPubliclyVisible(current) ? nil : current
        }
    }

    private static func isPubliclyVisible(_ record: BackendMemory) -> Bool {
        record.visibility == "public" && (record.moderationStatus == nil || record.moderationStatus == "approved")
    }

    /// Prune a single check-in from grouped places, retaining unrelated visits.
    static func removingMemories(_ ids: Set<UUID>, from places: [RatedPOI]) -> [RatedPOI] {
        places.compactMap { place in
            var result = place
            result.checkIns.removeAll { ids.contains($0.id) }
            return result.checkIns.isEmpty ? nil : result
        }
    }

    private func finishMemoryMutation(_ original: BackendMemory, deleted: Bool) {
        publicContentRevision += 1
        refreshGeneration += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        lastRefreshAt = nil
        let ids: Set<UUID> = [original.id]
        ownPublicReels.removeAll { ids.contains($0.id) }
        ownPublicPOIs = Self.removingMemories(ids, from: ownPublicPOIs)
        feedReels.send(feedReels.value.filter { !ids.contains($0.id) })
        feedPOIs.send(Self.removingMemories(ids, from: feedPOIs.value))
        archive.replaceServerRecords(
            pois: deleted ? Self.removingMemories(ids, from: archive.privatePOIs) : archive.privatePOIs,
            reels: deleted ? archive.privateReels.filter { !ids.contains($0.id) } : archive.privateReels)
        if deleted {
            if original.kind == "reel" {
                archive.removeFromPrivateArchive(.reel(original.id))
            } else if let placeID = original.place?.id,
                      !archive.privatePOIs.contains(where: { $0.id == placeID }) {
                archive.removeFromPrivateArchive(.poi(placeID))
            }
            // Shared uploaded photos may still belong to another post. Keep
            // those; purge only assets no remaining known own post references.
            let retained = Set(ownedMemories.values.flatMap { $0.media.map(\.id) }
                + profileMetadata.values.compactMap { $0.avatar?.id })
            let removed = Set(original.media.map(\.id)).subtracting(retained)
            mediaRevision += 1
            for id in removed {
                mediaDownloads.removeValue(forKey: id)?.cancel()
                localMedia.removeValue(forKey: id)
                localPosters.removeValue(forKey: id)
            }
            uploadedMedia = uploadedMedia.filter { !removed.contains($0.value.id) }
            mediaDisk.remove(removed)
        }
        publicContentChanges.send(ids)
    }

    private func refreshAfterMemoryMutation(confirmation: String = "Your post was updated.") async {
        do { try await refresh() }
        catch {
            // The mutation is already committed. Never present a successful
            // withdrawal as a failure or restore a stale public card.
            if isActive, !(error is CancellationError) {
                issue = "\(confirmation) Couldn't refresh all map data; pull to refresh."
            }
        }
    }

    func hideFromArchive(_ reference: JourneyFolder.MemberReference) async throws {
        try requireActive()
        let kind: String
        switch reference { case .poi: kind = "poi"; case .reel: kind = "reel" }
        try await api.hideArchive(kind: kind, id: reference.referencedID)
        try requireActive()
        refreshGeneration += 1
        archive.removeFromPrivateArchive(reference)
    }

    func publish(_ draft: MapTalkPublishDraft, audience: MapPublishAudience,
                 location: CLLocation, requestID: UUID) async throws -> BackendPublishResult {
        try requireActive()
        var urls: [URL] = []
        var contentTypes: [String] = []
        var posters: [URL?] = []
        var input = BackendMemoryInput(id: requestID, kind: "reel",
            visibility: audience == .livePublic ? "public" : "private",
            location: .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        switch draft {
        case let .place(place):
            input = BackendMemoryInput(id: requestID, kind: "poi", visibility: input.visibility, location: input.location)
            switch place.target {
            case let .new(name, category):
                input.place = .init(name: name, category: category.rawValue)
            case let .existing(rated):
                if knownPlaceIDs.contains(rated.poi.id) { input.placeId = rated.poi.id }
                else {
                    input.place = .init(name: rated.poi.name, category: rated.poi.category.rawValue,
                        coordinate: .init(latitude: rated.poi.coordinate.latitude, longitude: rated.poi.coordinate.longitude),
                        sourceId: rated.poi.id)
                }
            }
            if let media = place.media {
                switch media.kind {
                case let .photo(url): urls = [url]; contentTypes = ["image/jpeg"]; posters = [nil]
                case let .video(url, poster): urls = [url]; contentTypes = ["video/mp4"]; posters = [poster]
                }
            }
        case let .reel(reel):
            guard reel.bubbleSource == nil else {
                throw BackendClientError.message("Bubble publishing is not connected to the local server yet. Your draft is kept; remove the Bubble to test a photo or text Reel.")
            }
            input.caption = reel.text
            for attachment in reel.attachments {
                switch attachment.kind {
                case let .photo(url): urls.append(url); contentTypes.append("image/jpeg"); posters.append(nil)
                case let .video(url, poster): urls.append(url); contentTypes.append("video/mp4"); posters.append(poster)
                case .emoji: throw BackendClientError.message("Choose photos or videos for this Reel.")
                }
            }
        }
        // Exclude changing GPS readings from retry identity. A retry uses the
        // original sent coordinates and uploaded IDs, even after a timeout.
        var intent: [String] = [input.kind, input.visibility, input.caption ?? ""]
        intent.append(contentsOf: [input.place?.name ?? "", input.place?.category ?? ""])
        intent.append(contentsOf: [input.place?.sourceId?.uuidString ?? "", input.placeId?.uuidString ?? ""])
        intent.append(contentsOf: urls.map(\.absoluteString))
        intent.append(contentsOf: contentTypes)
        let fingerprint = intent.joined(separator: "\u{0}")
        if let pending = pendingInputs[requestID] {
            guard pending.fingerprint == fingerprint else {
                throw BackendClientError.publishPending("The pending save must be checked before changing its content.")
            }
            input = pending.input
        } else {
            for (url, contentType) in zip(urls, contentTypes) {
                guard url.isFileURL else { throw BackendClientError.message("Choose a photo or video from this device.") }
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                try requireActive()
                guard data.count <= (contentType == "video/mp4" ? 20 : 10) * 1024 * 1024 else {
                    throw BackendClientError.message("This file is too large. Choose a smaller photo or shorter video.")
                }
                let key = await Task.detached {
                    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }.value
                try requireActive()
                let media: BackendMedia
                if let previous = uploadedMedia[key] { media = previous }
                else {
                    let mime = contentType == "video/mp4" ? contentType : (data.starts(with: [137, 80, 78, 71]) ? "image/png" : "image/jpeg")
                    media = try await api.uploadMedia(data, mimeType: mime)
                    try requireActive()
                    uploadedMedia[key] = media
                }
                input.mediaIds.append(media.id)
            }
            // Duplicate visual selections must not generate a server-side
            // duplicate media ID. Keep the error actionable without data loss.
            guard Set(input.mediaIds).count == input.mediaIds.count else {
                throw BackendClientError.message("The same photo or video was selected twice. Remove one copy and retry.")
            }
            pendingInputs[requestID] = (fingerprint, input)
        }
        let saved: BackendMemory
        do {
            saved = try await api.publish(input)
        } catch let error as BackendClientError where error.confirmsPublishRejection {
            pendingInputs.removeValue(forKey: requestID)
            throw error
        } catch {
            // The server may have committed before the connection failed.
            // Keep the exact input so retrying cannot create a second post.
            throw BackendClientError.publishPending(error.localizedDescription)
        }
        try requireActive()
        // Use the submitted photos immediately; a subsequent read failure
        // cannot turn a confirmed save into a false "not published" result.
        for (index, pair) in zip(saved.media, urls).enumerated() {
            let (media, url) = pair
            localMedia[media.id] = url
            localPosters[media.id] = posters[index]
        }
        if saved.owner.id != user.id { applyProfile(saved.owner) }
        ownedMemories[saved.id] = saved
        knownMemories[saved.id] = saved
        if let place = saved.place {
            knownPlaceIDs.insert(place.id)
            if let sourceID = place.sourceId { placeAliases[sourceID] = place.id }
        }
        let projection = project([saved])
        let visibleAudience: MapPublishAudience = Self.isPubliclyVisible(saved) ? .livePublic : .privateMyMap
        // The save has succeeded even if the following refresh is offline.
        // Do not keep the composer open and invite an accidental second post.
        if let reel = projection.reels.first {
            archive.saveReel(reel, audience: visibleAudience)
            if visibleAudience == .livePublic {
                ownPublicReels.removeAll { $0.id == reel.id }
                ownPublicReels.insert(reel, at: 0)
                feedReels.send([reel] + feedReels.value.filter { $0.id != reel.id })
            }
            refreshAfterConfirmedPublish()
            return .reel(reel)
        }
        guard let newPlace = projection.pois.first else { throw BackendClientError.message("The server returned an invalid place.") }
        func merging(_ original: RatedPOI?) -> RatedPOI {
            var value = original ?? newPlace
            value.checkIns.removeAll { $0.id == saved.id }
            value.checkIns.append(contentsOf: newPlace.checkIns)
            return value
        }
        let privatePlace = merging(archive.privatePOIs.first { $0.id == newPlace.id })
        let publicPlace = visibleAudience == .livePublic ? merging(ownPublicPOIs.first { $0.id == newPlace.id }) : nil
        archive.savePOI(privatePlace, publicVersion: publicPlace, audience: visibleAudience)
        if let publicPlace {
            ownPublicPOIs.removeAll { $0.id == publicPlace.id }
            ownPublicPOIs.insert(publicPlace, at: 0)
            var activePlace = feedPOIs.value.first { $0.id == newPlace.id } ?? newPlace
            activePlace.checkIns.removeAll { $0.id == saved.id }
            activePlace.checkIns.append(contentsOf: newPlace.checkIns)
            feedPOIs.send([activePlace] + feedPOIs.value.filter { $0.id != activePlace.id })
        }
        refreshAfterConfirmedPublish()
        return .poi(publicPlace ?? privatePlace)
    }

    private func refreshAfterConfirmedPublish() {
        // Invalidate a pre-publish refresh before yielding, so an old snapshot
        // cannot erase the just-confirmed local projection.
        refreshGeneration += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        lastRefreshAt = nil
        Task { [weak self] in
            guard let self, isActive else { return }
            do { try await refresh() }
            catch { if isActive && !(error is CancellationError) { issue = error.localizedDescription } }
        }
    }

    // MARK: - Offline archive and durable publishing

    func cacheVerifiedIdentity(profile: BackendUser? = nil) async throws {
        try requireActive()
        if let profile, profile.id == user.id {
            localState.user = profile
            applyProfile(profile)
        }
        try await persistLocalState()
        resumeVerifiedConnection()
    }

    func restoreCachedState() async -> Bool {
        do {
            guard let saved = try await stateDisk.load(), saved.ownerID == user.id,
                  saved.user.id == user.id, saved.server == api.baseURL.absoluteString,
                  saved.queued.allSatisfy({ $0.record.ownerId == user.id && $0.record.id == $0.id }) else { return false }
            try requireActive()
            localState = saved
            deletedMemoryIDs = saved.deleted
            privateOverrides = Dictionary(uniqueKeysWithValues: saved.privateOverrides.map { ($0.id, $0) })
            blockedUserIDs = saved.blocked
            remember(saved.mine + saved.profile + saved.feed)
            await loadCachedMedia(saved.mine + saved.profile + saved.feed, identity: saved.user)
            try requireActive()
            applyProfile(saved.user)
            rebuildLocalProjections()
            observeConnection()
            return true
        } catch { return false }
    }

    func resumeVerifiedConnection() {
        guard isActive else { return }
        syncAuthorized = true
        observeConnection()
        startPendingSync()
    }

    func retryPendingPublications() {
        guard isActive else { return }
        for index in localState.queued.indices { localState.queued[index].failure = nil }
        updatePendingStatuses()
        Task { [weak self] in
            guard let self else { return }
            do { try await persistLocalState(); startPendingSync() }
            catch { if isActive { issue = error.localizedDescription } }
        }
    }

    private func observeConnection() {
        guard automaticallySync, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                if syncAuthorized { startPendingSync() }
                else { onConnectionAvailable?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "maptalk.connection"))
        pathMonitor = monitor
        activationSubscription = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, isActive else { return }
                    if syncAuthorized { startPendingSync() }
                    else { onConnectionAvailable?() }
                }
            }
    }

    private func persistLocalState() async throws {
        try requireActive()
        localState.deleted = deletedMemoryIDs
        localState.privateOverrides = Array(privateOverrides.values)
        localState.blocked = blockedUserIDs
        localState.mine = currentRecords(localState.mine)
        localState.profile = currentRecords(localState.profile, publicOnly: true)
        localState.feed = currentRecords(localState.feed, publicOnly: true)
        stateRevision += 1
        try await stateDisk.save(localState, revision: stateRevision)
        // No throwing cancellation check after the atomic write: callers must
        // not erase durable photo files thinking this save failed to commit.
    }

    private func remember(_ records: [BackendMemory]) {
        for record in records {
            knownMemories[record.id] = record
            if record.ownerId == user.id { ownedMemories[record.id] = record }
            else { applyProfile(record.owner) }
            if let place = record.place, record.moderationStatus != "local_pending" {
                knownPlaceIDs.insert(place.id)
                if let sourceID = place.sourceId { placeAliases[sourceID] = place.id }
            }
        }
    }

    private func loadCachedMedia(_ records: [BackendMemory], identity: BackendUser) async {
        let items = records.flatMap(\.media) + records.compactMap { $0.owner.avatar } + [identity.avatar].compactMap { $0 }
        for item in items where localMedia[item.id] == nil {
            if let url = try? await mediaDisk.cachedURL(for: item.id, mimeType: item.mimeType), isActive {
                localMedia[item.id] = url
                if item.mimeType == "video/mp4", let poster = try? await mediaDisk.cachedPosterURL(for: item.id), isActive {
                    localPosters[item.id] = poster
                }
            }
        }
    }

    private func updatePendingStatuses() {
        var statuses: [UUID: PendingPublicationStatus] = [:]
        for entry in localState.queued where !entry.cancelled {
            if let failure = entry.failure { statuses[entry.id] = .failed(failure) }
            else if pendingPublications[entry.id] == .uploading { statuses[entry.id] = .uploading }
            else { statuses[entry.id] = .waiting }
        }
        pendingPublications = statuses
    }

    private func rebuildLocalProjections() {
        guard isActive else { return }
        let queued = localState.queued.filter { !$0.cancelled && !deletedMemoryIDs.contains($0.id) }
        for entry in queued {
            for photo in entry.photos {
                localMedia[photo.id] = stateDisk.mediaURL(photo)
                let poster = stateDisk.posterURL(photo.id)
                if photo.isVideo, FileManager.default.fileExists(atPath: poster.path) { localPosters[photo.id] = poster }
            }
        }
        let queuedIDs = Set(queued.map(\.id))
        let mine = currentRecords(localState.mine).filter { !queuedIDs.contains($0.id) } + queued.map(\.record)
        remember(mine + localState.profile + localState.feed)
        let privateProjection = project(mine.sorted { $0.createdAt > $1.createdAt })
        let publicProjection = project(currentRecords(localState.profile, publicOnly: true))
        let activeProjection = project(currentRecords(localState.feed, publicOnly: true))
        archive.replaceServerRecords(pois: privateProjection.pois, reels: privateProjection.reels)
        ownPublicPOIs = publicProjection.pois
        ownPublicReels = publicProjection.reels
        feedPOIs.send(activeProjection.pois)
        feedReels.send(activeProjection.reels)
        updatePendingStatuses()
    }

    func enqueuePublish(_ draft: MapTalkPublishDraft, audience: MapPublishAudience,
                        location: CLLocation, requestID: UUID) async throws -> BackendPublishResult {
        try requireActive()
        guard !isEnqueuing else { throw BackendClientError.message("Your memory is being saved on this phone.") }
        guard !deletedMemoryIDs.contains(requestID) else { throw BackendClientError.message("This post was deleted.") }
        if let previous = localState.queued.first(where: { $0.id == requestID }) {
            return try localResult(for: previous.record)
        }
        isEnqueuing = true
        defer { isEnqueuing = false }
        let capturedAt = Date()
        let kind = if case .place = draft { "poi" } else { "reel" }
        var input = BackendMemoryInput(id: requestID, kind: kind,
            visibility: audience == .livePublic ? "public" : "private",
            location: .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        input.capturedAt = capturedAt.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var sources: [URL] = []
        var contentTypes: [String] = []
        var posters: [URL?] = []
        var place: BackendPlace?
        switch draft {
        case let .reel(reel):
            guard reel.bubbleSource == nil else {
                throw BackendClientError.message("Bubble publishing isn't available yet. Remove the Bubble to save this Reel.")
            }
            input.caption = reel.text
            for attachment in reel.attachments {
                switch attachment.kind {
                case let .photo(url): sources.append(url); contentTypes.append("image/jpeg"); posters.append(nil)
                case let .video(url, poster): sources.append(url); contentTypes.append("video/mp4"); posters.append(poster)
                case .emoji: throw BackendClientError.message("Choose photos or videos for this Reel.")
                }
            }
        case let .place(value):
            switch value.target {
            case let .new(name, category):
                // A stable source also joins subsequent offline visits to this
                // provisional place, without treating a local ID as a server ID.
                input.place = .init(name: name, category: category.rawValue, sourceId: requestID)
                place = BackendPlace(id: requestID, sourceId: requestID, name: name, category: category.rawValue, coordinate: input.location)
            case let .existing(rated):
                let canonical = placeAliases[rated.poi.id] ?? rated.poi.id
                if knownPlaceIDs.contains(canonical) { input.placeId = canonical }
                else {
                    input.place = .init(name: rated.poi.name, category: rated.poi.category.rawValue,
                        coordinate: .init(latitude: rated.poi.coordinate.latitude, longitude: rated.poi.coordinate.longitude),
                        sourceId: rated.poi.id)
                }
                place = BackendPlace(id: canonical, sourceId: rated.poi.id, name: rated.poi.name,
                    category: rated.poi.category.rawValue,
                    coordinate: .init(latitude: rated.poi.coordinate.latitude, longitude: rated.poi.coordinate.longitude))
            }
            if let media = value.media {
                switch media.kind {
                case let .photo(url): sources = [url]; contentTypes = ["image/jpeg"]; posters = [nil]
                case let .video(url, poster): sources = [url]; contentTypes = ["video/mp4"]; posters = [poster]
                }
            }
        }
        let photos = contentTypes.map { QueuedPublication.Photo(id: UUID(), mimeType: $0) }
        let record = BackendMemory(id: requestID, ownerId: user.id, owner: localState.user, kind: input.kind,
            visibility: "private", location: input.location, caption: input.caption ?? "", place: place,
            media: photos.map { BackendMedia(id: $0.id, mimeType: $0.contentType, byteCount: 0, path: "/v1/media/\($0.id.uuidString.lowercased())") },
            createdAt: capturedAt, publishedAt: nil, expiresAt: .distantFuture, moderationStatus: "local_pending")
        let entry = QueuedPublication(input: input, record: record, photos: photos)
        try await stateDisk.copyMedia(sources, items: photos, posters: posters)
        do {
            try requireActive()
            localState.queued.append(entry)
            try await persistLocalState()
        } catch {
            // Session expiry may already have persisted this intent for the
            // next sign-in. Never delete its photos after that handoff.
            if isActive {
                localState.queued.removeAll { $0.id == requestID }
                stateDisk.removePhotos(photos.map(\.id))
            }
            throw error
        }
        try requireActive()
        rebuildLocalProjections()
        let result = try localResult(for: record)
        startPendingSync()
        return result
    }

    private func localResult(for record: BackendMemory) throws -> BackendPublishResult {
        let result = project([record])
        if let reel = result.reels.first { return .reel(reel) }
        if let poi = result.pois.first { return .poi(poi) }
        throw BackendClientError.message("This memory couldn't be prepared. Try again.")
    }

    private func startPendingSync() {
        guard automaticallySync, syncAuthorized, isActive, syncTask == nil,
              localState.queued.contains(where: { $0.cancelled || $0.failure == nil }) else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            await syncPendingPublications()
            syncTask = nil
            // Bounded retries while the app is running; network/foreground
            // callbacks also resume the durable queue. No busy retry loop.
            if isActive, localState.queued.contains(where: { $0.cancelled || $0.failure == nil }) {
                syncTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, isActive else { return }
                    syncTask = nil
                    startPendingSync()
                }
            }
        }
    }

    /// Also callable by isolated tests; never retries with a new post/photo ID.
    func syncPendingPublications() async {
        guard syncAuthorized, isActive, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let ids = localState.queued.map(\.id)
        for id in ids {
            guard let entry = localState.queued.first(where: { $0.id == id }), entry.cancelled || entry.failure == nil else { continue }
            do {
                try requireActive()
                if entry.cancelled { try await finishCancelledPublication(id); continue }
                pendingPublications[id] = .uploading
                for photo in entry.photos where photo.uploaded == nil {
                    let url = stateDisk.mediaURL(photo)
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    try requireActive()
                    guard let current = localState.queued.first(where: { $0.id == id }), !current.cancelled else { break }
                    let media = try await api.uploadMedia(data, mimeType: photo.contentType, idempotencyKey: photo.id)
                    try requireActive()
                    guard let index = localState.queued.firstIndex(where: { $0.id == id }),
                          let photoIndex = localState.queued[index].photos.firstIndex(where: { $0.id == photo.id }) else { throw CancellationError() }
                    localState.queued[index].photos[photoIndex].uploaded = media
                    try await persistLocalState()
                }
                guard let index = localState.queued.firstIndex(where: { $0.id == id }) else { continue }
                if localState.queued[index].cancelled { try await finishCancelledPublication(id); continue }
                localState.queued[index].input.mediaIds = localState.queued[index].photos.compactMap { $0.uploaded?.id }
                localState.queued[index].attemptedPost = true
                try await persistLocalState()
                guard let sending = localState.queued.first(where: { $0.id == id }), !sending.cancelled else { continue }
                let saved = try await api.publish(sending.input)
                try requireActive()
                if localState.queued.first(where: { $0.id == id })?.cancelled == true {
                    try await finishCancelledPublication(id)
                    continue
                }
                // Keep a cached copy after removing durable outbox files.
                for (photo, media) in zip(sending.photos, saved.media) {
                    let url = stateDisk.mediaURL(photo)
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    localMedia[media.id] = try await mediaDisk.write(data, for: media.id, mimeType: media.mimeType)
                    if media.mimeType == "video/mp4" {
                        localPosters[media.id] = try await mediaDisk.cachedPosterURL(for: media.id)
                    }
                }
                try requireActive()
                if localState.queued.first(where: { $0.id == id })?.cancelled == true {
                    try await finishCancelledPublication(id)
                    continue
                }
                invalidateRefresh()
                if let source = sending.record.place?.id, let destination = saved.place?.id {
                    try archive.remapPOIReference(from: source, to: destination)
                    for index in localState.queued.indices where localState.queued[index].record.place?.id == source {
                        localState.queued[index].record.place = saved.place
                    }
                }
                localState.mine.removeAll { $0.id == id }
                localState.mine.insert(saved, at: 0)
                if Self.isPubliclyVisible(saved) {
                    localState.profile.removeAll { $0.id == id }
                    localState.profile.insert(saved, at: 0)
                    localState.feed.removeAll { $0.id == id }
                    localState.feed.insert(saved, at: 0)
                }
                localState.queued.removeAll { $0.id == id }
                do { try await persistLocalState() }
                catch {
                    // Disk full after a confirmed response: preserve the exact
                    // durable intent so a restart can safely reconcile it.
                    localState.queued.append(sending)
                    throw error
                }
                stateDisk.removePhotos(sending.photos.map(\.id))
                for item in sending.photos {
                    localMedia.removeValue(forKey: item.id)
                    localPosters.removeValue(forKey: item.id)
                }
                remember([saved])
                rebuildLocalProjections()
            } catch is CancellationError { return }
            catch {
                guard isActive else { return }
                if let index = localState.queued.firstIndex(where: { $0.id == id }) {
                    let permanent: Bool
                    if case let BackendClientError.http(status, _) = error {
                        permanent = [400, 403, 404, 409, 410, 413, 415, 422].contains(status)
                    } else { permanent = error is CocoaError }
                    if permanent { localState.queued[index].failure = error.localizedDescription }
                    pendingPublications[id] = permanent ? .failed(error.localizedDescription) : .waiting
                    try? await persistLocalState()
                    updatePendingStatuses()
                    if !permanent { return }
                }
            }
        }
    }

    private func cancelQueuedPublication(id: UUID) async throws {
        guard let index = localState.queued.firstIndex(where: { $0.id == id }) else { return }
        let original = localState.queued[index]
        localState.queued[index].cancelled = true
        deletedMemoryIDs.insert(id)
        do { try await persistLocalState() }
        catch {
            if let index = localState.queued.firstIndex(where: { $0.id == id }) { localState.queued[index] = original }
            deletedMemoryIDs.remove(id)
            throw error
        }
        ownedMemories.removeValue(forKey: id)
        knownMemories.removeValue(forKey: id)
        finishMemoryMutation(original.record, deleted: true)
        rebuildLocalProjections()
        startPendingSync()
    }

    private func finishCancelledPublication(_ id: UUID) async throws {
        guard let entry = localState.queued.first(where: { $0.id == id }) else { return }
        // This server-side tombstone also blocks a late POST whose response
        // was lost. A plain DELETE/404 would not prove cancellation succeeded.
        try await api.deleteMemory(id: id, cancelPending: true)
        // Resolve even uploads whose success response was lost, without
        // uploading them again or leaking their storage quota.
        for photo in entry.photos { try await api.cancelPhotoUpload(key: photo.id) }
        try requireActive()
        localState.queued.removeAll { $0.id == id }
        do { try await persistLocalState() }
        catch { localState.queued.append(entry); throw error }
        stateDisk.removePhotos(entry.photos.map(\.id))
        // Cancellation can arrive while a confirmed upload is being copied to
        // the playback cache. Remove both provisional and server media IDs.
        let cancelledMedia = Set(entry.photos.map(\.id) + entry.photos.compactMap { $0.uploaded?.id })
        for id in cancelledMedia {
            mediaDownloads.removeValue(forKey: id)?.cancel()
            localMedia.removeValue(forKey: id)
            localPosters.removeValue(forKey: id)
        }
        mediaDisk.remove(cancelledMedia)
        rebuildLocalProjections()
    }

    func clearLocalMedia(preservePendingPublications: Bool = false) {
        // The account owns a store for one signed-in lifetime. Awaited work from
        // that lifetime must never repopulate its cache after sign-out.
        isActive = false
        syncAuthorized = false
        syncTask?.cancel()
        syncTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        activationSubscription = nil
        pendingPublications.removeAll()
        let preserved = preservePendingPublications ? BackendLocalState(ownerID: user.id,
            server: api.baseURL.absoluteString, user: localState.user, queued: localState.queued,
            deleted: localState.deleted) : nil
        stateDisk.invalidate(preserving: preserved)
        localState.queued.removeAll()
        refreshTask?.task.cancel()
        refreshTask = nil
        for download in mediaDownloads.values { download.cancel() }
        mediaDownloads.removeAll()
        refreshGeneration += 1
        localMedia.removeAll()
        localPosters.removeAll()
        uploadedMedia.removeAll()
        pendingInputs.removeAll()
        ownedMemories.removeAll()
        privateOverrides.removeAll()
        deletedMemoryIDs.removeAll()
        pendingMemoryMutations.removeAll()
        knownMemories.removeAll()
        profileMetadata.removeAll()
        blockedUserIDs.removeAll()
        knownPlaceIDs.removeAll()
        placeAliases.removeAll()
        user.avatarURL = nil
        users = [user.id: user]
        archive.replaceServerRecords(pois: [], reels: [])
        ownPublicPOIs = []
        ownPublicReels = []
        feedPOIs.send([])
        feedReels.send([])
        issue = nil
        mediaDisk.invalidate()
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
    }

    private func prepareMedia(_ records: [BackendMemory], onProgress: (() -> Void)? = nil) async throws {
        try requireActive()
        let contentRevision = publicContentRevision
        var mediaByID: [UUID: BackendMedia] = [:]
        for var record in records {
            if record.ownerId == user.id, let current = profileMetadata[user.id] { record.owner = current }
            knownMemories[record.id] = record
            if record.ownerId == user.id { ownedMemories[record.id] = record }
            else { profileMetadata[record.owner.id] = record.owner }
            if let place = record.place {
                knownPlaceIDs.insert(place.id)
                if let sourceID = place.sourceId { placeAliases[sourceID] = place.id }
            }
            for media in record.media where localMedia[media.id] == nil { mediaByID[media.id] = media }
            if record.ownerId != user.id, let avatar = record.owner.avatar, localMedia[avatar.id] == nil {
                mediaByID[avatar.id] = avatar
            }
        }
        // A small fixed concurrency limit avoids both serial photo waits and
        // hundreds of simultaneous downloads for a large map viewport.
        // Complete lightweight covers first, instead of an arbitrary dictionary
        // batch mixing one small photo with several full video downloads.
        let images = mediaByID.values.filter { $0.mimeType != "video/mp4" }.sorted { $0.id.uuidString < $1.id.uuidString }
        let videos = mediaByID.values.filter { $0.mimeType == "video/mp4" }.sorted { $0.id.uuidString < $1.id.uuidString }
        for media in [images, videos] {
            for start in stride(from: 0, to: media.count, by: 4) {
                try requireActive()
                guard contentRevision == publicContentRevision else { throw CancellationError() }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for item in media[start..<min(start + 4, media.count)] {
                        group.addTask { try await self.prepareMedium(item, contentRevision: contentRevision) }
                    }
                    try await group.waitForAll()
                }
                try requireActive()
                guard contentRevision == publicContentRevision else { throw CancellationError() }
                onProgress?()
            }
        }
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        for var record in records {
            // A map/list read started before a profile PATCH can finish later.
            // Only /me or the confirmed PATCH may change our own identity.
            if record.ownerId == user.id, let current = profileMetadata[user.id] { record.owner = current }
            if record.ownerId == user.id { ownedMemories[record.id]?.owner = record.owner }
            else { applyProfile(record.owner) }
        }
    }

    private func prepareMedium(_ media: BackendMedia, contentRevision: Int) async throws {
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        let revision = mediaRevision
        guard localMedia[media.id] == nil else { return }
        let task: Task<URL, Error>
        if let existing = mediaDownloads[media.id] { task = existing }
        else {
            let disk = mediaDisk
            let api = api
            task = Task {
                if let cached = try await disk.cachedURL(for: media.id, mimeType: media.mimeType) { return cached }
                let data = try await api.downloadMedia(media)
                try Task.checkCancellation()
                return try await disk.write(data, for: media.id, mimeType: media.mimeType)
            }
            mediaDownloads[media.id] = task
        }
        do {
            let url = try await task.value
            try requireActive()
            guard revision == mediaRevision, contentRevision == publicContentRevision else { throw CancellationError() }
            localMedia[media.id] = url
            if media.mimeType == "video/mp4" {
                let poster = try await mediaDisk.cachedPosterURL(for: media.id)
                try requireActive()
                guard revision == mediaRevision, contentRevision == publicContentRevision else { throw CancellationError() }
                localPosters[media.id] = poster
            }
            mediaDownloads.removeValue(forKey: media.id)
        } catch {
            if revision == mediaRevision { mediaDownloads.removeValue(forKey: media.id) }
            throw error
        }
    }

    private func project(_ records: [BackendMemory]) -> (pois: [RatedPOI], reels: [RealPost]) {
        var places: [UUID: RatedPOI] = [:]
        var reels: [RealPost] = []
        for record in records {
            let attachments = record.media.compactMap { media -> RealPost.Attachment? in
                guard let url = localMedia[media.id] else { return nil }
                return .init(id: media.id, kind: media.mimeType == "video/mp4"
                    ? .video(url: url, poster: localPosters[media.id]) : .photo(url))
            }
            if record.kind == "reel" {
                reels.append(RealPost(id: record.id, userId: record.ownerId,
                    center: .init(latitude: record.location.latitude, longitude: record.location.longitude),
                    radiusMeters: 220, message: record.caption.isEmpty ? nil : record.caption,
                    attachments: attachments, likes: [], comments: [],
                    visibility: record.visibility == "public" ? .publicAll : .privateOnly,
                    createdAt: record.createdAt, expiresAt: record.expiresAt, publishedAt: record.publishedAt))
            } else if let place = record.place {
                var rated = places[place.id] ?? RatedPOI(
                    poi: .init(id: place.id, name: place.name,
                        coordinate: .init(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                        category: POICategory(rawValue: place.category) ?? .other),
                    highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
                    endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
                    isFavoritedByCurrentUser: false, favoritesCount: 0)
                let media = record.media.compactMap { item -> RatedPOI.Media? in
                    guard let url = localMedia[item.id] else { return nil }
                    return .init(id: item.id, kind: item.mimeType == "video/mp4"
                        ? .video(url: url, poster: localPosters[item.id]) : .photo(url))
                }
                rated.checkIns.append(.init(id: record.id, userId: record.ownerId, createdAt: record.createdAt,
                    endorsement: nil, media: media, tag: nil, publishedAt: record.publishedAt))
                places[place.id] = rated
            }
        }
        return (Array(places.values).sorted { $0.poi.name < $1.poi.name }, reels)
    }
}

@MainActor
final class BackendPOIRepository: POIRepository, ActivePOIRepository {
    let store: BackendStore
    init(store: BackendStore) { self.store = store }
    func active(in region: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> { store.feedPOIs.eraseToAnyPublisher() }
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Deferred { [store] in
            Future { promise in
                Task { @MainActor in
                    do {
                        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
                        promise(.success(try await store.loadMap(region).pois))
                    } catch { if store.isActive { store.issue = error.localizedDescription }; promise(.success([])) }
                }
            }
        }.eraseToAnyPublisher()
    }
}

@MainActor
final class BackendRealRepository: RealRepository {
    let store: BackendStore
    init(store: BackendStore) { self.store = store }
    func active(in rect: MKMapRect?) -> AnyPublisher<[RealPost], Never> {
        guard let rect else { return store.feedReels.eraseToAnyPublisher() }
        return Deferred { [store] in
            Future { promise in
                Task { @MainActor in
                    do { promise(.success(try await store.loadMap(MKCoordinateRegion(rect)).reels)) }
                    catch { if store.isActive { store.issue = error.localizedDescription }; promise(.success([])) }
                }
            }
        }.eraseToAnyPublisher()
    }
}

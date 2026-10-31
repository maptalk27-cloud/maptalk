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
    /// Authoritative Feed metadata, independent of viewport queries and local
    /// media readiness. A story's pages must not appear/disappear as assets load.
    let feedRecords = CurrentValueSubject<[BackendMemory], Never>([])
    /// Exact check-in/Reel IDs, never a shared landmark ID.
    let publicContentChanges = PassthroughSubject<Set<UUID>, Never>()
    private(set) var publicContentRevision = 0
    private let placeHistoryScopeID = UUID()
    @Published private(set) var ownedMemories: [UUID: BackendMemory] = [:]
    @Published private(set) var pendingMemoryMutations: Set<UUID> = []
    @Published private(set) var pendingPublications: [UUID: PendingPublicationStatus] = [:]
    @Published private(set) var publicationProgress: [UUID: Double] = [:]
    @Published private var commentThreads: [BackendCommentTarget: [BackendComment]] = [:]
    private var commentThreadRevisions: [BackendCommentTarget: Int] = [:]
    /// Includes cancellations still waiting for server acknowledgement.
    var hasPendingSyncWork: Bool { !localState.queued.isEmpty }
    private var privateOverrides: [UUID: BackendMemory] = [:]
    private var deletedMemoryIDs: Set<UUID> = []
    private var mediaRevision = 0
    private var knownMemories: [UUID: BackendMemory] = [:]
    private var mapExcludedMemoryIDs: Set<UUID> = []
    /// Viewport absence is a map-only eligibility rule, never archive deletion.
    var excludedMapMemoryIDs: Set<UUID> { mapExcludedMemoryIDs }
    private var mapCacheRevision = 0
    private var blockedUserIDs: Set<UUID> = []
    var onSignOut: (() -> Void)?
    var onConnectionAvailable: (() -> Void)?
    private var users: [UUID: User]
    private var profileMetadata: [UUID: BackendUser] = [:]
    private var profileRevision = 0
    private var isUpdatingProfile = false
    private var knownPlaceIDs: Set<UUID> = []
    private var placeAliases: [UUID: UUID] = [:]
    /// Fresh directory categories improve this session's picker presentation,
    /// without rewriting shared places or changing check-in distance policy.
    private var selectionDirectoryCategories: [UUID: POICategory] = [:]
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
    private var syncRetryTask: Task<Void, Never>?
    private var syncRetryCounts: [UUID: Int] = [:]
    private var syncRetryDates: [UUID: Date] = [:]
    private var currentSyncID: UUID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundExecutionExpired = false
    private var connectionAvailable: Bool?
    private var syncAuthorized = false
    private let automaticallySync: Bool
    private let observesConnectivity: Bool
    private let retryDelay: @Sendable (Int) -> TimeInterval
    private var isEnqueuing = false
    private var isSyncing = false
    private var pathMonitor: NWPathMonitor?
    private var activationSubscription: AnyCancellable?

    init(user: User, api: BackendAPI, storageDirectory: URL? = nil, automaticallySync: Bool = true,
         observesConnectivity: Bool = true,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval = { min(60, pow(2, Double($0))) }) {
        self.user = user
        self.api = api
        self.automaticallySync = automaticallySync
        self.observesConnectivity = observesConnectivity
        self.retryDelay = retryDelay
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

    /// A cluster is reachable only through its authorized parent Reel. Never
    /// register its private source snapshots as independent map/feed records.
    func journey(for id: UUID, publicOnly: Bool = false) -> JourneyPost? {
        guard isActive, let known = knownMemories[id],
              let parent = currentRecords([known], publicOnly: publicOnly).first,
              parent.ownerId == user.id || Self.isPubliclyVisible(parent),
              let cluster = validatedCluster(in: parent) else { return nil }
        let members = cluster.members.map { member in
            var snapshot = member
            snapshot.cluster = nil
            return snapshot
        }
        let projection = project(members)
        var references: [JourneyFolder.MemberReference] = []
        for member in members {
            let reference: JourneyFolder.MemberReference?
            if member.kind == "reel" { reference = .reel(member.id) }
            else { reference = member.place.map { .poi($0.id) } }
            if let reference, !references.contains(reference) { references.append(reference) }
        }
        return JourneyPost(id: cluster.id, userId: parent.ownerId, title: cluster.title, content: "",
            coordinate: .init(latitude: parent.location.latitude, longitude: parent.location.longitude),
            createdAt: parent.activityDate, orderedMemberReferences: references,
            reels: projection.reels, pois: projection.pois, likes: [], comments: [])
    }

    private func validatedCluster(in parent: BackendMemory) -> BackendCluster? {
        guard parent.kind == "reel", let cluster = parent.cluster, cluster.id == parent.id,
              (1...50).contains(cluster.members.count),
              Set(cluster.members.map(\.id)).count == cluster.members.count,
              cluster.members.allSatisfy({
                  $0.id != parent.id && $0.ownerId == parent.ownerId && $0.owner.id == parent.ownerId
                      && ($0.kind == "reel" || ($0.kind == "poi" && $0.place != nil))
              }) else { return nil }
        return cluster
    }

    private func rebuildClusterCatalogs() {
        let privateIDs = Set(archive.privateReels.map(\.id))
        let records = currentRecords(Array(knownMemories.values)).sorted { $0.activityDate > $1.activityDate }
        archive.replaceServerBubbles(
            privateBubbles: records.filter { $0.ownerId == user.id && privateIDs.contains($0.id) }
                .compactMap { journey(for: $0.id) },
            publicBubbles: records.compactMap { journey(for: $0.id, publicOnly: true) })
    }

    /// Freeze selection before touching the network. A POI selection means
    /// this person's exact visits, not the shared place or somebody else's
    /// visits. Pending visit IDs are stable even if their place is remapped.
    private func makeClusterSelection(_ source: MapTalkReelBubbleSource, parentID: UUID)
        throws -> (input: BackendClusterInput, snapshot: BackendCluster) {
        let references: [JourneyFolder.MemberReference]
        let title: String
        switch source {
        case let .memories(selected):
            references = selected
            title = "Bubble"
        case let .folder(id):
            guard let folder = archive.journeyFolders.first(where: { $0.id == id && $0.userId == user.id }) else {
                throw BackendClientError.message("This collection is no longer available. Choose its memories again.")
            }
            references = folder.memberReferences
            let trimmed = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? "Bubble" : trimmed
        }
        guard title.utf16.count <= 160 else {
            throw BackendClientError.message("Keep the collection title under 160 characters.")
        }
        var members: [BackendMemory] = []
        var seen = Set<UUID>()
        for reference in references {
            let available: Bool
            switch reference {
            case let .reel(id): available = archive.privateReels.contains { $0.id == id && $0.userId == user.id }
            case let .poi(id): available = archive.privatePOIs.contains { $0.id == id }
            }
            let selected = manageableMemories(for: reference).sorted {
                $0.activityDate == $1.activityDate ? $0.id.uuidString < $1.id.uuidString : $0.activityDate > $1.activityDate
            }
            guard available, !selected.isEmpty else {
                throw BackendClientError.message("A selected memory is no longer available. Choose the cluster again.")
            }
            for var member in selected where seen.insert(member.id).inserted {
                guard member.id != parentID, member.ownerId == user.id,
                      member.moderationStatus != "rejected",
                      !localState.queued.contains(where: { $0.id == member.id && $0.cancelled }) else {
                    throw BackendClientError.message("A selected memory can no longer be shared.")
                }
                // V1 snapshots never recursively include another cluster.
                member.cluster = nil
                members.append(member)
            }
        }
        guard !members.isEmpty, members.count <= 50 else {
            throw BackendClientError.message("Choose between 1 and 50 memories for this cluster. Each place visit counts as one memory.")
        }
        return (.init(title: title, memoryIds: members.map(\.id)),
                .init(id: parentID, title: title, members: members))
    }

    /// Comments belong to an existing public post/place, never to a new visit.
    /// Expiry only removes active-map emphasis; it does not close discussion.
    func canComment(on target: BackendCommentTarget) -> Bool {
        guard isActive, api.token != nil else { return false }
        return currentRecords(Array(knownMemories.values), publicOnly: true).contains { record in
            switch target {
            case let .memory(id): return record.id == id
            case let .place(id): return record.kind == "poi" && record.place?.id == id
            }
        }
    }

    func comments(for target: BackendCommentTarget) -> [BackendComment] {
        guard canComment(on: target) else { return [] }
        return (commentThreads[target] ?? []).filter { !blockedUserIDs.contains($0.userId) }
    }

    func cachedCommentCount(for target: BackendCommentTarget) -> Int? {
        guard canComment(on: target), commentThreads[target] != nil else { return nil }
        return comments(for: target).count
    }

    func loadComments(for target: BackendCommentTarget) async throws {
        try requireActive()
        guard canComment(on: target) else { return }
        let revision = publicContentRevision
        let threadRevision = commentThreadRevisions[target, default: 0]
        let originalIDs = Set((commentThreads[target] ?? []).map(\.id))
        let loaded: [BackendComment]
        do { loaded = try await api.comments(for: target) }
        catch {
            if isActive, revision == publicContentRevision,
               threadRevision == commentThreadRevisions[target, default: 0],
               case let BackendClientError.http(status, _, _) = error,
               status == 403 || status == 404 || status == 410 {
                commentThreads.removeValue(forKey: target)
            }
            throw error
        }
        try requireActive()
        guard revision == publicContentRevision, canComment(on: target) else { throw CancellationError() }
        // A read that started before Send must not erase its confirmed reply.
        let justSent = (commentThreads[target] ?? []).filter { !originalIDs.contains($0.id) }
        cacheComments(loaded + justSent, for: target)
        await prepareCommentAvatars(loaded, for: target, revision: revision)
    }

    @discardableResult
    func addComment(to target: BackendCommentTarget, text: String, requestID: UUID) async throws -> BackendComment {
        try requireActive()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 1_000 else {
            throw BackendClientError.message("Write a comment of up to 1,000 characters.")
        }
        guard canComment(on: target) else {
            throw BackendClientError.message("This post is no longer available for comments.")
        }
        let revision = publicContentRevision
        let saved = try await api.addComment(to: target, text: trimmed, requestID: requestID)
        try requireActive()
        guard revision == publicContentRevision, canComment(on: target) else { throw CancellationError() }
        guard saved.id == requestID, saved.userId == user.id, saved.author.id == user.id, saved.text == trimmed else {
            throw BackendClientError.message("Your comment wasn't confirmed. Please try again.")
        }
        cacheComments((commentThreads[target] ?? []) + [saved], for: target)
        return saved
    }

    private func cacheComments(_ comments: [BackendComment], for target: BackendCommentTarget) {
        var unique: [UUID: BackendComment] = [:]
        for comment in comments where comment.userId == comment.author.id && !blockedUserIDs.contains(comment.userId) {
            unique[comment.id] = comment
            if comment.userId != user.id { applyProfile(comment.author) }
        }
        commentThreads[target] = unique.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        commentThreadRevisions[target, default: 0] += 1
    }

    private func prepareCommentAvatars(_ comments: [BackendComment], for target: BackendCommentTarget,
                                       revision: Int) async {
        var authors: [UUID: BackendUser] = [:]
        for comment in comments where comment.userId != user.id && !blockedUserIDs.contains(comment.userId) {
            if let avatar = comment.author.avatar, localMedia[avatar.id] == nil {
                authors[comment.author.id] = comment.author
            }
        }
        let profiles = Array(authors.values)
        for start in stride(from: 0, to: profiles.count, by: 4) {
            guard isActive, !Task.isCancelled, revision == publicContentRevision, canComment(on: target) else { return }
            let batch = Array(profiles[start..<min(start + 4, profiles.count)])
            await withTaskGroup(of: Void.self) { group in
                for author in batch {
                    group.addTask { try? await self.prepareProfileAvatar(author) }
                }
            }
            guard isActive, !Task.isCancelled, revision == publicContentRevision, canComment(on: target) else { return }
            for author in batch { applyProfile(author) }
            // Text is already visible. A missing photo must never turn a
            // successful comment read into a failed discussion load.
            if let comments = commentThreads[target] { commentThreads[target] = comments }
        }
    }

    func canonicalPlaceID(for sourceID: UUID) -> UUID? { placeAliases[sourceID] }

    /// The server's stored classification defines the allowed publish radius
    /// for an existing place. Apple may have richer metadata now, but that does
    /// not silently upgrade a legacy canonical place or its publication rules.
    func canonicalPlaceForSelection(_ poi: POI, fromDirectory: Bool = false) -> POI {
        let canonicalID = placeAliases[poi.id] ?? poi.id
        guard knownPlaceIDs.contains(canonicalID) else { return poi }
        let stored = knownMemories.values
            .filter { $0.place?.id == canonicalID && $0.moderationStatus != "local_pending" }
            .max { $0.createdAt < $1.createdAt }?.place
        if fromDirectory, poi.category != .other,
           stored?.sourceId == poi.id, placeAliases[poi.id] == canonicalID {
            selectionDirectoryCategories[canonicalID] = poi.category
        }
        return POI(id: canonicalID, name: stored?.name ?? poi.name,
            coordinate: stored.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
                ?? poi.coordinate,
            category: selectionDirectoryCategories[canonicalID]
                ?? stored.flatMap { POICategory(rawValue: $0.category) } ?? poi.category,
            directoryKind: (stored?.directoryKind).flatMap(POIDirectoryKind.init(rawValue:)))
    }

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
        publishFeedRecords()
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
        let mapRevision = mapCacheRevision
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
        restoreMapEligibility(from: localState.feed + localState.profile, ifRevision: mapRevision)
        let records = localState.mine + localState.profile + localState.feed
        remember(records)
        publishFeedRecords()
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
        let mapRevision = mapCacheRevision
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
        if restoreMapEligibility(from: visible, ifRevision: mapRevision) {
            try? await persistLocalState()
            try requireActive()
            guard contentRevision == publicContentRevision else { throw CancellationError() }
        }
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

    struct PlaceHistoryPage {
        let placeID: UUID
        let place: RatedPOI?
        let nextCursor: String?
        let revision: Int
        fileprivate let scopeID: UUID
        fileprivate let records: [BackendMemory]
        fileprivate let requestedCursors: Set<String>
    }

    /// Each deliberate request appends at most 12 public visits by place ID.
    /// Only that page's media is prepared; older pages require another action.
    /// History never enters the Feed or adopts a partial viewport fallback.
    func loadPlaceHistory(placeID: UUID, after previous: PlaceHistoryPage? = nil,
                          onUpdate: ((PlaceHistoryPage) -> Void)? = nil) async throws -> PlaceHistoryPage {
        try requireActive()
        let revision = publicContentRevision
        if let previous {
            guard previous.placeID == placeID, previous.revision == revision,
                  previous.scopeID == placeHistoryScopeID else { throw CancellationError() }
            guard previous.nextCursor != nil else { return previous }
        }
        let cursor = previous?.nextCursor
        let page = try await api.placeMemories(placeID: placeID, cursor: cursor)
        try requireActive()
        guard revision == publicContentRevision else { throw CancellationError() }
        var requestedCursors = previous?.requestedCursors ?? []
        if let cursor { requestedCursors.insert(cursor) }
        guard page.nextCursor.map({ !$0.isEmpty && !requestedCursors.contains($0) }) ?? true else {
            throw BackendClientError.message("The server returned a repeated page. Please retry.")
        }
        // Reject malformed cross-place responses rather than showing another
        // place's visits under the requested place name.
        guard page.items.allSatisfy({ $0.kind == "poi" && $0.place?.id == placeID }) else {
            throw BackendClientError.message("Couldn't load this place. Please try again.")
        }
        let newRecords = currentRecords(page.items, publicOnly: true)
        let incomingIDs = Set(page.items.map(\.id))
        let priorRecords = (previous?.records ?? []).filter { !incomingIDs.contains($0.id) }
        let visible = currentRecords(priorRecords + newRecords, publicOnly: true)
        remember(newRecords)
        await loadCachedMedia(newRecords, identity: localState.user)
        try requireActive()
        guard revision == publicContentRevision else { throw CancellationError() }
        func snapshot() -> PlaceHistoryPage {
            let records = currentRecords(visible, publicOnly: true)
            return PlaceHistoryPage(placeID: placeID,
                place: project(records).pois.first { $0.id == placeID }, nextCursor: page.nextCursor,
                revision: revision, scopeID: placeHistoryScopeID,
                records: records, requestedCursors: requestedCursors)
        }
        onUpdate?(snapshot())
        try await prepareMedia(newRecords) { [weak self] in
            guard let self, isActive, !Task.isCancelled, revision == publicContentRevision else { return }
            onUpdate?(snapshot())
        }
        try requireActive()
        guard revision == publicContentRevision else { throw CancellationError() }
        return snapshot()
    }

    /// An authorized metadata page remains useful when a later photo
    /// or video cannot download. Permission failures and invalidated reads are
    /// different: neither may retain an older place under a verified label.
    static func canRetainVerifiedPlaceHistory(after error: Error, hasVerifiedMetadata: Bool,
                                               requestRevision: Int, currentRevision: Int,
                                               isActive: Bool) -> Bool {
        guard hasVerifiedMetadata, isActive, requestRevision == currentRevision,
              !(error is CancellationError) else { return false }
        if let clientError = error as? BackendClientError {
            switch clientError {
            case .unauthorized, .publishPending:
                return false
            case let .http(status, _, _):
                return status == 408 || status == 429 || status >= 500
            case .message:
                // URLSession transport errors are intentionally wrapped in a
                // user-safe message. Only allow this after metadata succeeded.
                return true
            }
        }
        // This stage can also fail while decoding a local video poster or
        // writing media to the cache. That does not revoke the public records.
        return true
    }

    func loadMap(_ region: MKCoordinateRegion, onUpdate: ((Snapshot) -> Void)? = nil) async throws -> Snapshot {
        try requireActive()
        let mapRevision = mapCacheRevision
        let previouslyKnownIDs = Set(knownMemories.keys)
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
        func isInViewport(_ record: BackendMemory) -> Bool {
            let coordinate = record.place?.coordinate ?? record.location
            let inLongitude = west <= east ? (west...east).contains(coordinate.longitude)
                : coordinate.longitude >= west || coordinate.longitude <= east
            return (south...north).contains(coordinate.latitude) && inLongitude
        }
        let records: [BackendMemory]
        do { records = try await api.allMemories(path: "/v1/map/memories?west=\(west)&east=\(east)&south=\(south)&north=\(north)") }
        catch {
            try requireActive()
            let mayUseCache: Bool
            switch error {
            case BackendClientError.message: mayUseCache = true
            case let BackendClientError.http(status, _, _): mayUseCache = status >= 500
            default: mayUseCache = false
            }
            guard mayUseCache else { throw error }
            return project(currentMapRecords(Array(knownMemories.values)).filter(isInViewport))
        }
        try requireActive()
        // A GET may have started before a withdrawal. Reconcile that response
        // against today's private/deleted/blocked overrides before starting a
        // media operation, preserving the filtered-return contract. From this
        // point on, a newer withdrawal cancels every progressive update.
        let contentRevision = publicContentRevision
        let visible = currentRecords(records, publicOnly: true)
        // allMemories exhausts nextCursor before returning. A failed/partial
        // page never reaches this replacement, and absence only affects this
        // viewport's map eligibility, never the person's archive or profile.
        if mapRevision == mapCacheRevision {
            let returnedIDs = Set(visible.map(\.id))
            let absentIDs = Set(knownMemories.values.filter {
                previouslyKnownIDs.contains($0.id) && Self.isPubliclyVisible($0)
                    && isInViewport($0) && !returnedIDs.contains($0.id)
            }.map(\.id))
            mapExcludedMemoryIDs.formUnion(absentIDs)
            mapExcludedMemoryIDs.subtract(returnedIDs)
            mapCacheRevision += 1
            try? await persistLocalState()
            try requireActive()
            guard contentRevision == publicContentRevision else { throw CancellationError() }
        }
        remember(visible)
        await loadCachedMedia(visible, identity: localState.user)
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        onUpdate?(project(currentMapRecords(visible)))
        try await prepareMedia(visible) { [weak self] in
            guard let self, isActive, !Task.isCancelled, contentRevision == publicContentRevision else { return }
            onUpdate?(project(currentMapRecords(visible)))
        }
        try requireActive()
        guard contentRevision == publicContentRevision else { throw CancellationError() }
        return project(currentMapRecords(records))
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
        }.sorted { $0.activityDate > $1.activityDate }
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

    /// Editing changes this record in place; it is not a new publication and
    /// must not restart the active-map clock. A queued upload remains immutable
    /// until the server confirms it, because its original request may be live.
    func updateCaption(memoryID: UUID, caption: String) async throws -> BackendMemory {
        let original = try beginMemoryMutation(memoryID)
        defer { pendingMemoryMutations.remove(memoryID) }
        guard original.kind == "reel", !localState.queued.contains(where: { $0.id == memoryID }) else {
            throw BackendClientError.message("You can edit this reel after it finishes sharing.")
        }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 2200, !text.isEmpty || !original.media.isEmpty || original.cluster != nil else {
            throw BackendClientError.message(text.isEmpty ? "Keep a caption on a text-only reel." : "Keep the caption under 2,200 characters.")
        }
        let saved = try await api.updateMemoryCaption(id: memoryID, caption: text)
        try requireActive()
        guard saved.id == memoryID, saved.ownerId == user.id, saved.kind == "reel",
              saved.caption == text, saved.visibility == original.visibility,
              saved.createdAt == original.createdAt, saved.publishedAt == original.publishedAt,
              saved.media.map(\.id) == original.media.map(\.id),
              saved.cluster?.id == original.cluster?.id,
              saved.cluster?.members.map(\.id) == original.cluster?.members.map(\.id) else {
            throw BackendClientError.message("The edit wasn't confirmed. Your text is kept here; please try again.")
        }
        // Invalidate reads begun before PATCH so they cannot roll the card back.
        publicContentRevision += 1
        refreshGeneration += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        lastRefreshAt = nil
        knownMemories[memoryID] = saved
        ownedMemories[memoryID] = saved
        if privateOverrides[memoryID] != nil { privateOverrides[memoryID] = saved }
        localState.mine = localState.mine.map { $0.id == memoryID ? saved : $0 }
        localState.profile = localState.profile.map { $0.id == memoryID ? saved : $0 }
        localState.feed = localState.feed.map { $0.id == memoryID ? saved : $0 }
        rebuildLocalProjections()
        // The server already committed. A local cache-write error must not
        // label a successful edit as failed or discard the confirmed text.
        do { try await persistLocalState() }
        catch { issue = "Your edit is saved. Its offline copy will update when you refresh." }
        return saved
    }

    func deletePosts(memoryIDs: [UUID]) async throws {
        var completed = false
        var seen = Set<UUID>()
        do {
            for id in memoryIDs where seen.insert(id).inserted {
                try await deletePost(memoryID: id, refreshAfterward: false)
                completed = true
            }
        } catch {
            if completed { await refreshAfterMemoryMutation() }
            throw error
        }
        if completed { await refreshAfterMemoryMutation() }
    }

    func deletePost(memoryID: UUID, refreshAfterward: Bool = true) async throws {
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
        if refreshAfterward { await refreshAfterMemoryMutation() }
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
        var mediaIDs = Set(removedRecords.flatMap { $0.attachedMedia.map(\.id) })
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
        rebuildClusterCatalogs()
        profileMetadata.removeValue(forKey: id)
        users.removeValue(forKey: id)
        commentThreads = commentThreads.reduce(into: [:]) { result, entry in
            if canComment(on: entry.key) {
                result[entry.key] = entry.value.filter { $0.userId != id }
            }
        }
        feedReels.send(feedReels.value.filter { $0.userId != id })
        feedPOIs.send(Self.removingMemories(ids, from: feedPOIs.value))
        publishFeedRecords()
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

    private static func publicExpiry(for record: BackendMemory) -> Date {
        guard record.visibility == "public", record.moderationStatus != "local_pending" else { return record.expiresAt }
        // Normalize pre-72-hour disk snapshots too; publication, not capture,
        // starts the public clock. Queued local previews keep their own lifetime.
        return record.activityDate.addingTimeInterval(StoryReadKeys.freshWindow)
    }

    private func currentMapRecords(_ records: [BackendMemory]) -> [BackendMemory] {
        currentRecords(records, publicOnly: true).filter {
            !mapExcludedMemoryIDs.contains($0.id)
                && ($0.kind != "reel" || Self.publicExpiry(for: $0) > .now)
        }
    }

    @discardableResult
    private func restoreMapEligibility(from records: [BackendMemory], ifRevision revision: Int) -> Bool {
        // A fresh feed/profile response can confirm public visibility again.
        // A read started before a newer viewport result may not undo its absence.
        guard revision == mapCacheRevision else { return false }
        let ids = Set(currentRecords(records, publicOnly: true).map(\.id))
        guard !mapExcludedMemoryIDs.isDisjoint(with: ids) else { return false }
        mapExcludedMemoryIDs.subtract(ids)
        mapCacheRevision += 1
        return true
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
        commentThreads.removeValue(forKey: .memory(original.id))
        if let placeID = original.place?.id, !canComment(on: .place(placeID)) {
            commentThreads.removeValue(forKey: .place(placeID))
        }
        let ids: Set<UUID> = [original.id]
        ownPublicReels.removeAll { ids.contains($0.id) }
        ownPublicPOIs = Self.removingMemories(ids, from: ownPublicPOIs)
        feedReels.send(feedReels.value.filter { !ids.contains($0.id) })
        feedPOIs.send(Self.removingMemories(ids, from: feedPOIs.value))
        publishFeedRecords()
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
            let retained = Set(ownedMemories.values.flatMap { $0.attachedMedia.map(\.id) }
                + profileMetadata.values.compactMap { $0.avatar?.id })
            let removed = Set(original.attachedMedia.map(\.id)).subtracting(retained)
            mediaRevision += 1
            for id in removed {
                mediaDownloads.removeValue(forKey: id)?.cancel()
                localMedia.removeValue(forKey: id)
                localPosters.removeValue(forKey: id)
            }
            uploadedMedia = uploadedMedia.filter { !removed.contains($0.value.id) }
            mediaDisk.remove(removed)
        }
        rebuildClusterCatalogs()
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
        let publicationDate = Date()
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
                        sourceId: rated.poi.id, directoryKind: rated.poi.directoryKind?.rawValue)
                }
            }
            if let media = place.media {
                switch media.kind {
                case let .photo(url): urls = [url]; contentTypes = ["image/jpeg"]; posters = [nil]
                case let .video(url, poster): urls = [url]; contentTypes = ["video/mp4"]; posters = [poster]
                }
            }
        case let .reel(reel):
            if let source = reel.bubbleSource {
                let cluster = try makeClusterSelection(source, parentID: requestID).input
                input.cluster = cluster
                guard !localState.queued.contains(where: { cluster.memoryIds.contains($0.id) }) else {
                    throw BackendClientError.message("The selected memories are still uploading. Keep this draft and try again when they finish.")
                }
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
        input.capturedAt = publicationDate.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        // Exclude changing GPS readings and the new attempt's clock from retry identity. A retry uses the
        // original sent coordinates and uploaded IDs, even after a timeout.
        let fingerprint = Self.publicationFingerprint(for: input, urls: urls, contentTypes: contentTypes)
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
        if visibleAudience == .livePublic {
            localState.feed.removeAll { $0.id == saved.id }
            localState.feed.insert(saved, at: 0)
            publishFeedRecords()
        }
        // The save has succeeded even if the following refresh is offline.
        // Do not keep the composer open and invite an accidental second post.
        if let reel = projection.reels.first {
            archive.saveReel(reel, audience: visibleAudience)
            rebuildClusterCatalogs()
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

    /// Preserve the pre-directory-metadata identity byte for byte when the
    /// optional field is absent. In particular, an empty extra component would
    /// insert another NUL separator and invalidate an unchanged pending draft.
    nonisolated static func publicationFingerprint(for input: BackendMemoryInput,
                                                   urls: [URL], contentTypes: [String]) -> String {
        var intent = [input.kind, input.visibility, input.caption ?? ""]
        intent.append(contentsOf: [input.place?.name ?? "", input.place?.category ?? ""])
        intent.append(contentsOf: [input.place?.sourceId?.uuidString ?? "", input.placeId?.uuidString ?? ""])
        intent.append(contentsOf: urls.map(\.absoluteString))
        intent.append(contentsOf: contentTypes)
        if let directoryKind = input.place?.directoryKind {
            intent.append("directoryKind=\(directoryKind)")
        }
        if let cluster = input.cluster {
            // Add no component for legacy inputs: old retries remain identical.
            intent.append("clusterTitle=\(cluster.title)")
            intent.append("clusterMembers=\(cluster.memoryIds.map(\.uuidString).joined(separator: ","))")
        }
        return intent.joined(separator: "\u{0}")
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
            mapExcludedMemoryIDs = saved.mapExcludedMemoryIDs ?? []
            remember(saved.mine + saved.profile + saved.feed)
            await loadCachedMedia(saved.mine + saved.profile + saved.feed + saved.queued.map(\.record), identity: saved.user)
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

    func retryPendingPublications(id: UUID? = nil) {
        guard isActive else { return }
        for index in localState.queued.indices where id == nil || localState.queued[index].id == id {
            let key = localState.queued[index].id
            localState.queued[index].failure = nil
            syncRetryCounts.removeValue(forKey: key)
            syncRetryDates.removeValue(forKey: key)
        }
        updatePendingStatuses()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await persistLocalState()
                syncRetryTask?.cancel()
                syncRetryTask = nil
                startPendingSync()
            }
            catch { if isActive { issue = error.localizedDescription } }
        }
    }

    private func observeConnection() {
        guard automaticallySync, observesConnectivity, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                connectionAvailable = available
                guard available else {
                    // Stop the unacknowledged chunk, not the durable upload.
                    // Reconnection queries the server's last committed offset.
                    syncTask?.cancel()
                    syncRetryTask?.cancel()
                    syncRetryTask = nil
                    return
                }
                if syncAuthorized { startPendingSync(resumeImmediately: true) }
                else { onConnectionAvailable?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "maptalk.connection"))
        pathMonitor = monitor
        activationSubscription = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, isActive else { return }
                    backgroundExecutionExpired = false
                    if syncAuthorized { startPendingSync(resumeImmediately: true) }
                    else { onConnectionAvailable?() }
                }
            }
    }

    private func persistLocalState() async throws {
        try requireActive()
        localState.deleted = deletedMemoryIDs
        localState.privateOverrides = Array(privateOverrides.values)
        localState.blocked = blockedUserIDs
        localState.mapExcludedMemoryIDs = mapExcludedMemoryIDs
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
        let items = records.flatMap(\.attachedMedia) + records.compactMap { $0.owner.avatar } + [identity.avatar].compactMap { $0 }
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
            else if pendingPublications[entry.id] == .processing { statuses[entry.id] = .processing }
            else { statuses[entry.id] = .waiting }
        }
        pendingPublications = statuses
        publicationProgress = publicationProgress.filter { statuses[$0.key] != nil }
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
            for preview in entry.clusterPreviews ?? [] {
                if localMedia[preview.mediaID].map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                    localMedia[preview.mediaID] = stateDisk.mediaURL(preview.file)
                }
                let poster = stateDisk.posterURL(preview.file.id)
                if preview.file.isVideo, localPosters[preview.mediaID] == nil,
                   FileManager.default.fileExists(atPath: poster.path) { localPosters[preview.mediaID] = poster }
            }
        }
        let queuedIDs = Set(queued.map(\.id))
        let mine = currentRecords(localState.mine).filter { !queuedIDs.contains($0.id) } + queued.map(\.record)
        remember(mine + localState.profile + localState.feed)
        let privateProjection = project(mine.sorted { $0.activityDate > $1.activityDate })
        let publicProjection = project(currentRecords(localState.profile, publicOnly: true))
        let activeProjection = project(currentRecords(localState.feed, publicOnly: true))
        archive.replaceServerRecords(pois: privateProjection.pois, reels: privateProjection.reels)
        rebuildClusterCatalogs()
        ownPublicPOIs = publicProjection.pois
        ownPublicReels = publicProjection.reels
        feedPOIs.send(activeProjection.pois)
        feedReels.send(activeProjection.reels)
        publishFeedRecords()
        updatePendingStatuses()
    }

    private func publishFeedRecords() {
        guard isActive else { return }
        // Never derive this from knownMemories: that dictionary also contains
        // private, profile-history and arbitrary map-search records. Pending
        // publications remain local previews until the server confirms them.
        let queuedIDs = Set(localState.queued.map(\.id))
        let records = currentRecords(localState.feed, publicOnly: true)
            .filter { !queuedIDs.contains($0.id) }
            .sorted { $0.activityDate == $1.activityDate ? $0.id.uuidString < $1.id.uuidString : $0.activityDate > $1.activityDate }
            .map { record in
                var current = record
                if let identity = profileMetadata[record.ownerId] { current.owner = identity }
                return current
            }
        feedRecords.send(records)
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
        let publicationDate = Date()
        let kind = if case .place = draft { "poi" } else { "reel" }
        var input = BackendMemoryInput(id: requestID, kind: kind,
            visibility: audience == .livePublic ? "public" : "private",
            location: .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        // Persist once before any file work or upload; retries resend this exact instant.
        input.capturedAt = publicationDate.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var sources: [URL] = []
        var contentTypes: [String] = []
        var posters: [URL?] = []
        var place: BackendPlace?
        var cluster: BackendCluster?
        switch draft {
        case let .reel(reel):
            if let source = reel.bubbleSource {
                let selection = try makeClusterSelection(source, parentID: requestID)
                input.cluster = selection.input
                cluster = selection.snapshot
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
                        sourceId: rated.poi.id, directoryKind: rated.poi.directoryKind?.rawValue)
                }
                place = BackendPlace(id: canonical, sourceId: rated.poi.id, name: rated.poi.name,
                    category: rated.poi.category.rawValue,
                    coordinate: .init(latitude: rated.poi.coordinate.latitude, longitude: rated.poi.coordinate.longitude),
                    directoryKind: rated.poi.directoryKind?.rawValue)
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
            createdAt: publicationDate, publishedAt: nil, expiresAt: .distantFuture, moderationStatus: "local_pending",
            cluster: cluster)
        var entry = QueuedPublication(input: input, record: record, photos: photos)
        try await stateDisk.copyMedia(sources, items: photos, posters: posters)
        do {
            // Keep any already-available member media with the durable intent,
            // including across sign-out or source-upload file cleanup.
            var seen = Set<UUID>()
            let previewMedia = (cluster?.members.flatMap(\.media) ?? []).filter {
                seen.insert($0.id).inserted && localMedia[$0.id] != nil
            }
            let previews = previewMedia.map {
                QueuedPublication.ClusterPreview(mediaID: $0.id, file: .init(id: UUID(), mimeType: $0.mimeType))
            }
            entry.clusterPreviews = previews.isEmpty ? nil : previews
            try await stateDisk.copyMedia(previewMedia.compactMap { localMedia[$0.id] },
                items: previews.map(\.file), posters: previewMedia.map { localPosters[$0.id] })
            try requireActive()
            localState.queued.append(entry)
            try await persistLocalState()
        } catch {
            // Session expiry may already have persisted this intent for the
            // next sign-in. Never delete its photos after that handoff.
            if isActive {
                localState.queued.removeAll { $0.id == requestID }
                stateDisk.removePhotos(photos.map(\.id) + (entry.clusterPreviews ?? []).map { $0.file.id })
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

    private func startPendingSync(resumeImmediately: Bool = false) {
        if resumeImmediately {
            syncRetryTask?.cancel()
            syncRetryTask = nil
            syncRetryDates.removeAll()
        }
        guard automaticallySync, syncAuthorized, isActive, connectionAvailable != false,
              !backgroundExecutionExpired, syncTask == nil,
              localState.queued.contains(where: { $0.cancelled || $0.failure == nil }) else { return }
        syncRetryTask?.cancel()
        syncRetryTask = nil
        syncTask = Task { [weak self] in
            guard let self else { return }
            beginSyncBackgroundGrace()
            await syncPendingPublications(respectingBackoff: true)
            endSyncBackgroundGrace()
            syncTask = nil
            schedulePendingRetry()
        }
    }

    private func schedulePendingRetry() {
        guard automaticallySync, isActive, syncAuthorized, connectionAvailable != false,
              !backgroundExecutionExpired else { return }
        let dates = localState.queued.filter { entry in
            if entry.cancelled { return true }
            guard entry.failure == nil else { return false }
            // A blocked source owns its retry/error UI. Do not wake forever
            // just to discover that its dependent cluster is still waiting.
            guard let cluster = entry.input.cluster else { return true }
            return !localState.queued.contains { cluster.memoryIds.contains($0.id) }
        }
            .map { syncRetryDates[$0.id] ?? Date() }
        guard let next = dates.min() else { return }
        let delay = max(0.01, next.timeIntervalSinceNow)
        syncRetryTask?.cancel()
        syncRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, isActive else { return }
            syncRetryTask = nil
            startPendingSync()
        }
    }

    private func beginSyncBackgroundGrace() {
        guard backgroundTask == .invalid else { return }
        // A short OS-granted window can finish the current chunk when leaving
        // the app. It is not a promise of unlimited background uploading.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MapTalk upload") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                backgroundExecutionExpired = true
                syncTask?.cancel()
                syncRetryTask?.cancel()
                syncRetryTask = nil
                endSyncBackgroundGrace()
            }
        }
    }

    private func endSyncBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Also callable by isolated tests; never retries with a new post/photo ID.
    func syncPendingPublications(respectingBackoff: Bool = false) async {
        guard syncAuthorized, isActive, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false; currentSyncID = nil }
        let ids = localState.queued.map(\.id)
        for id in ids {
            guard let entry = localState.queued.first(where: { $0.id == id }), entry.cancelled || entry.failure == nil else { continue }
            if respectingBackoff, let next = syncRetryDates[id], next > Date() { continue }
            if !entry.cancelled, let cluster = entry.input.cluster,
               localState.queued.contains(where: { cluster.memoryIds.contains($0.id) }) {
                // Sources can fail/back off independently. Never send the
                // parent early (404), nor permanently fail it just for waiting.
                pendingPublications[id] = .waiting
                syncRetryDates[id] = Date().addingTimeInterval(max(1, retryDelay(1)))
                continue
            }
            currentSyncID = id
            var reconcilingVideoUpload = false
            var failurePhase: QueuedPublication.FailureDiagnostic.Phase = entry.cancelled ? .cancellation : .mediaUpload
            do {
                try Task.checkCancellation()
                try requireActive()
                if entry.cancelled { try await finishCancelledPublication(id); continue }
                pendingPublications[id] = .uploading
                for photo in entry.photos where photo.uploaded == nil {
                    let url = stateDisk.mediaURL(photo)
                    try requireActive()
                    guard let current = localState.queued.first(where: { $0.id == id }), !current.cancelled else { break }
                    let finishedCount = current.photos.filter { $0.uploaded != nil }.count
                    let attachmentCount = max(1, current.photos.count)
                    pendingPublications[id] = .uploading
                    let confirmedProgress = Double(finishedCount) / Double(attachmentCount)
                    // Keep the last acknowledged fraction while PUT reconciles
                    // an interrupted video. Its response is authoritative and
                    // may reset this if the server expired/restarted the upload.
                    publicationProgress[id] = photo.isVideo
                        ? max(publicationProgress[id] ?? confirmedProgress, confirmedProgress)
                        : confirmedProgress
                    let media: BackendMedia
                    failurePhase = .mediaUpload
                    if photo.isVideo {
                        reconcilingVideoUpload = true
                        media = try await api.uploadVideo(at: url, idempotencyKey: photo.id,
                            checkActive: { [weak self] in
                                guard let self else { throw CancellationError() }
                                try requireActive()
                                guard localState.queued.contains(where: { $0.id == id && !$0.cancelled }) else { throw CancellationError() }
                            }, onProgress: { [weak self] fraction in
                                guard let self, canUpdatePublicationProgress(id) else { return }
                                publicationProgress[id] = (Double(finishedCount) + fraction) / Double(attachmentCount)
                                pendingPublications[id] = .uploading
                            }, onProcessing: { [weak self] in
                                guard let self, canUpdatePublicationProgress(id) else { return }
                                failurePhase = .videoProcessing
                                pendingPublications[id] = .processing
                            })
                        reconcilingVideoUpload = false
                    } else {
                        let data = try await Task.detached { try Data(contentsOf: url) }.value
                        try Task.checkCancellation()
                        media = try await api.uploadMedia(data, mimeType: photo.contentType, idempotencyKey: photo.id)
                    }
                    try requireActive()
                    guard let index = localState.queued.firstIndex(where: { $0.id == id }),
                          let photoIndex = localState.queued[index].photos.firstIndex(where: { $0.id == photo.id }) else { throw CancellationError() }
                    localState.queued[index].photos[photoIndex].uploaded = media
                    failurePhase = .localCommit
                    try await persistLocalState()
                    if canUpdatePublicationProgress(id) {
                        publicationProgress[id] = Double(finishedCount + 1) / Double(attachmentCount)
                        pendingPublications[id] = .uploading
                    }
                }
                guard let index = localState.queued.firstIndex(where: { $0.id == id }) else { continue }
                if localState.queued[index].cancelled { try await finishCancelledPublication(id); continue }
                // Video processing is complete. Photo uploads and the final
                // post confirmation use the ordinary uploading state again.
                pendingPublications[id] = .uploading
                localState.queued[index].input.mediaIds = localState.queued[index].photos.compactMap { $0.uploaded?.id }
                localState.queued[index].attemptedPost = true
                failurePhase = .localCommit
                try await persistLocalState()
                guard let sending = localState.queued.first(where: { $0.id == id }), !sending.cancelled else { continue }
                failurePhase = .publication
                let saved = try await api.publish(sending.input)
                try requireActive()
                if localState.queued.first(where: { $0.id == id })?.cancelled == true {
                    try await finishCancelledPublication(id)
                    continue
                }
                failurePhase = .localCommit
                // Keep a cached copy after removing durable outbox files.
                for (photo, media) in zip(sending.photos, saved.media) {
                    let url = stateDisk.mediaURL(photo)
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    localMedia[media.id] = try await mediaDisk.write(data, for: media.id, mimeType: media.mimeType)
                    if media.mimeType == "video/mp4" {
                        localPosters[media.id] = try await mediaDisk.cachedPosterURL(for: media.id)
                    }
                }
                let clusterMedia = Dictionary((saved.cluster?.members.flatMap(\.media) ?? [])
                    .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for preview in sending.clusterPreviews ?? [] {
                    guard let media = clusterMedia[preview.mediaID] else { continue }
                    let url = stateDisk.mediaURL(preview.file)
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
                remapQueuedClusterSource(from: sending.record, to: saved)
                localState.mine.removeAll { $0.id == id }
                localState.mine.insert(saved, at: 0)
                if Self.isPubliclyVisible(saved) {
                    restoreMapEligibility(from: [saved], ifRevision: mapCacheRevision)
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
                stateDisk.removePhotos(sending.photos.map(\.id) + (sending.clusterPreviews ?? []).map { $0.file.id })
                syncRetryCounts.removeValue(forKey: id)
                syncRetryDates.removeValue(forKey: id)
                for item in sending.photos {
                    localMedia.removeValue(forKey: item.id)
                    localPosters.removeValue(forKey: item.id)
                }
                remember([saved])
                rebuildLocalProjections()
            } catch is CancellationError {
                if localState.queued.contains(where: { $0.id == id && !$0.cancelled }) { pendingPublications[id] = .waiting }
                return
            }
            catch {
                guard isActive else { return }
                if let index = localState.queued.firstIndex(where: { $0.id == id }) {
                    let permanent: Bool
                    if case let BackendClientError.http(status, _, code) = error {
                        let reconcile = reconcilingVideoUpload
                            && ["upload_offset_mismatch", "upload_incomplete", "incomplete_body", "not_found"].contains(code ?? "")
                        permanent = !reconcile && [400, 403, 404, 409, 410, 413, 415, 422].contains(status)
                    } else { permanent = error is CocoaError }
                    let message = publicationFailureMessage(error)
                    localState.queued[index].lastFailure = publicationFailureDiagnostic(error,
                        phase: localState.queued[index].cancelled ? .cancellation : failurePhase)
                    if permanent { localState.queued[index].failure = message }
                    // Cancellation remains eligible until the server confirms
                    // its tombstone and media cleanup. Even a permanent-looking
                    // cleanup refusal (e.g. media_in_use) must back off rather
                    // than bypassing failure and spinning on the next tick.
                    if !permanent || localState.queued[index].cancelled {
                        let attempt = min(6, (syncRetryCounts[id] ?? 0) + 1)
                        syncRetryCounts[id] = attempt
                        syncRetryDates[id] = Date().addingTimeInterval(max(0.01, retryDelay(attempt)))
                    }
                    pendingPublications[id] = permanent ? .failed(message) : .waiting
                    try? await persistLocalState()
                    updatePendingStatuses()
                    // A single interrupted video must not strand independent
                    // photos/posts behind it. Each entry has bounded backoff.
                }
            }
        }
    }

    private func canUpdatePublicationProgress(_ id: UUID) -> Bool {
        isActive && !Task.isCancelled && currentSyncID == id
            && localState.queued.contains { $0.id == id && !$0.cancelled }
    }

    /// Source post IDs never change. Only provisional media/place identities
    /// change on confirmation; keep the selected caption/order frozen locally.
    private func remapQueuedClusterSource(from original: BackendMemory, to saved: BackendMemory) {
        let mediaIDs = Dictionary(zip(original.media.map(\.id), saved.media.map(\.id)), uniquingKeysWith: { first, _ in first })
        for index in localState.queued.indices {
            guard var cluster = localState.queued[index].record.cluster,
                  let memberIndex = cluster.members.firstIndex(where: { $0.id == original.id }) else { continue }
            let member = cluster.members[memberIndex]
            cluster.members[memberIndex] = BackendMemory(id: member.id, ownerId: member.ownerId, owner: member.owner,
                kind: member.kind, visibility: member.visibility, location: member.location, caption: member.caption,
                place: saved.place, media: saved.media, createdAt: member.createdAt, publishedAt: saved.publishedAt,
                expiresAt: saved.expiresAt, moderationStatus: saved.moderationStatus)
            localState.queued[index].record.cluster = cluster
            if let previews = localState.queued[index].clusterPreviews {
                localState.queued[index].clusterPreviews = previews.map { preview in
                    var updated = preview
                    updated.mediaID = mediaIDs[preview.mediaID] ?? preview.mediaID
                    return updated
                }
            }
        }
    }

    private func publicationFailureMessage(_ error: Error) -> String {
        if case let BackendClientError.http(_, _, code) = error {
            if code == "media_quota" {
                return "Your storage is full. Delete an older post to free space, then retry. Your media is saved on this phone."
            }
            // Server/decoder diagnostics are not instructions for the person
            // publishing. In particular, a validation error alone cannot prove
            // their original video is damaged. The local preview stays usable.
            return "Couldn't publish yet. Your post is saved on this phone. Please try again."
        }
        if error is CocoaError {
            return "The saved media couldn't be read. Your post is still on this phone; check available storage and retry."
        }
        return "Couldn't publish yet. Your post is saved on this phone. Please try again."
    }

    private func publicationFailureDiagnostic(_ error: Error,
        phase: QueuedPublication.FailureDiagnostic.Phase) -> QueuedPublication.FailureDiagnostic {
        let status: Int?
        let code: String?
        switch error {
        case let BackendClientError.http(httpStatus, _, serverCode):
            status = httpStatus
            // Error codes are identifiers, not a second channel for arbitrary
            // server text. Discard unexpected values instead of persisting it.
            code = serverCode.flatMap { value in
                guard !value.isEmpty, value.utf8.count <= 80,
                      value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
                return value
            }
        case BackendClientError.unauthorized:
            status = 401
            code = nil
        default:
            status = nil
            code = nil
        }
        return .init(phase: phase, httpStatus: status, code: code, occurredAt: Date())
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
        if currentSyncID == id { syncTask?.cancel() }
        startPendingSync(resumeImmediately: true)
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
        stateDisk.removePhotos(entry.photos.map(\.id) + (entry.clusterPreviews ?? []).map { $0.file.id })
        for preview in entry.clusterPreviews ?? [] where localMedia[preview.mediaID] == stateDisk.mediaURL(preview.file) {
            localMedia.removeValue(forKey: preview.mediaID)
            localPosters.removeValue(forKey: preview.mediaID)
        }
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
        syncRetryTask?.cancel()
        syncRetryTask = nil
        syncRetryDates.removeAll()
        syncRetryCounts.removeAll()
        endSyncBackgroundGrace()
        pathMonitor?.cancel()
        pathMonitor = nil
        activationSubscription = nil
        pendingPublications.removeAll()
        publicationProgress.removeAll()
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
        commentThreads.removeAll()
        commentThreadRevisions.removeAll()
        mapExcludedMemoryIDs.removeAll()
        mapCacheRevision += 1
        profileMetadata.removeAll()
        blockedUserIDs.removeAll()
        knownPlaceIDs.removeAll()
        placeAliases.removeAll()
        selectionDirectoryCategories.removeAll()
        user.avatarURL = nil
        users = [user.id: user]
        archive.replaceServerRecords(pois: [], reels: [])
        archive.replaceServerBubbles(privateBubbles: [], publicBubbles: [])
        ownPublicPOIs = []
        ownPublicReels = []
        feedPOIs.send([])
        feedReels.send([])
        feedRecords.send([])
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
            for media in record.attachedMedia where localMedia[media.id] == nil { mediaByID[media.id] = media }
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
        var firstDownloadFailure: Error?
        for media in [images, videos] {
            for start in stride(from: 0, to: media.count, by: 4) {
                try requireActive()
                guard contentRevision == publicContentRevision else { throw CancellationError() }
                try await withThrowingTaskGroup(of: (any Error)?.self) { group in
                    for item in media[start..<min(start + 4, media.count)] {
                        group.addTask {
                            do {
                                try await self.prepareMedium(item, contentRevision: contentRevision)
                                return nil
                            } catch {
                                try Task.checkCancellation()
                                // Revoked access and cancelled views still stop
                                // immediately. A broken download must not stop
                                // unrelated photos or every later video batch.
                                if Self.mustStopMediaPreparation(after: error) { throw error }
                                return error
                            }
                        }
                    }
                    for try await failure in group {
                        if firstDownloadFailure == nil { firstDownloadFailure = failure }
                    }
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
        // Successful assets have already reached the visible projection. Keep
        // the failure recoverable so the next refresh retries only missing media.
        if let firstDownloadFailure { throw firstDownloadFailure }
    }

    private nonisolated static func mustStopMediaPreparation(after error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        switch error {
        case BackendClientError.unauthorized: return true
        case let BackendClientError.http(status, _, _): return [401, 403, 404, 410].contains(status)
        default: return false
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
        for record in records.sorted(by: { $0.activityDate == $1.activityDate
            ? $0.id.uuidString < $1.id.uuidString : $0.activityDate > $1.activityDate }) {
            let attachments = record.media.compactMap { media -> RealPost.Attachment? in
                guard let url = localMedia[media.id] else { return nil }
                return .init(id: media.id, kind: media.mimeType == "video/mp4"
                    ? .video(url: url, poster: localPosters[media.id]) : .photo(url))
            }
            if record.kind == "reel" {
                reels.append(RealPost(id: record.id, userId: record.ownerId,
                    center: .init(latitude: record.location.latitude, longitude: record.location.longitude),
                    radiusMeters: 220, message: record.caption.isEmpty ? nil : record.caption,
                    attachments: attachments, capsuleId: validatedCluster(in: record)?.id, likes: [], comments: [],
                    visibility: record.visibility == "public" ? .publicAll : .privateOnly,
                    createdAt: record.createdAt, expiresAt: Self.publicExpiry(for: record), publishedAt: record.publishedAt))
            } else if let place = record.place {
                var rated = places[place.id] ?? RatedPOI(
                    poi: .init(id: place.id, name: place.name,
                        coordinate: .init(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                        category: POICategory(rawValue: place.category) ?? .other,
                        directoryKind: place.directoryKind.flatMap(POIDirectoryKind.init(rawValue:))),
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

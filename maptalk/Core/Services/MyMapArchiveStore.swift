import Combine
import Foundation

/// The destination a new memory takes at the moment it is made.
///
/// A live post is also part of its author's MyMap history; a private memory
/// lives only in that history until a later publishing flow promotes it.
enum MapPublishAudience: Hashable {
    case livePublic
    case privateMyMap
}

/// Shared, in-memory ownership for the current person's map memories.
///
/// The app still uses read-only mock repositories for the world map. This
/// store is their local companion: it preserves newly made content across the
/// MapTalk and MyMap tabs without pretending mock data has been written back
/// to a server. One instance is owned by `AppEnvironment`, so its preview
/// baseline is seeded once per app environment rather than once per view.
@MainActor
final class MyMapArchiveStore: ObservableObject {
    /// New public content that MapTalk can overlay on top of its read-only
    /// repository stream.
    @Published private(set) var publicPOIOverlays: [RatedPOI]
    @Published private(set) var publicReelOverlays: [RealPost]

    /// Immutable Bubble snapshots reachable through a public Reel's capsule.
    @Published private(set) var publicBubbleCatalog: [JourneyPost]

    /// Everything the current person can revisit in MyMap, including items
    /// also present in the public overlays above.
    @Published private(set) var privatePOIs: [RatedPOI]
    @Published private(set) var privateReels: [RealPost]
    @Published private(set) var privateBubbleCatalog: [JourneyPost]
    @Published private(set) var journeyFolders: [JourneyFolder]

    /// Existing published Journey capsules are legacy presentation data. They
    /// stay immutable here, while `JourneyFolder` remains the editable local
    /// organizer.
    let legacyJourneyCatalog: [JourneyPost]

    let currentUserID: UUID
    private var folderStorageURL: URL?

    init(
        currentUserID: UUID? = nil,
        seed: PreviewData.ChengsiMock? = nil,
        startsEmpty: Bool = false
    ) {
        publicPOIOverlays = []
        publicReelOverlays = []
        publicBubbleCatalog = []
        privatePOIs = []
        privateReels = []
        privateBubbleCatalog = []
        journeyFolders = []
        if startsEmpty {
            // Connected accounts must not construct the entire preview archive just to discard
            // it. Their explicit identity bypasses every mock-data initializer below.
            let ownerID = currentUserID ?? seed?.user.id ?? PreviewData.currentUser.id
            self.currentUserID = ownerID
            legacyJourneyCatalog = []
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BackendAccounts/\(ownerID.uuidString)", isDirectory: true)
            folderStorageURL = directory.appendingPathComponent("collections.json")
            if let url = folderStorageURL, let data = try? Data(contentsOf: url),
               let saved = try? JSONDecoder().decode([JourneyFolder].self, from: data) {
                journeyFolders = saved.filter { $0.userId == ownerID }
            }
        } else {
            let baseline = seed ?? PreviewData.chengsiPrivateArchive
            let ownerID = currentUserID ?? baseline.user.id
            self.currentUserID = ownerID
            legacyJourneyCatalog = baseline.journeys
            privatePOIs = PreviewData.profileRatedPOIs(for: baseline.user, customPOIs: baseline.pois)
            privateReels = baseline.reels
            journeyFolders = baseline.journeyFolders.filter { $0.userId == ownerID }
        }
    }

    func replaceServerRecords(pois: [RatedPOI], reels: [RealPost]) {
        privatePOIs = pois
        privateReels = reels
        publicPOIOverlays = []
        publicReelOverlays = []
    }

    /// Replace server projections as media fills in or a parent is withdrawn.
    /// The server owns snapshot immutability; these are hydrated UI copies.
    func replaceServerBubbles(privateBubbles: [JourneyPost], publicBubbles: [JourneyPost]) {
        privateBubbleCatalog = privateBubbles
        publicBubbleCatalog = publicBubbles
    }

    private func persistFolders() {
        do {
            try writeFolders(journeyFolders)
        } catch {
            // Keep the in-memory edit; callers observe an actionable save issue.
            persistenceIssue = "Could not save Collections on this device. Please try again."
        }
    }

    private func writeFolders(_ folders: [JourneyFolder]) throws {
        guard let url = folderStorageURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(folders).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A queued new place temporarily uses its local post ID. On confirmation,
    /// retain all Collection memberships under the server's canonical place ID.
    /// Persist before acknowledging the remap so the upload queue can safely
    /// replay it after a crash or a failed disk write.
    func remapPOIReference(from sourceID: UUID, to destinationID: UUID) throws {
        guard sourceID != destinationID else { return }
        let source = JourneyFolder.MemberReference.poi(sourceID)
        let destination = JourneyFolder.MemberReference.poi(destinationID)
        var changed = false
        let updated = journeyFolders.map { folder in
            guard folder.userId == currentUserID, folder.memberReferences.contains(source) else { return folder }
            var result = folder
            result.memberReferences = unique(folder.memberReferences.map { $0 == source ? destination : $0 })
            result.updatedAt = .now
            changed = true
            return result
        }
        guard changed else { return }
        do {
            try writeFolders(updated)
        } catch {
            persistenceIssue = "Could not save Collections on this device. Please try again."
            throw error
        }
        journeyFolders = updated
        persistenceIssue = nil
    }

    @Published var persistenceIssue: String?

    /// Saves the person's complete POI history to MyMap. A public publish must
    /// also provide a separately constructed projection containing only
    /// public check-ins; this prevents an earlier private capture at the same
    /// landmark from being promoted accidentally.
    @discardableResult
    func savePOI(
        _ privateVersion: RatedPOI,
        publicVersion: RatedPOI?,
        audience: MapPublishAudience
    ) -> RatedPOI {
        if audience == .livePublic {
            guard let publicVersion,
                  publicVersion.id == privateVersion.id else {
                assertionFailure("A public POI needs a matching public-only projection")
                return privateVersion
            }
        }

        upsert(privateVersion, into: &privatePOIs)

        if audience == .livePublic {
            guard let publicVersion else { return privateVersion }
            upsert(publicVersion, into: &publicPOIOverlays)
        }

        return privateVersion
    }

    /// Saves a Reel to MyMap and, for a live post, makes it available as a
    /// public-map overlay.
    @discardableResult
    func saveReel(
        _ reel: RealPost,
        audience: MapPublishAudience
    ) -> RealPost {
        upsert(reel, into: &privateReels)

        if audience == .livePublic {
            upsert(reel, into: &publicReelOverlays)
        }

        return reel
    }

    /// Persists the immutable Bubble snapshot attached to a Reel.
    ///
    /// A Bubble is always retained in its author's private catalog. Only a
    /// Bubble attached to a live Reel is also discoverable from the public
    /// Reel stream. Folder membership is deliberately not involved: choosing
    /// a Folder during publishing is only a shortcut for creating this
    /// independent snapshot.
    @discardableResult
    func saveBubble(
        _ bubble: JourneyPost,
        audience: MapPublishAudience
    ) -> JourneyPost {
        let snapshot: JourneyPost
        if let existing = privateBubbleCatalog.first(where: { $0.id == bubble.id }) {
            snapshot = existing
        } else {
            privateBubbleCatalog.insert(bubble, at: 0)
            snapshot = bubble
        }

        if audience == .livePublic,
           publicBubbleCatalog.contains(where: { $0.id == snapshot.id }) == false {
            publicBubbleCatalog.insert(snapshot, at: 0)
        }

        return snapshot
    }

    /// Adds an existing private Reel to an editable Folder from MyMap's
    /// organizer flows. Publishing a Bubble must use `saveBubble` instead;
    /// that operation snapshots Folder contents without changing membership.
    @discardableResult
    func addReel(
        _ reelID: UUID,
        toJourneyFolder folderID: UUID
    ) -> JourneyFolder? {
        guard privateReels.contains(where: { $0.id == reelID }),
              let index = journeyFolders.firstIndex(where: {
                  $0.id == folderID && $0.userId == currentUserID
              }) else {
            return nil
        }

        var folder = journeyFolders[index]
        let reference = JourneyFolder.MemberReference.reel(reelID)
        guard folder.memberReferences.contains(reference) == false else {
            return folder
        }

        folder.memberReferences.append(reference)
        folder.updatedAt = .now
        journeyFolders[index] = folder
        persistFolders()
        return folder
    }

    @discardableResult
    func createJourneyFolder(
        title: String,
        memberReferences: [JourneyFolder.MemberReference] = []
    ) -> JourneyFolder {
        let now = Date()
        let folder = JourneyFolder(
            userId: currentUserID,
            title: normalizedFolderTitle(title),
            memberReferences: unique(memberReferences),
            createdAt: now,
            updatedAt: now
        )
        journeyFolders.insert(folder, at: 0)
        persistFolders()
        return folder
    }

    @discardableResult
    func saveJourneyFolder(_ folder: JourneyFolder) -> JourneyFolder? {
        guard folder.userId == currentUserID,
              let index = journeyFolders.firstIndex(where: { $0.id == folder.id }) else {
            return nil
        }

        var updated = folder
        updated.title = normalizedFolderTitle(updated.title)
        updated.memberReferences = unique(updated.memberReferences)
        updated.updatedAt = .now
        journeyFolders[index] = updated
        persistFolders()
        return updated
    }

    func deleteJourneyFolder(id: UUID) {
        journeyFolders.removeAll { folder in
            folder.id == id && folder.userId == currentUserID
        }
        persistFolders()
    }

    /// Removes only the MyMap copy. A live-post overlay remains live on the
    /// public map, matching MyMap's existing "remove from MyMap" meaning.
    func removeFromPrivateArchive(_ reference: JourneyFolder.MemberReference) {
        switch reference {
        case let .reel(id):
            privateReels.removeAll { $0.id == id }
        case let .poi(id):
            privatePOIs.removeAll { $0.id == id }
        }

        journeyFolders = journeyFolders.map { folder in
            var updated = folder
            updated.memberReferences.removeAll { $0 == reference }
            if updated.memberReferences.count != folder.memberReferences.count {
                updated.updatedAt = .now
            }
            return updated
        }
        persistFolders()
    }

    private func normalizedFolderTitle(_ title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Collection" : cleaned
    }

    private func unique(
        _ references: [JourneyFolder.MemberReference]
    ) -> [JourneyFolder.MemberReference] {
        references.reduce(into: []) { result, reference in
            if result.contains(reference) == false {
                result.append(reference)
            }
        }
    }

    private func upsert<Item: Identifiable>(
        _ item: Item,
        into collection: inout [Item]
    ) where Item.ID: Equatable {
        if let index = collection.firstIndex(where: { $0.id == item.id }) {
            collection[index] = item
        } else {
            collection.insert(item, at: 0)
        }
    }
}

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

    init(
        currentUserID: UUID? = nil,
        seed: PreviewData.ChengsiMock? = nil
    ) {
        let baseline = seed ?? PreviewData.chengsiPrivateArchive
        let ownerID = currentUserID ?? baseline.user.id

        self.currentUserID = ownerID
        publicPOIOverlays = []
        publicReelOverlays = []
        publicBubbleCatalog = []
        privatePOIs = PreviewData.profileRatedPOIs(
            for: baseline.user,
            customPOIs: baseline.pois
        )
        privateReels = baseline.reels
        privateBubbleCatalog = []
        journeyFolders = baseline.journeyFolders.filter { $0.userId == ownerID }
        legacyJourneyCatalog = baseline.journeys
    }

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
        return updated
    }

    func deleteJourneyFolder(id: UUID) {
        journeyFolders.removeAll { folder in
            folder.id == id && folder.userId == currentUserID
        }
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

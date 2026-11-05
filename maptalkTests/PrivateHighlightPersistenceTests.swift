import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct PrivateHighlightPersistenceTests {
    @Test
    func legacyCollectionsFileKeepsIdentityTitlesOrderAndDatesWithoutRewriting() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let firstID = UUID(), secondID = UUID(), placeID = UUID(), reelID = UUID()
        // This is the existing synthesized Codable format, not a new Highlight schema.
        let legacy = Data("""
        [
          {
            "id": "\(firstID.uuidString)",
            "userId": "\(fixture.ownerID.uuidString)",
            "title": "Lānaʻi · 四季",
            "memberReferences": [
              {"poi": {"_0": "\(placeID.uuidString)"}},
              {"reel": {"_0": "\(reelID.uuidString)"}}
            ],
            "createdAt": 600000000,
            "updatedAt": 600000090
          },
          {
            "id": "\(secondID.uuidString)",
            "userId": "\(fixture.ownerID.uuidString)",
            "title": "Untitled Collection",
            "memberReferences": [],
            "createdAt": 599999000,
            "updatedAt": 599999000
          }
        ]
        """.utf8)
        try fixture.write(legacy)

        let store = fixture.makeStore()
        let folders = store.journeyFolders
        #expect(folders.map(\.id) == [firstID, secondID])
        #expect(folders.map(\.userId) == [fixture.ownerID, fixture.ownerID])
        #expect(folders.map(\.title) == ["Lānaʻi · 四季", "Untitled Collection"])
        let first = try #require(folders.first)
        #expect(first.memberReferences == [.poi(placeID), .reel(reelID)])
        #expect(first.createdAt == Date(timeIntervalSinceReferenceDate: 600_000_000))
        #expect(first.updatedAt == Date(timeIntervalSinceReferenceDate: 600_000_090))
        #expect(folders.last?.memberReferences.isEmpty == true)
        #expect(try Data(contentsOf: fixture.storageURL) == legacy)
        #expect(store.privatePOIs.isEmpty && store.privateReels.isEmpty)
        #expect(store.publicPOIOverlays.isEmpty && store.publicReelOverlays.isEmpty)
        #expect(store.publicBubbleCatalog.isEmpty)
    }

    @Test
    func createRenameAddRemoveAndDeleteEachSurviveStoreReconstruction() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let placeID = UUID()
        let reel = fixture.reel()
        let created = fixture.makeStore().createJourneyFolder(
            title: "  Lānaʻi  ", memberReferences: [.poi(placeID)])

        let renameStore = fixture.makeStore()
        var renamed = try #require(renameStore.journeyFolders.first)
        #expect(renamed.id == created.id)
        #expect(renamed.title == "Lānaʻi")
        renamed.title = "  Four Seasons  "
        _ = try #require(renameStore.saveJourneyFolder(renamed))

        let addStore = fixture.makeStore()
        #expect(addStore.journeyFolders.first?.title == "Four Seasons")
        addStore.saveReel(reel, audience: .privateMyMap)
        _ = try #require(addStore.addReel(reel.id, toJourneyFolder: created.id))

        let removeStore = fixture.makeStore()
        var reduced = try #require(removeStore.journeyFolders.first)
        #expect(reduced.memberReferences == [.poi(placeID), .reel(reel.id)])
        #expect(reduced.createdAt == created.createdAt)
        reduced.memberReferences.removeAll { $0 == .poi(placeID) }
        _ = try #require(removeStore.saveJourneyFolder(reduced))

        let deleteStore = fixture.makeStore()
        let remaining = try #require(deleteStore.journeyFolders.first)
        #expect(remaining.id == created.id)
        #expect(remaining.createdAt == created.createdAt)
        #expect(remaining.memberReferences == [.reel(reel.id)])
        deleteStore.deleteJourneyFolder(id: created.id)

        #expect(fixture.makeStore().journeyFolders.isEmpty)
        #expect(try JSONDecoder().decode([JourneyFolder].self,
            from: Data(contentsOf: fixture.storageURL)).isEmpty)
    }

    @Test
    func accountsHaveIndependentFilesAndCannotMutateAnotherOwnersHighlight() throws {
        let alice = HighlightPersistenceFixture(), bob = HighlightPersistenceFixture()
        defer { alice.cleanup(); bob.cleanup() }
        let aliceStore = alice.makeStore(), bobStore = bob.makeStore()
        let aliceFolder = aliceStore.createJourneyFolder(title: "Alice's trip")
        let bobFolder = bobStore.createJourneyFolder(title: "Bob's trip")

        #expect(alice.storageURL != bob.storageURL)
        #expect(alice.makeStore().journeyFolders == [aliceFolder])
        #expect(bob.makeStore().journeyFolders == [bobFolder])
        #expect(bobStore.saveJourneyFolder(aliceFolder) == nil)
        bobStore.deleteJourneyFolder(id: aliceFolder.id)
        #expect(alice.makeStore().journeyFolders == [aliceFolder])
        #expect(bob.makeStore().journeyFolders == [bobFolder])

        // Even an incorrectly mixed legacy file must not load another person's organizer.
        try alice.write(JSONEncoder().encode([bobFolder, aliceFolder]))
        #expect(alice.makeStore().journeyFolders == [aliceFolder])
    }

    @Test
    func deduplicationPreservesAuthoredOrderAndDistinctPlaceAndReelReferences() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let sharedID = UUID(), otherID = UUID()
        let originalOrder: [JourneyFolder.MemberReference] = [
            .poi(sharedID), .reel(sharedID), .reel(otherID)
        ]
        var folder = store.createJourneyFolder(title: "Ordered", memberReferences: [
            .poi(sharedID), .reel(sharedID), .poi(sharedID), .reel(otherID), .reel(sharedID)
        ])
        #expect(fixture.makeStore().journeyFolders.first?.memberReferences == originalOrder)

        folder.memberReferences = [.reel(otherID), .poi(sharedID), .reel(otherID), .reel(sharedID)]
        _ = try #require(store.saveJourneyFolder(folder))
        let reordered: [JourneyFolder.MemberReference] = [.reel(otherID), .poi(sharedID), .reel(sharedID)]
        #expect(fixture.makeStore().journeyFolders.first?.memberReferences == reordered)

        store.saveReel(fixture.reel(id: otherID), audience: .privateMyMap)
        _ = try #require(store.addReel(otherID, toJourneyFolder: folder.id))
        #expect(fixture.makeStore().journeyFolders.first?.memberReferences == reordered)
    }

    @Test
    func onlyNewOrExplicitlyRenamedBlankTitlesUseHighlightFallback() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let created = store.createJourneyFolder(title: " \n\t ")
        #expect(created.title == "Untitled Highlight")
        #expect(fixture.makeStore().journeyFolders.first?.title == "Untitled Highlight")

        var renamed = store.createJourneyFolder(title: "Existing name")
        renamed.title = "\n"
        _ = try #require(store.saveJourneyFolder(renamed))
        #expect(fixture.makeStore().journeyFolders.first?.title == "Untitled Highlight")
        #expect(fixture.makeStore().journeyFolders.map(\.id) == [renamed.id, created.id])
    }

    @Test
    func missingReelOrHighlightCannotCreateMembership() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let folder = store.createJourneyFolder(title: "Keep empty")
        #expect(store.addReel(UUID(), toJourneyFolder: folder.id) == nil)
        let reel = fixture.reel()
        store.saveReel(reel, audience: .privateMyMap)
        #expect(store.addReel(reel.id, toJourneyFolder: UUID()) == nil)
        #expect(fixture.makeStore().journeyFolders == [folder])
    }

    @Test
    func editingAndDeletingHighlightNeverChangeOriginalsOrPublishedBubble() throws {
        let fixture = HighlightPersistenceFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let privateReel = fixture.reel()
        let privatePlace = fixture.place()
        var publicPlace = privatePlace
        publicPlace.checkIns = [try #require(privatePlace.checkIns.last)]
        let bubble = JourneyPost(id: UUID(), userId: fixture.ownerID, title: "Published title",
            content: "Original Bubble", coordinate: privatePlace.poi.coordinate,
            createdAt: Date(timeIntervalSinceReferenceDate: 600_000_000),
            orderedMemberReferences: [.poi(privatePlace.id), .reel(privateReel.id)],
            reels: [privateReel], pois: [privatePlace], likes: [UUID()], comments: [])
        var publicReel = fixture.reel()
        publicReel.message = "Published summary"
        publicReel.visibility = .publicAll
        publicReel.capsuleId = bubble.id
        store.saveReel(privateReel, audience: .privateMyMap)
        store.saveReel(publicReel, audience: .livePublic)
        store.savePOI(privatePlace, publicVersion: publicPlace, audience: .livePublic)
        store.saveBubble(bubble, audience: .livePublic)
        let baseline = HighlightUnrelatedContent(store)

        var folder = store.createJourneyFolder(title: bubble.title,
            memberReferences: bubble.orderedMemberReferences)
        #expect(HighlightUnrelatedContent(store) == baseline)
        folder.title = "Renamed only in MyMap"
        folder.memberReferences.reverse()
        _ = try #require(store.saveJourneyFolder(folder))
        #expect(HighlightUnrelatedContent(store) == baseline)
        folder.memberReferences.removeAll()
        _ = try #require(store.saveJourneyFolder(folder))
        #expect(HighlightUnrelatedContent(store) == baseline)
        _ = try #require(store.addReel(privateReel.id, toJourneyFolder: folder.id))
        #expect(HighlightUnrelatedContent(store) == baseline)
        store.deleteJourneyFolder(id: folder.id)
        #expect(HighlightUnrelatedContent(store) == baseline)
        #expect(fixture.makeStore().journeyFolders.isEmpty)
    }
}

@MainActor
private struct HighlightPersistenceFixture {
    let ownerID = UUID()

    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackendAccounts/\(ownerID.uuidString)", isDirectory: true)
    }

    var storageURL: URL { directory.appendingPathComponent("collections.json") }

    func makeStore() -> MyMapArchiveStore {
        MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
    }

    func cleanup() {
        // Every fixture has a fresh account UUID; never remove the shared BackendAccounts parent.
        try? FileManager.default.removeItem(at: directory)
    }

    func reel(id: UUID = UUID()) -> RealPost {
        let date = Date(timeIntervalSinceReferenceDate: 600_000_000)
        return RealPost(id: id, userId: ownerID,
            center: .init(latitude: 20.824, longitude: -156.921), radiusMeters: 150,
            message: "Private memory", attachments: [.init(kind: .emoji("🌴"))],
            likes: [], comments: [], visibility: .privateOnly,
            createdAt: date, expiresAt: date.addingTimeInterval(72 * 60 * 60))
    }

    func place() -> RatedPOI {
        let date = Date(timeIntervalSinceReferenceDate: 600_000_000)
        return RatedPOI(
            poi: .init(id: UUID(), name: "Lānaʻi café",
                coordinate: .init(latitude: 20.824, longitude: -156.921), category: .coffee),
            highlight: "Original place", secondary: nil, media: [],
            checkIns: [
                .init(userId: ownerID, createdAt: date),
                .init(userId: ownerID, createdAt: date.addingTimeInterval(60), publishedAt: date.addingTimeInterval(60))
            ],
            comments: [], endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: [], isFavoritedByCurrentUser: false, favoritesCount: 0)
    }
}

/// RealPost equality compares IDs only. Capture mutable content explicitly so
/// these tests detect accidental publication, rewriting or attachment changes.
@MainActor
private struct HighlightUnrelatedContent: Equatable {
    private struct Reel: Equatable {
        let id: UUID
        let message: String?
        let attachments: [RealPost.Attachment]
        let capsuleID: UUID?
        let visibility: RealPost.Visibility
        let createdAt: Date
        let publishedAt: Date?

        init(_ reel: RealPost) {
            id = reel.id
            message = reel.message
            attachments = reel.attachments
            capsuleID = reel.capsuleId
            visibility = reel.visibility
            createdAt = reel.createdAt
            publishedAt = reel.publishedAt
        }
    }

    private struct Bubble: Equatable {
        let id: UUID
        let title: String
        let content: String
        let references: [JourneyFolder.MemberReference]
        let reels: [Reel]
        let places: [RatedPOI]
        let createdAt: Date
        let likes: [UUID]

        init(_ bubble: JourneyPost) {
            id = bubble.id
            title = bubble.title
            content = bubble.content
            references = bubble.orderedMemberReferences
            reels = bubble.reels.map(Reel.init)
            places = bubble.pois
            createdAt = bubble.createdAt
            likes = bubble.likes
        }
    }

    private let privateReels: [Reel]
    private let publicReels: [Reel]
    private let privatePlaces: [RatedPOI]
    private let publicPlaces: [RatedPOI]
    private let privateBubbles: [Bubble]
    private let publicBubbles: [Bubble]

    init(_ store: MyMapArchiveStore) {
        privateReels = store.privateReels.map(Reel.init)
        publicReels = store.publicReelOverlays.map(Reel.init)
        privatePlaces = store.privatePOIs
        publicPlaces = store.publicPOIOverlays
        privateBubbles = store.privateBubbleCatalog.map(Bubble.init)
        publicBubbles = store.publicBubbleCatalog.map(Bubble.init)
    }
}

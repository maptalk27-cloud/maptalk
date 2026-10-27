import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct BackendPlaceSelectionTests {
    @Test
    func freshKnownDirectoryCategoryWinsForSelectionWithoutRewritingStoredPlace() async throws {
        for oldCategory in [POICategory.other, .restaurant] {
            let fixture = try await makeStore(category: oldCategory)
            defer { fixture.store.clearLocalMedia() }
            let directory = POI(id: fixture.sourceID, name: "New directory label",
                coordinate: .init(latitude: 47.449, longitude: -122.307), category: .market,
                directoryKind: .airport)
            let selected = fixture.store.canonicalPlaceForSelection(directory, fromDirectory: true)
            #expect(selected.category == .market)
            #expect(selected.id == fixture.record.place?.id)
            #expect(selected.name == fixture.record.place?.name)
            #expect(selected.coordinate.latitude == fixture.record.place?.coordinate.latitude)
            #expect(selected.coordinate.longitude == fixture.record.place?.coordinate.longitude)
            #expect(selected.directoryKind == nil, "A display-category correction must never grant the airport radius")
            #expect(fixture.store.ownedMemories[fixture.record.id]?.place?.category == oldCategory.rawValue)
            #expect(fixture.store.archive.privatePOIs.first?.poi.category == oldCategory)

            var socialCopy = selected
            socialCopy.category = oldCategory
            let mergedAgain = fixture.store.canonicalPlaceForSelection(socialCopy)
            #expect(mergedAgain.category == .market, "The second provenance/social merge must not put the stale category back")
        }
    }

    @Test
    func unknownCategoriesAndUntrustedCanonicalCopiesCannotOverwriteKnownClassification() async throws {
        let fixture = try await makeStore(category: .coffee)
        defer { fixture.store.clearLocalMedia() }
        var directory = POI(id: fixture.sourceID, name: "Known place",
            coordinate: .init(latitude: 47.448, longitude: -122.308), category: .other)
        #expect(fixture.store.canonicalPlaceForSelection(directory, fromDirectory: true).category == .coffee)
        directory.category = .nightlife
        #expect(fixture.store.canonicalPlaceForSelection(directory).category == .coffee,
                "Only explicitly sourced directory results can refresh classification")
        directory = POI(id: try #require(fixture.record.place?.id), name: directory.name,
            coordinate: directory.coordinate, category: .nightlife)
        #expect(fixture.store.canonicalPlaceForSelection(directory, fromDirectory: true).category == .coffee,
                "A server ID is not evidence of a matching Apple directory result")
    }

    @Test
    func directoryDisplayCorrectionsAreNotPersistedToAnotherStoreSession() async throws {
        let fixture = try await makeStore(category: .other)
        defer { fixture.store.clearLocalMedia() }
        let directory = POI(id: fixture.sourceID, name: "Known place",
            coordinate: .init(latitude: 47.448, longitude: -122.308), category: .market)
        #expect(fixture.store.canonicalPlaceForSelection(directory, fromDirectory: true).category == .market)
        let restored = BackendStore(user: fixture.store.user, api: fixture.store.api,
            storageDirectory: fixture.path, automaticallySync: false, observesConnectivity: false)
        #expect(await restored.restoreCachedState())
        #expect(restored.canonicalPlaceForSelection(directory).category == .other)
        restored.clearLocalMedia()
    }

    private func makeStore(category: POICategory) async throws
        -> (store: BackendStore, record: BackendMemory, sourceID: UUID, path: URL) {
        let user = BackendUser(id: UUID(), handle: "directory_category")
        let sourceID = UUID()
        let place = BackendPlace(id: UUID(), sourceId: sourceID, name: "Stored place",
            category: category.rawValue, coordinate: .init(latitude: 47.448, longitude: -122.308))
        let record = BackendMemory(id: UUID(), ownerId: user.id, owner: user, kind: "poi", visibility: "public",
            location: place.coordinate, caption: "", place: place, media: [], createdAt: .now,
            publishedAt: .now, expiresAt: .now.addingTimeInterval(72 * 3_600))
        let api = BackendAPI(baseURL: URL(string: "https://example.test")!)
        var state = BackendLocalState(ownerID: user.id, server: api.baseURL.absoluteString, user: user)
        state.mine = [record]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendLocalStateDisk(directory: path)
        try await disk.save(state, revision: 1)
        let store = BackendStore(user: user.user, api: api, storageDirectory: path,
            automaticallySync: false, observesConnectivity: false)
        #expect(await store.restoreCachedState())
        return (store, record, sourceID, path)
    }
}

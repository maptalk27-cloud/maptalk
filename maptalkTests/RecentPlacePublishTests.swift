import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct RecentPlacePublishTests {
    @Test func recommendationsAndCheckInsUseOnlyCurrentGPS() {
        let origin = CurrentPlacePublishFixture.origin
        #expect(POISelectionPolicy.radius(for: nil) == 150)
        #expect(POISelectionPolicy.radius(for: .airport) == 150)
        #expect(POISelectionPolicy.publicationRadius(for: nil) == 500)
        #expect(POISelectionPolicy.publicationRadius(for: .airport) == 500)
        #expect(POISelectionPolicy.canPublish(at: CurrentPlacePublishFixture.point(499), kind: nil, from: origin))
        #expect(!POISelectionPolicy.canPublish(at: CurrentPlacePublishFixture.point(501), kind: nil, from: origin))
        #expect(!POISelectionPolicy.canPublish(at: CurrentPlacePublishFixture.point(1_500), kind: .airport, from: origin))
    }

    @Test func widerCurrentCheckInQueuesOfflineWithoutVisitFieldsOrMovingLandmark() async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: 500)
        defer { fixture.finish() }
        let place = CurrentPlacePublishFixture.rated(450)
        _ = try await fixture.store.enqueuePublish(.place(.init(target: .existing(place), media: nil)),
            audience: .livePublic, location: CurrentPlacePublishFixture.origin, requestID: UUID())
        let input = try #require(try await fixture.state().queued.first?.input)
        #expect(input.placeVisit == nil && input.photoVisit == nil && input.videoVisit == nil)
        #expect(input.location.latitude == CurrentPlacePublishFixture.origin.coordinate.latitude)
        #expect(input.place?.coordinate?.latitude == place.poi.coordinate.latitude)
        #expect(input.capturedAt != nil)
    }

    @Test(arguments: [Double?.none, 150, 499])
    func oldServerBlocksWiderChoiceBeforeEnqueueButStillAllowsNearby(radius: Double?) async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: radius)
        defer { fixture.finish() }
        do {
            _ = try await fixture.store.enqueuePublish(.place(.init(
                target: .existing(CurrentPlacePublishFixture.rated(450)), media: nil)),
                audience: .livePublic, location: CurrentPlacePublishFixture.origin, requestID: UUID())
            Issue.record("Wider check-ins need an explicit current-radius capability")
        } catch {
            #expect(error.localizedDescription.contains("150 m"))
        }
        #expect(fixture.store.pendingPublications.isEmpty)
        _ = try await fixture.store.enqueuePublish(.place(.init(
            target: .existing(CurrentPlacePublishFixture.rated(90)), media: nil)),
            audience: .livePublic, location: CurrentPlacePublishFixture.origin, requestID: UUID())
        #expect(fixture.store.pendingPublications.count == 1)
    }

    @Test func capabilityMustBeExplicitAndLegacyFlagsCannotEnableIt() throws {
        let old = try JSONDecoder().decode(BackendAPI.PostLocationCapabilities.self, from: Data(
            "{\"supportsRecentPlaceVisits\":true,\"supportsPhotoPlaceVisits\":true,\"supportsVideoPlaceVisits\":true,\"supportsMediaPlaceVisits\":true}".utf8))
        #expect(old.poiCheckInRadiusMeters == nil)
        let current = try JSONDecoder().decode(BackendAPI.PostLocationCapabilities.self,
            from: Data("{\"poiCheckInRadiusMeters\":500}".utf8))
        #expect(current.poiCheckInRadiusMeters == 500)
    }

    @Test(arguments: ["place", "photo", "video"])
    func previouslyQueuedVisitPayloadRetriesUnchanged(source: String) async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: 500)
        defer { fixture.finish() }
        let requestID = UUID()
        let media: RatedPOI.Media = source == "video"
            ? .init(kind: .video(url: fixture.media, poster: nil)) : .init(kind: .photo(fixture.media))
        let draft = MapTalkPublishDraft.place(.init(
            target: .existing(CurrentPlacePublishFixture.rated(90)), media: media))
        _ = try await fixture.store.enqueuePublish(draft, audience: .livePublic,
            location: CurrentPlacePublishFixture.origin, requestID: requestID)
        var state = try await fixture.state()
        let coordinate = BackendCoordinate(latitude: 21.27799, longitude: -157.83353)
        let time = "2026-11-12T12:40:00.000Z"
        switch source {
        case "place":
            state.queued[0].input.placeVisit = .init(location: coordinate, recordedAt: time, horizontalAccuracy: 20)
        case "photo": state.queued[0].input.photoVisit = .init(location: coordinate, capturedAt: time)
        default: state.queued[0].input.videoVisit = .init(location: coordinate, capturedAt: time)
        }
        try await BackendLocalStateDisk(directory: fixture.path).save(state, revision: 2)
        let restored = BackendStore(user: fixture.store.user, api: fixture.store.api,
            storageDirectory: fixture.path, automaticallySync: false, observesConnectivity: false)
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        _ = try await restored.enqueuePublish(draft, audience: .livePublic,
            location: CLLocation(latitude: 0, longitude: 0), requestID: requestID)
        let after = try await fixture.state()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(state.queued[0].input) == encoder.encode(after.queued[0].input))
    }
}

/// Offline queue fixtures only; prepared bytes are copied, not decoded or uploaded.
@MainActor
struct CurrentPlacePublishFixture {
    static let origin = CLLocation(latitude: 47.5, longitude: -122.2)
    let store: BackendStore
    let path: URL
    let root: URL
    let media: URL

    static func point(_ meters: Double) -> CLLocationCoordinate2D {
        .init(latitude: origin.coordinate.latitude + meters / 111_195, longitude: origin.coordinate.longitude)
    }

    static func rated(_ meters: Double) -> RatedPOI {
        .init(poi: .init(id: UUID(), name: "Cafe", coordinate: point(meters), category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    static func make(radius: Double?) async throws -> Self {
        let user = BackendUser(id: UUID(), handle: "current_place_test")
        let api = BackendAPI(baseURL: URL(string: "https://example.test")!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("state")
        var state = BackendLocalState(ownerID: user.id, server: api.baseURL.absoluteString, user: user)
        state.poiCheckInRadiusMeters = radius
        try await BackendLocalStateDisk(directory: path).save(state, revision: 1)
        let media = root.appendingPathComponent("prepared-media.bin")
        try Data("local-only prepared-media queue fixture".utf8).write(to: media)
        let store = BackendStore(user: user.user, api: api, storageDirectory: path,
            automaticallySync: false, observesConnectivity: false)
        #expect(await store.restoreCachedState())
        return .init(store: store, path: path, root: root, media: media)
    }

    func state() async throws -> BackendLocalState {
        try #require(try await BackendLocalStateDisk(directory: path).load())
    }

    func finish() {
        store.clearLocalMedia()
        try? FileManager.default.removeItem(at: root)
    }
}

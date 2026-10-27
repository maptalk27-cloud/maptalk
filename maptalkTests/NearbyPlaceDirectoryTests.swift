import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct NearbyPlaceDirectoryTests {
    private let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)

    @Test
    func airportAllowanceUsesDirectoryClassificationNotItsName() throws {
        let item = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        item.name = "Airport coffee"
        item.pointOfInterestCategory = .cafe
        #expect(ApplePOIRepository.makeRatedPOI(from: item)?.poi.directoryKind == nil)
        item.name = "Seattle-Tacoma International Airport"
        item.pointOfInterestCategory = .airport
        let airport = try #require(ApplePOIRepository.makeRatedPOI(from: item))
        #expect(airport.poi.directoryKind == .airport)
        #expect(POISelectionPolicy.radius(for: airport.poi.directoryKind) == 2_000)
        #expect(POISelectionPolicy.radius(for: nil) == 150)
    }

    @Test
    func directoryKeepsOneAirportWithoutWideningOrdinaryPlacesOrMovingIt() {
        let nearby = (0..<35).map { place(metersNorth: Double(5 + $0)) }
        let airport = place(metersNorth: 1_200, kind: .airport)
        let otherAirport = place(metersNorth: 1_600, kind: .airport)
        let tooFar = place(metersNorth: 2_200, kind: .airport)
        let remoteShop = place(metersNorth: 500)
        let result = ApplePOIRepository.candidates(nearby + [airport, airport, otherAirport, tooFar, remoteShop], near: origin)
        #expect(result.count == 30)
        #expect(result.filter { $0.poi.directoryKind == .airport }.map(\.id) == [airport.id])
        #expect(!result.contains { $0.id == remoteShop.id || $0.id == tooFar.id })
        #expect(result.first { $0.id == airport.id }?.poi.coordinate.latitude == airport.poi.coordinate.latitude)
    }

    @Test
    func cacheOnlyBridgesTransientErrorsAtTheSameLocationForFiveMinutes() {
        let place = place(metersNorth: 20)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var cache = AppleNearbyPlaceCache()
        #expect(cache.resolve([place], for: .nearby, near: origin, at: now).map(\.id) == [place.id])
        #expect(cache.resolve(nil, for: .nearby, near: origin, at: now.addingTimeInterval(299)).map(\.id) == [place.id])
        #expect(cache.resolve(nil, for: .nearby, near: origin, at: now.addingTimeInterval(301)).isEmpty)
        #expect(cache.resolve(nil, for: .airports, near: origin, at: now).isEmpty)
        let moved = coordinate(metersNorth: 100)
        #expect(cache.resolve(nil, for: .nearby, near: moved, at: now.addingTimeInterval(10)).isEmpty)
        #expect(cache.resolve([], for: .nearby, near: origin, at: now.addingTimeInterval(20)).isEmpty)
        #expect(cache.resolve(nil, for: .nearby, near: origin, at: now.addingTimeInterval(21)).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func pickerKeepsAllEligiblePlacesAndCanRetryWithoutMoving() async throws {
        let airport = place(metersNorth: 1_200, kind: .airport)
        let secondAirport = place(metersNorth: 1_700, kind: .airport)
        let shopOutsideNormalRange = place(metersNorth: 500)
        let directory = NearbyTestRepository((0..<10).map { place(metersNorth: Double(10 + $0 * 5)) }
            + [airport, secondAirport, shopOutsideNormalRange])
        let location = NearbyTestLocation(origin)
        let empty = NearbyTestRepository([])
        let archive = MyMapArchiveStore(startsEmpty: true)
        let environment = AppEnvironment(build: .init(configuration: .debug, featureFlags: []),
            location: location, notifications: NotificationServiceImpl(), activePOIRepo: empty,
            poiRepo: empty, nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive)
        let model = MapTalkViewModel(environment: environment)
        try await waitForDirectory(model, searches: 1, repository: directory)
        let fix = try #require(model.publishableLiveLocation)
        let choices = model.nearbyPlaceOptions(near: fix)
        #expect(choices.count == 12)
        #expect(choices.filter { $0.place.poi.directoryKind == .airport }.map(\.id) == [airport.id, secondAirport.id])
        #expect(!choices.contains { $0.id == shopOutsideNormalRange.id })
        #expect(try #require(choices.first { $0.id == airport.id }).distanceMeters > 1_000)
        let previousCamera = model.region.center
        model.refreshNearbyPlaces()
        try await waitForDirectory(model, searches: 2, repository: directory)
        #expect(model.publishableLiveLocation?.coordinate.latitude == origin.latitude)
        #expect(model.region.center.latitude == previousCamera.latitude)
        #expect(model.region.center.longitude == previousCamera.longitude)

        let saved = try #require(model.publishPlace(.init(target: .existing(airport), media: nil),
            at: fix, audience: .privateMyMap))
        #expect(saved.poi.directoryKind == .airport)
        #expect(archive.privatePOIs.first?.poi.directoryKind == .airport)
        #expect(saved.poi.coordinate.latitude == airport.poi.coordinate.latitude)
        #expect(model.publishPlace(.init(target: .existing(shopOutsideNormalRange), media: nil),
            at: fix, audience: .privateMyMap) == nil)
        let tooFar = place(metersNorth: 2_200, kind: .airport)
        #expect(model.publishPlace(.init(target: .existing(tooFar), media: nil),
            at: fix, audience: .privateMyMap) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func namedSearchAddsMissingVenuesWithoutBypassingProximityOrDuplicatingPlaces() async throws {
        let closePlaces = (0..<8).map { place(metersNorth: Double(10 + $0 * 5)) }
        let edgePlace = place(metersNorth: 145)
        let namedMatch = place(metersNorth: 115)
        let tooFar = place(metersNorth: 200)
        let directory = NearbyTestRepository(closePlaces + [edgePlace])
        let empty = NearbyTestRepository([])
        let archive = MyMapArchiveStore(startsEmpty: true)
        var privateVisit = namedMatch
        privateVisit.checkIns = [.init(userId: archive.currentUserID, createdAt: .now)]
        archive.savePOI(privateVisit, publicVersion: nil, audience: .privateMyMap)
        let environment = AppEnvironment(build: .init(configuration: .debug, featureFlags: []),
            location: NearbyTestLocation(origin), notifications: NotificationServiceImpl(),
            activePOIRepo: empty, poiRepo: empty, nearbyPOIRepo: directory,
            realRepo: NearbyTestReelRepository(), myMapArchive: archive)
        let model = MapTalkViewModel(environment: environment)
        try await waitForDirectory(model, searches: 1, repository: directory)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let choices = model.nearbyPlaceOptions(near: location,
            matching: [namedMatch, namedMatch, closePlaces[0], tooFar])

        #expect(choices.count == 10)
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(choices.contains { $0.id == edgePlace.id }, "150 m is the actual ordinary-place boundary")
        #expect(!choices.contains { $0.id == tooFar.id })
        let searched = try #require(choices.first { $0.id == namedMatch.id })
        #expect(searched.isPublicDirectoryPlace)
        #expect(searched.isInMyMap)
        #expect(searched.publicVisitorCount == 0, "Private visits must never become public social proof")
        #expect(searched.place.checkIns.count == 1)
    }

    @Test
    func optionalDirectoryMetadataDecodesOldStateAndRoundTripsNewState() throws {
        let oldJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Existing place","category":"other",
         "coordinate":{"latitude":47.448,"longitude":-122.308}}
        """
        let old = try JSONDecoder().decode(BackendPlace.self, from: Data(oldJSON.utf8))
        #expect(old.directoryKind == nil)
        var airport = old
        airport.directoryKind = "airport"
        let decoded = try JSONDecoder().decode(BackendPlace.self, from: JSONEncoder().encode(airport))
        #expect(decoded.directoryKind == "airport")
        let input = BackendPlaceInput(name: airport.name, category: airport.category,
            coordinate: airport.coordinate, sourceId: airport.id, directoryKind: "airport")
        let saved = try JSONDecoder().decode(BackendPlaceInput.self, from: JSONEncoder().encode(input))
        #expect(saved.directoryKind == "airport")
        #expect(saved.coordinate?.latitude == airport.coordinate.latitude)
    }

    @Test
    func missingDirectoryMetadataPreservesTheLegacyPublicationFingerprintExactly() {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let url = URL(fileURLWithPath: "/tmp/pending-photo.jpg")
        var input = BackendMemoryInput(id: UUID(), kind: "poi", visibility: "public",
            location: .init(latitude: origin.latitude, longitude: origin.longitude),
            place: .init(name: "Old place", category: "other", sourceId: sourceID))
        let expected = ["poi", "public", "", "Old place", "other", sourceID.uuidString, "",
                        url.absoluteString, "image/jpeg"].joined(separator: "\u{0}")
        let actual = BackendStore.publicationFingerprint(for: input, urls: [url], contentTypes: ["image/jpeg"])
        #expect(Array(actual.utf8) == Array(expected.utf8))
        input.place?.directoryKind = "airport"
        let airport = BackendStore.publicationFingerprint(for: input, urls: [url], contentTypes: ["image/jpeg"])
        #expect(airport == expected + "\u{0}directoryKind=airport")
        #expect(airport != actual)

        let reel = BackendMemoryInput(id: UUID(), kind: "reel", visibility: "private",
            location: input.location, caption: "Existing draft")
        let oldReel = ["reel", "private", "Existing draft", "", "", "", ""].joined(separator: "\u{0}")
        #expect(BackendStore.publicationFingerprint(for: reel, urls: [], contentTypes: []) == oldReel)
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedAirportMetadataSurvivesDiskReloadWithoutChangingItsGPSAnchor() async throws {
        let user = BackendUser(id: UUID(), handle: "airport_test")
        let gps = BackendCoordinate(latitude: origin.latitude, longitude: origin.longitude)
        let center = BackendCoordinate(latitude: origin.latitude + 0.01, longitude: origin.longitude)
        let place = BackendPlace(id: UUID(), sourceId: UUID(), name: "Airport", category: "other",
            coordinate: center, directoryKind: "airport")
        let input = BackendMemoryInput(id: UUID(), kind: "poi", visibility: "public", location: gps,
            place: .init(name: place.name, category: place.category, coordinate: center,
                         sourceId: place.sourceId, directoryKind: "airport"))
        let record = BackendMemory(id: input.id, ownerId: user.id, owner: user, kind: "poi", visibility: "private",
            location: gps, caption: "", place: place, media: [], createdAt: .now, publishedAt: nil,
            expiresAt: .distantFuture, moderationStatus: "local_pending")
        var state = BackendLocalState(ownerID: user.id, server: "https://example.test", user: user)
        state.mine = [record]
        state.queued = [.init(input: input, record: record, photos: [])]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendLocalStateDisk(directory: directory)
        defer { disk.invalidate() }
        try await disk.save(state, revision: 1)
        let restored = try #require(try await BackendLocalStateDisk(directory: directory).load())
        #expect(restored.mine.first?.place?.directoryKind == "airport")
        #expect(restored.queued.first?.record.place?.directoryKind == "airport")
        #expect(restored.queued.first?.input.place?.directoryKind == "airport")
        #expect(restored.queued.first?.input.location.latitude == gps.latitude)
        #expect(restored.queued.first?.input.place?.coordinate?.latitude == center.latitude)

        // Actual pre-field JSON has no directoryKind keys at any nesting level.
        state.mine[0].place?.directoryKind = nil
        state.queued[0].record.place?.directoryKind = nil
        state.queued[0].input.place?.directoryKind = nil
        let oldBytes = try JSONEncoder().encode(state)
        #expect(!String(decoding: oldBytes, as: UTF8.self).contains("directoryKind"))
        let oldState = try JSONDecoder().decode(BackendLocalState.self, from: oldBytes)
        #expect(oldState.queued.first?.input.place?.directoryKind == nil)
        #expect(oldState.queued.first?.record.place?.directoryKind == nil)
        #expect(oldState.mine.first?.place?.directoryKind == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func appleMetadataCannotWidenALegacyCanonicalPlacesServerRadius() async throws {
        let user = BackendUser(id: UUID(), handle: "legacy_place_test")
        let appleAirport = place(metersNorth: 1_200, kind: .airport)
        let newAppleAirport = place(metersNorth: 1_500, kind: .airport)
        let canonicalID = UUID()
        let serverPlace = BackendPlace(id: canonicalID, sourceId: appleAirport.id,
            name: appleAirport.poi.name, category: "other",
            coordinate: .init(latitude: appleAirport.poi.coordinate.latitude,
                              longitude: appleAirport.poi.coordinate.longitude))
        let record = BackendMemory(id: UUID(), ownerId: user.id, owner: user, kind: "poi", visibility: "public",
            location: serverPlace.coordinate, caption: "", place: serverPlace, media: [],
            createdAt: .now, publishedAt: .now, expiresAt: .now.addingTimeInterval(72 * 3_600))
        let api = BackendAPI(baseURL: URL(string: "https://example.test")!)
        var state = BackendLocalState(ownerID: user.id, server: api.baseURL.absoluteString, user: user)
        state.mine = [record]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendLocalStateDisk(directory: path)
        defer { disk.invalidate() }
        try await disk.save(state, revision: 1)
        let store = BackendStore(user: user.user, api: api, storageDirectory: path,
            automaticallySync: false, observesConnectivity: false)
        defer { store.clearLocalMedia() }
        #expect(await store.restoreCachedState())
        let legacy = store.canonicalPlaceForSelection(appleAirport.poi)
        #expect(legacy.id == canonicalID)
        #expect(legacy.directoryKind == nil)
        #expect(POISelectionPolicy.radius(for: legacy.directoryKind) == 150)
        #expect(store.canonicalPlaceForSelection(newAppleAirport.poi).directoryKind == .airport)

        let directory = NearbyTestRepository([appleAirport, newAppleAirport])
        let empty = NearbyTestRepository([])
        let environment = AppEnvironment(build: .init(configuration: .debug, featureFlags: []),
            location: NearbyTestLocation(origin), notifications: NotificationServiceImpl(), activePOIRepo: empty,
            poiRepo: empty, nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(),
            myMapArchive: store.archive, backend: store)
        let model = MapTalkViewModel(environment: environment)
        try await waitForDirectory(model, searches: 1, repository: directory)
        let choices = model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        #expect(choices.map(\.id) == [newAppleAirport.id])
        let nearbyChoices = model.nearbyPlaceOptions(near: CLLocation(latitude: legacy.coordinate.latitude,
                                                                    longitude: legacy.coordinate.longitude))
        let existingChoice = try #require(nearbyChoices.first { $0.id == canonicalID })
        #expect(existingChoice.place.poi.directoryKind == nil)
    }

    private func waitForDirectory(_ model: MapTalkViewModel, searches: Int,
                                  repository: NearbyTestRepository) async throws {
        for _ in 0..<100 {
            if repository.searchCount >= searches, !model.isLoadingNearbyPlaces { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Nearby directory did not complete the expected search")
    }

    private func coordinate(metersNorth: Double) -> CLLocationCoordinate2D {
        .init(latitude: origin.latitude + metersNorth / 111_200, longitude: origin.longitude)
    }

    private func place(metersNorth: Double, kind: POIDirectoryKind? = nil) -> RatedPOI {
        .init(poi: .init(id: UUID(), name: "Directory place", coordinate: coordinate(metersNorth: metersNorth),
                        category: .other, directoryKind: kind),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }
}

@MainActor
private final class NearbyTestRepository: POIRepository, ActivePOIRepository {
    let places: [RatedPOI]
    private(set) var searchCount = 0
    init(_ places: [RatedPOI]) { self.places = places }
    func near(_: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        searchCount += 1
        return Just(places).eraseToAnyPublisher()
    }
    func active(in _: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> { Just(places).eraseToAnyPublisher() }
}

private final class NearbyTestLocation: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.authorizedWhenInUse)
    let location: CurrentValueSubject<CLLocation?, Never>
    init(_ coordinate: CLLocationCoordinate2D) {
        location = .init(CLLocation(coordinate: coordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now))
    }
    func requestWhenInUse() {}
}

private final class NearbyTestReelRepository: RealRepository {
    func active(in _: MKMapRect?) -> AnyPublisher<[RealPost], Never> { Just([]).eraseToAnyPublisher() }
}

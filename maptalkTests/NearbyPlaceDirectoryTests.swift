import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct NearbyPlaceDirectoryTests {
    private let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)

    @Test(.timeLimit(.minutes(1)))
    func postLocationLibraryTracksCommittedArchiveWithoutGPSOrDirectorySearch() async throws {
        let archive = MyMapArchiveStore(currentUserID: UUID(), startsEmpty: true)
        let initial = RealPost(id: UUID(), userId: archive.currentUserID, center: origin,
            radiusMeters: 220, message: "Seattle memory", attachments: [], likes: [], comments: [],
            visibility: .privateOnly, createdAt: .distantPast, expiresAt: .distantPast,
            locationName: "Seattle", locationID: UUID())
        var visited = place(metersNorth: 200, name: "Old Seattle visit")
        visited.checkIns = [.init(userId: archive.currentUserID, createdAt: .distantPast)]
        var savedOnly = place(metersNorth: 20_000, name: "Saved but not visited")
        savedOnly.isFavoritedByCurrentUser = true
        archive.replaceServerRecords(pois: [visited, savedOnly], reels: [initial])
        let service = NearbyTestLocation(origin)
        service.location.send(nil)
        let directory = NearbyTestRepository([])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: service,
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        defer { model.setMapActivity(false) }

        // CurrentValueSubject must replay the committed initial archive during
        // initialization, not after a GPS fix or asynchronous directory result.
        #expect(model.publishableLiveLocation == nil)
        #expect(model.postLocationLibrary.choices.map(\.selection.title) == ["Seattle"])
        let seattle = try #require(model.postLocationLibrary.choices.first?.selection)
        #expect(model.postPublicationLocation(for: seattle) != nil)
        #expect(model.postLocationLibrary.coverage.areas.map(\.id) == [visited.id])
        let visitedSelection = MapTalkPostLocationSelection(coordinate: visited.poi.coordinate,
            title: "New Seattle spot", locationName: "New Seattle spot", locationID: UUID())
        let savedSelection = MapTalkPostLocationSelection(coordinate: savedOnly.poi.coordinate,
            title: "Saved only", locationName: "Saved only", locationID: UUID())
        #expect(model.postPublicationLocation(for: visitedSelection) != nil)
        #expect(model.postPublicationLocation(for: savedSelection) == nil)
        #expect(directory.searchCount == 0)

        let hawaii = CLLocationCoordinate2D(latitude: 21.3099, longitude: -157.8581)
        let added = RealPost(id: UUID(), userId: archive.currentUserID, center: hawaii,
            radiusMeters: 220, message: "Hawaii memory", attachments: [], likes: [], comments: [],
            visibility: .privateOnly, createdAt: .now, expiresAt: .now,
            locationName: "Hawaii", locationID: UUID())
        archive.saveReel(added, audience: .privateMyMap)
        #expect(model.postLocationLibrary.choices.map(\.selection.title) == ["Hawaii", "Seattle"],
                "A synchronous local save must immediately update the bound library")
        let addedSelection = try #require(model.postLocationLibrary.choices.first?.selection)
        archive.replaceServerRecords(pois: [visited, savedOnly], reels: [initial])
        #expect(model.postLocationLibrary.choices.map(\.selection.title) == ["Seattle"])
        #expect(model.postPublicationLocation(for: addedSelection) == nil)
        #expect(directory.searchCount == 0)

        let libraryRevision = model.postLocationLibrary.revision
        let coverageRevision = model.postLocationLibrary.coverage.revision
        service.location.send(CLLocation(coordinate: hawaii, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now))
        try await waitForDirectory(model, searches: 1, repository: directory)
        #expect(model.postLocationLibrary.revision == libraryRevision)
        #expect(model.postLocationLibrary.coverage.revision == coverageRevision)
        #expect(model.postPublicationLocation(for: seattle) != nil,
                "Moving to Hawaii must not remove an owned Seattle Post location")
        #expect(model.postPublicationLocation(for: visitedSelection) != nil)

        service.location.send(nil)
        archive.replaceServerRecords(pois: [], reels: [])
        #expect(model.postLocationLibrary.choices.isEmpty)
        #expect(model.postLocationLibrary.coverage.areas.isEmpty)
        #expect(model.postPublicationLocation(for: seattle) == nil)
        #expect(model.postPublicationLocation(for: visitedSelection) == nil)
    }

    @Test
    func airportClassificationDoesNotChangeTheCurrentLocationRadius() throws {
        let item = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        item.name = "Airport coffee"
        item.pointOfInterestCategory = .cafe
        #expect(ApplePOIRepository.makeRatedPOI(from: item)?.poi.directoryKind == nil)
        item.name = "Seattle-Tacoma International Airport"
        item.pointOfInterestCategory = .airport
        let airport = try #require(ApplePOIRepository.makeRatedPOI(from: item))
        #expect(airport.poi.directoryKind == .airport)
        #expect(POISelectionPolicy.radius(for: airport.poi.directoryKind) == 150)
        #expect(POISelectionPolicy.radius(for: nil) == 150)
        #expect(POISelectionPolicy.publicationRadius(for: airport.poi.directoryKind) == 500)
        #expect(POISelectionPolicy.publicationRadius(for: nil) == 500)
    }

    @Test
    func directoryAppliesOneNearbyRadiusWithoutMovingOrDuplicatingPlaces() {
        let nearby = (0..<35).map { place(metersNorth: Double(5 + $0)) }
        let airport = place(metersNorth: 15.5, kind: .airport)
        let otherAirport = place(metersNorth: 1_600, kind: .airport)
        let tooFar = place(metersNorth: 2_200, kind: .airport)
        let remoteShop = place(metersNorth: 500)
        let result = ApplePOIRepository.candidates(nearby + [airport, airport, otherAirport, tooFar, remoteShop], near: origin)
        #expect(result.count == 30)
        #expect(Set(result.map(\.id)).count == result.count)
        #expect(result.filter { $0.poi.directoryKind == .airport }.map(\.id) == [airport.id])
        #expect(!result.contains { $0.id == remoteShop.id || $0.id == tooFar.id || $0.id == otherAirport.id })
        #expect(result.allSatisfy { POISelectionPolicy.distance(from: origin, to: $0.poi.coordinate) <= 150 })
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
        let airport = place(metersNorth: 120, kind: .airport)
        let secondAirport = place(metersNorth: 140, kind: .airport)
        let shopOutsideNormalRange = place(metersNorth: 450)
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
        #expect(Set(choices.filter { $0.place.poi.directoryKind == .airport }.map(\.id)) == Set([airport.id, secondAirport.id]))
        #expect(!choices.contains { $0.id == shopOutsideNormalRange.id })
        #expect(try #require(choices.first { $0.id == airport.id }).distanceMeters < 150)
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
            at: fix, audience: .privateMyMap) != nil, "A searched place may be outside the 150 m recommendation radius")
        #expect(model.publishPlace(.init(target: .existing(place(metersNorth: 600)), media: nil),
            at: fix, audience: .privateMyMap) == nil)
        let tooFar = place(metersNorth: 600, kind: .airport)
        #expect(model.publishPlace(.init(target: .existing(tooFar), media: nil),
            at: fix, audience: .privateMyMap) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func searchUsesOnlyCurrentGPSWithoutExpandingRecommendationsOrShrinkingPostRange() async throws {
        let local = place(metersNorth: 80)
        let searched = place(metersNorth: 450)
        let postOnly = place(metersNorth: 4_500)
        let remote = place(metersNorth: 6_000)
        var oldCheckInOnly = place(metersNorth: 8_000)
        let archive = MyMapArchiveStore(startsEmpty: true)
        oldCheckInOnly.checkIns = [.init(userId: archive.currentUserID, createdAt: .now)]
        archive.savePOI(oldCheckInOnly, publicVersion: nil, audience: .privateMyMap)
        let service = NearbyTestLocation(origin)
        let directory = NearbyTestRepository([local, searched, postOnly, remote])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: service,
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)
        #expect(model.nearbyPlaceOptions(near: gps).map(\.id) == [local.id])
        let search = model.nearbyPlaceOptions(near: gps, withinMeters: POISelectionPolicy.searchRadius,
            matching: [searched, postOnly, remote, oldCheckInOnly])
        #expect(Set(search.map(\.id)) == Set([local.id, searched.id]))
        let postOptions = model.nearbyPlaceOptions(near: gps, withinMeters: PostLocationPolicy.radius)
        #expect(Set(postOptions.map(\.id)) == Set([local.id, searched.id, postOnly.id]))
        #expect(model.publishPlace(.init(target: .existing(oldCheckInOnly), media: nil),
            at: gps, audience: .privateMyMap) == nil, "Past check-ins do not permit a remote check-in")
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultRecommendationsIncludeOnlyOwnCheckInsOutTo500Meters() async throws {
        let archive = MyMapArchiveStore(startsEmpty: true)
        let oldVisit = RatedPOI.CheckIn(userId: archive.currentUserID, createdAt: .distantPast)
        var own300 = place(metersNorth: 300, name: "My old visit")
        var own490 = place(metersNorth: 490, name: "My farther visit")
        var own550 = place(metersNorth: 550, name: "My out-of-range visit")
        own300.checkIns = [oldVisit]
        own490.checkIns = [oldVisit]
        own550.checkIns = [oldVisit]
        var savedOnly = place(metersNorth: 300, name: "Saved only")
        savedOnly.isFavoritedByCurrentUser = true
        var foreignPrivate = place(metersNorth: 300, name: "Another person's private visit")
        foreignPrivate.checkIns = [.init(userId: UUID(), createdAt: .now)]
        let postOnly = place(metersNorth: 300, name: "My Post location")
        let priorPost = RealPost(id: UUID(), userId: archive.currentUserID, center: postOnly.poi.coordinate,
            radiusMeters: 220, message: "A Post is not a POI check-in", attachments: [], likes: [], comments: [],
            visibility: .privateOnly, createdAt: .distantPast, expiresAt: .distantPast,
            locationName: postOnly.poi.name, locationID: postOnly.id)
        archive.replaceServerRecords(pois: [own300, own490, own550, savedOnly, foreignPrivate], reels: [priorPost])
        var otherUsers300 = place(metersNorth: 300, name: "Other people's visits")
        otherUsers300.checkIns = [.init(userId: UUID(), createdAt: .now)]
        let freshNearby = place(metersNorth: 20, name: "New nearby venue")
        let fresh300 = place(metersNorth: 300, name: "New farther venue")
        let directory = NearbyTestRepository([freshNearby, fresh300, savedOnly, postOnly, otherUsers300])
        let social = NearbyTestRepository([otherUsers300])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: social, poiRepo: social,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        defer { model.setMapActivity(false) }
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)
        let choices = model.nearbyPlaceOptions(near: gps)

        #expect(Set(choices.map(\.id)) == Set([own300.id, own490.id, freshNearby.id]))
        #expect(Set(choices.prefix(2).map(\.id)) == Set([own300.id, own490.id]),
                "Actual personal visits within 500 m precede even a very close new venue")
        #expect(choices.last?.id == freshNearby.id)
        let fartherHistory = try #require(choices.first { $0.id == own490.id })
        #expect(fartherHistory.ownCheckIns.map(\.id) == [oldVisit.id])
        #expect(fartherHistory.ownCheckIns.first?.createdAt == .distantPast,
                "Historical check-in eligibility has no visit-age limit")
        #expect(fartherHistory.distanceMeters > 450 && fartherHistory.distanceMeters < 500)
        #expect(fartherHistory.place.poi.coordinate.latitude == own490.poi.coordinate.latitude)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitSearchRadiusKeepsAllPlaceKindsAndHonorsTighterLimits() async throws {
        let archive = MyMapArchiveStore(startsEmpty: true)
        var own = place(metersNorth: 490, name: "My visited venue")
        own.checkIns = [.init(userId: archive.currentUserID, createdAt: .distantPast)]
        var saved = place(metersNorth: 350, name: "My saved venue")
        saved.isFavoritedByCurrentUser = true
        archive.replaceServerRecords(pois: [own, saved], reels: [])
        var publicHistory = place(metersNorth: 400, name: "Public visits")
        publicHistory.checkIns = [.init(userId: UUID(), createdAt: .now)]
        let nearby = place(metersNorth: 20, name: "Nearby venue")
        let fresh = place(metersNorth: 300, name: "New venue")
        let outside = place(metersNorth: 550, name: "Outside search range")
        let directory = NearbyTestRepository([nearby, fresh, outside])
        let social = NearbyTestRepository([publicHistory])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: social, poiRepo: social,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        defer { model.setMapActivity(false) }
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)

        let search = model.nearbyPlaceOptions(near: gps, withinMeters: POISelectionPolicy.searchRadius)
        #expect(Set(search.map(\.id)) == Set([own.id, saved.id, publicHistory.id, nearby.id, fresh.id]))
        #expect(model.nearbyPlaceOptions(near: gps, withinMeters: 150).map(\.id) == [nearby.id],
                "An explicit tighter limit must not be widened for historical visits")
        #expect(POISelectionPolicy.searchRadius == 500)
        #expect(POISelectionPolicy.publicationRadius(for: nil) == 500)
    }

    @Test(.timeLimit(.minutes(1)))
    func searchDeduplicatesCandidatesAndMeasuresEachFromCurrentGPS() async throws {
        let local = place(metersNorth: 80)
        let currentSearch = place(metersNorth: 450)
        let outsideCurrentSearch = place(metersNorth: 900)
        let directory = NearbyTestRepository([local, currentSearch])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(),
            myMapArchive: MyMapArchiveStore(startsEmpty: true)))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)
        let matches = [local, currentSearch, currentSearch, outsideCurrentSearch, outsideCurrentSearch]
        let choices = model.nearbyPlaceOptions(near: gps, withinMeters: POISelectionPolicy.searchRadius,
            matching: matches)

        #expect(Set(choices.map(\.id)) == Set([local.id, currentSearch.id]))
        #expect(choices.count == 2)
        let currentChoice = try #require(choices.first { $0.id == currentSearch.id })
        #expect(currentChoice.distanceMeters > 400 && currentChoice.distanceMeters < 500)
        #expect(currentChoice.place.poi.coordinate.latitude == currentSearch.poi.coordinate.latitude)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func attachedPhotosAndVideosDoNotExpandCurrentGPSCheckInRange(video: Bool) async throws {
        let remote = place(metersNorth: 5_000)
        let nearby = place(metersNorth: 450)
        let directory = NearbyTestRepository([])
        let archive = MyMapArchiveStore(startsEmpty: true)
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: directory, poiRepo: directory,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)
        let url = URL(fileURLWithPath: "/tmp/selected-check-in-media")
        let media = RatedPOI.Media(kind: video ? .video(url: url, poster: nil) : .photo(url))
        let remoteDraft = MapTalkPlaceDraft(target: .existing(remote), media: media)
        #expect(model.publishPlace(remoteDraft, at: gps, audience: .privateMyMap) == nil)
        #expect(archive.privatePOIs.isEmpty)

        let nearbyDraft = MapTalkPlaceDraft(target: .existing(nearby), media: media)
        let saved = try #require(model.publishPlace(nearbyDraft, at: gps, audience: .privateMyMap))
        #expect(saved.id == nearby.id)
        #expect(saved.poi.coordinate.latitude == nearby.poi.coordinate.latitude)
        #expect(saved.poi.coordinate.longitude == nearby.poi.coordinate.longitude)
        #expect(saved.checkIns.count == 1)
        #expect(saved.checkIns.first?.media.map(\.id) == [media.id])
        #expect(archive.privatePOIs.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func createNewUsesCurrentGPSRatherThanTheMapViewportOrRemoteCandidates() async throws {
        let current = place(metersNorth: 40)
        let remote = place(metersNorth: 10_080)
        let service = NearbyTestLocation(origin)
        let directory = NearbyTestRepository([current])
        let empty = NearbyTestRepository([])
        let archive = MyMapArchiveStore(startsEmpty: true)
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: service,
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let gps = try #require(model.publishableLiveLocation)
        model.region.center = remote.poi.coordinate
        #expect(model.nearbyPlaceOptions(near: gps, matching: [remote]).map(\.id) == [current.id])
        #expect(model.nearbyPlaceOptions(near: gps, withinMeters: POISelectionPolicy.searchRadius,
            matching: [remote]).map(\.id) == [current.id])
        #expect(model.publishPlace(.init(target: .existing(remote), media: nil),
            at: gps, audience: .privateMyMap) == nil)
        let created = try #require(model.publishPlace(
            .init(target: .new(name: "Here now", category: .other), media: nil),
            at: gps, audience: .privateMyMap))
        #expect(created.poi.name == "Here now")
        #expect(created.poi.coordinate.latitude == gps.coordinate.latitude)
        #expect(created.poi.coordinate.longitude == gps.coordinate.longitude)
        #expect(archive.privatePOIs.first { $0.id == created.id }?.poi.coordinate.latitude == origin.latitude)
        #expect(model.publishableLiveLocation?.coordinate.latitude == origin.latitude)
    }

    @Test(.timeLimit(.minutes(1)))
    func namedSearchAddsMissingVenuesWithoutBypassingProximityOrDuplicatingPlaces() async throws {
        let closePlaces = (0..<8).map { place(metersNorth: Double(10 + $0 * 5)) }
        let edgePlace = place(metersNorth: 145)
        let namedMatch = place(metersNorth: 450)
        let tooFar = place(metersNorth: 600)
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
        #expect(model.nearbyPlaceOptions(near: location).contains { $0.id == namedMatch.id },
                "An owned visit within 500 m is recommended even before searching")
        let choices = model.nearbyPlaceOptions(near: location, withinMeters: POISelectionPolicy.searchRadius,
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
        #expect(searched.ownCheckIns.count == 1)
        #expect(searched.hasHistory)
        #expect(searched.historyBadge == "Been here", "Search additions must preserve personal history")
    }

    @Test(.timeLimit(.minutes(1)))
    func oldPersonalVisitsKeepTheirRankingSignalAndPrivateHistoryDetails() async throws {
        let archive = MyMapArchiveStore(startsEmpty: true)
        let older = RatedPOI.CheckIn(userId: archive.currentUserID, createdAt: .now.addingTimeInterval(-30 * 86_400))
        let newer = RatedPOI.CheckIn(userId: archive.currentUserID, createdAt: .now.addingTimeInterval(-14 * 86_400))
        let visitedDirectory = place(metersNorth: 90)
        var visited = visitedDirectory
        visited.checkIns = [older, newer, newer]
        archive.savePOI(visited, publicVersion: nil, audience: .privateMyMap)
        var outside = place(metersNorth: 550)
        outside.checkIns = [newer]
        archive.savePOI(outside, publicVersion: nil, audience: .privateMyMap)
        var publicHistory = place(metersNorth: 70)
        publicHistory.checkIns = [.init(userId: UUID(), createdAt: .now)]
        let unused = place(metersNorth: 5)
        let social = NearbyTestRepository([publicHistory])
        let directory = NearbyTestRepository([unused, publicHistory, visitedDirectory])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: social, poiRepo: social,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let choices = model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude))

        #expect(choices.first?.id == visited.id, "Repeat history remains useful even after the live feed expires")
        try #require(choices.count == 3)
        #expect(choices.map(\.historyPriority) == [0, 1, 2])
        #expect(MapTalkNearbyPlaceOption.ranked(Array(choices.reversed())).map(\.id) == choices.map(\.id))
        let ownHistory = try #require(choices.first { $0.id == visited.id })
        #expect(ownHistory.historyPriority == 0)
        #expect(ownHistory.ownCheckIns.map(\.id) == [newer.id, older.id])
        #expect(ownHistory.hasHistory, "Personal visits must not expire with the 72-hour live feed")
        #expect(ownHistory.publicVisitorCount == 0)
        #expect(ownHistory.historyBadge == "Been here")
        #expect(ownHistory.historyDetail?.hasPrefix("You · 2 check-ins · Last ") == true)
        #expect(ownHistory.locationSubtitle.contains(visited.poi.category.displayName))
        let publicChoice = try #require(choices.first { $0.id == publicHistory.id })
        #expect(publicChoice.publicVisitorCount == 1)
        #expect(publicChoice.historyPriority == 1)
        #expect(publicChoice.historyBadge == "Check-ins")
        #expect(publicChoice.historyDetail == "1 person checked in")
        #expect(choices.first { $0.id == unused.id }?.hasHistory == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func savedPlacesAndOtherPeoplesPrivateVisitsDoNotClaimPersonalHistory() async throws {
        let archive = MyMapArchiveStore(startsEmpty: true)
        let saved = place(metersNorth: 10)
        var foreignPrivateVisit = place(metersNorth: 20)
        foreignPrivateVisit.checkIns = [.init(userId: UUID(), createdAt: .now)]
        archive.savePOI(saved, publicVersion: nil, audience: .privateMyMap)
        archive.savePOI(foreignPrivateVisit, publicVersion: nil, audience: .privateMyMap)
        let directory = NearbyTestRepository([saved])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let choices = model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude))

        #expect(Set(choices.map(\.id)) == Set([saved.id, foreignPrivateVisit.id]))
        #expect(choices.allSatisfy { $0.isInMyMap })
        #expect(choices.allSatisfy { $0.ownCheckIns.isEmpty && !$0.hasHistory && $0.historyPriority == 2 })
        #expect(choices.allSatisfy { $0.publicVisitorCount == 0 && $0.friendUsers.isEmpty })
        #expect(choices.allSatisfy { $0.historyBadge == nil && $0.historyDetail == nil })
    }

    @Test
    func mainVenueIsEasyToFindWithoutElevatorsAndEscalatorsInTheSuggestions() {
        let hotel = rankedOption(name: "Wynn Las Vegas", category: .hotel, meters: 80)
        let restaurant = rankedOption(name: "Wing Lei", category: .restaurant, meters: 20)
        let facilities = ["Elevator 1", "Escalator", "电梯", "扶梯", "Main Entrance"].map {
            rankedOption(name: $0, category: .other, meters: 2)
        }
        let result = MapTalkNearbyPlaceOption.ranked(facilities + [restaurant, hotel])

        #expect(result.first?.id == hotel.id)
        #expect(Set(result.map(\.id)) == Set([hotel.id, restaurant.id]))
    }

    @Test
    func aHotelAcrossTheBlockDoesNotAlwaysBeatTheRestaurantAtYourFeet() {
        let hotel = rankedOption(name: "Unrelated hotel", category: .hotel, meters: 149)
        let restaurant = rankedOption(name: "Here for lunch", category: .restaurant, meters: 5)
        #expect(MapTalkNearbyPlaceOption.ranked([hotel, restaurant]).first?.id == restaurant.id)
    }

    @Test
    func aFrequentlyVisitedRestaurantCanOutrankTheHotelInsteadOfHotelsAlwaysWinning() {
        let hotel = rankedOption(name: "Wynn Las Vegas", category: .hotel, meters: 120)
        let restaurant = rankedOption(name: "Wing Lei", category: .restaurant, meters: 20, ownVisits: 4)

        #expect(MapTalkNearbyPlaceOption.ranked([hotel, restaurant]).map(\.id) == [restaurant.id, hotel.id])
    }

    @Test
    func repeatedVisitsAndDistinctPublicVisitorsMatterAmongComparableVenues() {
        let once = rankedOption(name: "One visit", category: .coffee, meters: 65, ownVisits: 1)
        let regular = rankedOption(name: "Usual coffee", category: .coffee, meters: 70, ownVisits: 4)
        #expect(MapTalkNearbyPlaceOption.ranked([once, regular]).map(\.id) == [regular.id, once.id])

        let oneVisitor = rankedOption(name: "One visitor", category: .restaurant, meters: 65, publicVisitors: 1)
        let severalVisitors = rankedOption(name: "Several visitors", category: .restaurant, meters: 70, publicVisitors: 4)
        #expect(MapTalkNearbyPlaceOption.ranked([oneVisitor, severalVisitors]).map(\.id) == [severalVisitors.id, oneVisitor.id])
    }

    @Test
    func evenOnePersonalVisitPrecedesAnUnvisitedMainVenue() {
        let hotel = rankedOption(name: "Wynn Las Vegas", category: .hotel, meters: 5)
        let visited = rankedOption(name: "Maya's studio", category: .other, meters: 145, ownVisits: 1)

        #expect(MapTalkNearbyPlaceOption.ranked([hotel, visited]).map(\.id) == [visited.id, hotel.id])
    }

    @Test
    func evenOnePublicVisitorPrecedesAnUnvisitedMainVenue() {
        let hotel = rankedOption(name: "New hotel", category: .hotel, meters: 5)
        let visited = rankedOption(name: "Community studio", category: .other, meters: 145, publicVisitors: 1)

        #expect(MapTalkNearbyPlaceOption.ranked([hotel, visited]).map(\.id) == [visited.id, hotel.id])
    }

    @Test
    func personalThenPublicHistoryStayAheadOfEveryUntouchedVenue() {
        let own = rankedOption(name: "My familiar spot", category: .other, meters: 145, ownVisits: 1)
        let publicPlace = rankedOption(name: "Popular hotel", category: .hotel, meters: 5, publicVisitors: 20)
        let untouched = rankedOption(name: "New airport", category: .airport, meters: 1)
        let result = MapTalkNearbyPlaceOption.ranked([untouched, publicPlace, own])

        #expect(result.map(\.id) == [own.id, publicPlace.id, untouched.id])
        #expect(result.map(\.historyPriority) == [0, 1, 2])
    }

    @Test
    func historyCountsKeepRankingBeyondTheOldFourVisitScoreCap() {
        let fiveOwn = rankedOption(name: "Five visits", category: .hotel, meters: 5, ownVisits: 5)
        let eightOwn = rankedOption(name: "Eight visits", category: .other, meters: 145, ownVisits: 8)
        #expect(MapTalkNearbyPlaceOption.ranked([fiveOwn, eightOwn]).map(\.id) == [eightOwn.id, fiveOwn.id])

        let fiveVisitors = rankedOption(name: "Five people", category: .hotel, meters: 5, publicVisitors: 5)
        let twentyVisitors = rankedOption(name: "Twenty people", category: .other, meters: 145, publicVisitors: 20)
        #expect(MapTalkNearbyPlaceOption.ranked([fiveVisitors, twentyVisitors]).map(\.id) == [twentyVisitors.id, fiveVisitors.id])
    }

    @Test
    func exactSearchNameBeatsCloserHistoryAndSubsidiaryNames() {
        let hotel = rankedOption(name: "Wynn Las Vegas", category: .hotel, meters: 450)
        let cafe = rankedOption(name: "Wynn Las Vegas Cafe", category: .coffee, meters: 8,
                               ownVisits: 8, publicVisitors: 12)
        let result = MapTalkNearbyPlaceOption.ranked([cafe, hotel], query: "wynn las vegas")

        #expect(result.map(\.id) == [hotel.id, cafe.id])
        #expect(result.first?.distanceMeters == 450, "Ranking must not move the actual venue coordinate")
    }

    @Test
    func smallGPSDistanceChangesDoNotShuffleEquivalentRows() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let before = [rankedOption(id: secondID, name: "Second", category: .coffee, meters: 63),
                      rankedOption(id: firstID, name: "First", category: .coffee, meters: 67)]
        let after = [rankedOption(id: firstID, name: "First", category: .coffee, meters: 62),
                     rankedOption(id: secondID, name: "Second", category: .coffee, meters: 68)]

        #expect(MapTalkNearbyPlaceOption.ranked(before).map(\.id) == [firstID, secondID])
        #expect(MapTalkNearbyPlaceOption.ranked(after).map(\.id) == [firstID, secondID])
    }

    @Test
    func sameQuerySearchRefreshKeepsVisibleRowsAndOrder() {
        let near = rankedOption(name: "Cafe nearby", category: .coffee, meters: 60)
        let visited = rankedOption(name: "Cafe familiar", category: .coffee, meters: 90, ownVisits: 1)
        let searched = rankedOption(name: "Cafe searched", category: .coffee, meters: 320)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Cafe")
        state.receive(.init(options: [searched, visited, near]), for: "Cafe")
        let before = state.presentedOptions(for: "Cafe", nearbyPlaces: [near, visited], location: location)
        #expect(before.map(\.id) == [visited.id, near.id, searched.id])

        state.prepare(for: "Cafe")
        #expect(state.options.map(\.id) == [searched.id, visited.id, near.id])
        let refreshing = state.presentedOptions(for: "Cafe", nearbyPlaces: [visited, near], location: location)
        #expect(refreshing.map(\.id) == before.map(\.id), "Local input reordering must not blank or shuffle a same-query search")
    }

    @Test
    func differentSearchQueryImmediatelyHidesOldRowsBeforePreparing() {
        let previous = rankedOption(name: "Wynn", category: .hotel, meters: 250)
        let local = rankedOption(name: "Venetian", category: .hotel, meters: 80)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Wynn")
        state.receive(.init(options: [previous], issue: .temporarilyUnavailable), for: "Wynn")

        #expect(state.presentedOptions(for: "Venetian", nearbyPlaces: [], location: location).isEmpty)
        #expect(state.presentedOptions(for: "Venetian", nearbyPlaces: [local], location: location).map(\.id) == [local.id])
        #expect(state.query == "Wynn", "Presentation must hide stale rows before the replacement task prepares")
        state.prepare(for: "Venetian")
        #expect(state.query == "Venetian")
        #expect(state.options.isEmpty)
        #expect(state.issue == nil)
    }

    @Test
    func searchRefreshFailureRetainsRowsButSuccessfulEmptyResponseClearsThem() {
        let option = rankedOption(name: "Wynn", category: .hotel, meters: 250)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Wynn")
        state.receive(.init(options: [option]), for: "Wynn")
        state.prepare(for: "Wynn")
        state.receive(.init(options: [], issue: .temporarilyUnavailable), for: "Wynn")
        #expect(state.issue == .temporarilyUnavailable)
        #expect(state.options.map(\.id) == [option.id])
        #expect(state.presentedOptions(for: "Wynn", nearbyPlaces: [], location: location).map(\.id) == [option.id])

        state.prepare(for: "Wynn")
        #expect(state.options.map(\.id) == [option.id])
        state.receive(.init(options: []), for: "Wynn")
        #expect(state.issue == nil)
        #expect(state.options.isEmpty)
        #expect(state.presentedOptions(for: "Wynn", nearbyPlaces: [], location: location).isEmpty)
    }

    @Test
    func lateDifferentQuerySearchResponsesCannotReplaceCurrentRowsOrIssue() {
        let previous = rankedOption(name: "Wynn", category: .hotel, meters: 250)
        let current = rankedOption(name: "Venetian", category: .hotel, meters: 80)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Wynn")
        state.prepare(for: "Venetian")
        state.receive(.init(options: [previous], issue: .temporarilyUnavailable), for: "Wynn")
        #expect(state.query == "Venetian")
        #expect(state.options.isEmpty)
        #expect(state.issue == nil)
        state.receive(.init(options: [current]), for: "Venetian")
        state.receive(.init(options: [previous], issue: .temporarilyUnavailable), for: "Wynn")
        #expect(state.options.map(\.id) == [current.id])
        #expect(state.issue == nil)
    }

    @Test
    func retainedSearchAndNearbyRowsAreHiddenWithoutCurrentGPS() {
        let option = rankedOption(name: "Wynn", category: .hotel, meters: 80)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Wynn")
        state.receive(.init(options: [option]), for: "Wynn")
        #expect(state.presentedOptions(for: "Wynn", nearbyPlaces: [option], location: nil).isEmpty)
        #expect(state.presentedOptions(for: "", nearbyPlaces: [option], location: nil).isEmpty)
    }

    @Test
    func retainedSearchRowsRevalidateCurrentGPS500AndUpdateDistances() throws {
        let near = rankedOption(name: "Cafe nearby", category: .coffee, meters: 80)
        let edge = rankedOption(name: "Cafe edge", category: .coffee, meters: 499)
        let outside = rankedOption(name: "Cafe outside", category: .coffee, meters: 501)
        let initialLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Cafe")
        state.receive(.init(options: [outside, edge, near]), for: "Cafe")
        #expect(Set(state.presentedOptions(for: "Cafe", nearbyPlaces: [], location: initialLocation).map(\.id)) == Set([near.id, edge.id]))

        let moved = coordinate(metersNorth: -100)
        let currentLocation = CLLocation(latitude: moved.latitude, longitude: moved.longitude)
        let current = state.presentedOptions(for: "Cafe", nearbyPlaces: [], location: currentLocation)
        #expect(current.map(\.id) == [near.id], "Retaining a same-query response cannot retain old 500 m eligibility")
        let measured = try #require(current.first)
        let expectedDistance = POISelectionPolicy.distance(from: moved, to: near.place.poi.coordinate)
        #expect(abs(measured.distanceMeters - expectedDistance) < 0.001)
        #expect(measured.distanceMeters > 150 && measured.distanceMeters < 200)
        #expect(measured.place.poi.coordinate.latitude == near.place.poi.coordinate.latitude)
    }

    @Test
    func emptySearchQueryUsesOnlyCurrentGPS150Recommendations() {
        let inside = rankedOption(name: "Cafe inside", category: .coffee, meters: 149)
        let outside = rankedOption(name: "Cafe outside", category: .coffee, meters: 151)
        let searched = rankedOption(name: "Cafe searched", category: .coffee, meters: 300)
        let initialLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Cafe")
        state.receive(.init(options: [searched]), for: "Cafe")
        #expect(state.presentedOptions(for: "", nearbyPlaces: [outside, inside], location: initialLocation).map(\.id) == [inside.id])

        let moved = coordinate(metersNorth: 20)
        let currentLocation = CLLocation(latitude: moved.latitude, longitude: moved.longitude)
        #expect(Set(state.presentedOptions(for: "", nearbyPlaces: [outside, inside], location: currentLocation).map(\.id)) == Set([inside.id, outside.id]))
    }

    @Test
    func historicalRecommendationsRevalidateCurrentGPS500AndDisappearWithoutGPS() throws {
        let visited = rankedOption(name: "Old familiar venue", category: .coffee, meters: 490, ownVisits: 1)
        let distantVisit = rankedOption(name: "Distant familiar venue", category: .coffee, meters: 550, ownVisits: 1)
        let publicOnly = rankedOption(name: "Other people's venue", category: .coffee, meters: 300, publicVisitors: 5)
        let fresh = rankedOption(name: "New nearby venue", category: .coffee, meters: 100)
        let initialLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let state = MapTalkNearbyPlaceSearchState()
        let candidates = [fresh, publicOnly, visited, distantVisit]

        let initial = state.presentedOptions(for: "", nearbyPlaces: candidates, location: initialLocation)
        #expect(initial.map(\.id) == [visited.id, fresh.id])
        let history = try #require(initial.first)
        #expect(abs(history.distanceMeters - POISelectionPolicy.distance(from: origin, to: visited.place.poi.coordinate)) < 0.001)

        let moved = coordinate(metersNorth: -20)
        let currentLocation = CLLocation(latitude: moved.latitude, longitude: moved.longitude)
        let current = state.presentedOptions(for: "", nearbyPlaces: candidates, location: currentLocation)
        #expect(current.map(\.id) == [fresh.id],
                "Retained personal history must lose eligibility once current GPS is over 500 m away")
        #expect(state.presentedOptions(for: "", nearbyPlaces: candidates, location: nil).isEmpty)
    }

    @Test
    func searchPresentationUsesLatestLocalMetadataAndHistoryWithoutDuplicates() throws {
        let id = UUID()
        let stale = rankedOption(id: id, name: "Wynn", category: .other, meters: 90)
        let latest = rankedOption(id: id, name: "Wynn Resort", category: .hotel, meters: 80,
                                  ownVisits: 3, publicVisitors: 4)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var state = MapTalkNearbyPlaceSearchState()
        state.prepare(for: "Wynn")
        state.receive(.init(options: [stale, stale]), for: "Wynn")
        let result = state.presentedOptions(for: "Wynn", nearbyPlaces: [latest], location: location)
        #expect(result.map(\.id) == [id])
        let refreshed = try #require(result.first)
        #expect(refreshed.place.poi.name == latest.place.poi.name)
        #expect(refreshed.place.poi.category == .hotel)
        #expect(refreshed.isInMyMap)
        #expect(refreshed.publicVisitorCount == 4)
        #expect(refreshed.ownCheckIns.map(\.id) == latest.ownCheckIns.map(\.id))
        #expect(abs(refreshed.distanceMeters - POISelectionPolicy.distance(from: origin, to: latest.place.poi.coordinate)) < 0.001)

        // The directory may match an older name; even then, its cached metadata
        // must not overwrite the live canonical choice or its personal history.
        let renamed = rankedOption(id: id, name: "Updated Resort", category: .hotel, meters: 80, ownVisits: 5)
        let aliasResult = state.presentedOptions(for: "Wynn", nearbyPlaces: [renamed], location: location)
        #expect(aliasResult.map(\.id) == [id])
        #expect(aliasResult.first?.place.poi.name == "Updated Resort")
        #expect(aliasResult.first?.ownCheckIns.count == 5)
    }

    @Test
    func unknownVenuesAndBusinessesWithFacilityWordsAreNotBlanketRemoved() {
        let venues = [rankedOption(name: "Maya's studio", category: .other, meters: 20),
                      rankedOption(name: "The Elevator Cafe", category: .coffee, meters: 30),
                      rankedOption(name: "The Entrance", category: .other, meters: 40)]
        #expect(Set(MapTalkNearbyPlaceOption.ranked(venues).map(\.id)) == Set(venues.map(\.id)))
    }

    @Test(.timeLimit(.minutes(1)))
    func hidingSupportingFacilitiesDoesNotDeleteTheirExistingPrivateHistory() async throws {
        let archive = MyMapArchiveStore(startsEmpty: true)
        var elevator = place(metersNorth: 10, name: "Elevator 1")
        let visit = RatedPOI.CheckIn(userId: archive.currentUserID, createdAt: .now)
        elevator.checkIns = [visit]
        archive.savePOI(elevator, publicVersion: nil, audience: .privateMyMap)
        let directory = NearbyTestRepository([elevator])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: archive))
        try await waitForDirectory(model, searches: 1, repository: directory)

        #expect(model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude)).isEmpty)
        let saved = try #require(archive.privatePOIs.first { $0.id == elevator.id })
        #expect(saved.poi.name == elevator.poi.name)
        #expect(saved.checkIns.map(\.id) == [visit.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func canonicalDirectoryAndArchivedAliasKeepOneRowAndDistinctOwnVisits() async throws {
        let user = BackendUser(id: UUID(), handle: "history_alias_test")
        let apple = place(metersNorth: 100)
        let canonicalID = UUID()
        let serverPlace = BackendPlace(id: canonicalID, sourceId: apple.id,
            name: apple.poi.name, category: "other",
            coordinate: .init(latitude: apple.poi.coordinate.latitude, longitude: apple.poi.coordinate.longitude))
        let oldDate = Date.now.addingTimeInterval(-30 * 86_400)
        let memory = BackendMemory(id: UUID(), ownerId: user.id, owner: user, kind: "poi", visibility: "private",
            location: serverPlace.coordinate, caption: "", place: serverPlace, media: [],
            createdAt: oldDate, publishedAt: nil, expiresAt: oldDate.addingTimeInterval(72 * 3_600))
        let api = BackendAPI(baseURL: URL(string: "https://example.test")!)
        var state = BackendLocalState(ownerID: user.id, server: api.baseURL.absoluteString, user: user)
        state.mine = [memory]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendLocalStateDisk(directory: path)
        defer { disk.invalidate() }
        try await disk.save(state, revision: 1)
        let store = BackendStore(user: user.user, api: api, storageDirectory: path,
            automaticallySync: false, observesConnectivity: false)
        defer { store.clearLocalMedia() }
        #expect(await store.restoreCachedState())
        var alias = apple
        let newest = RatedPOI.CheckIn(userId: user.id, createdAt: oldDate.addingTimeInterval(86_400))
        let archived = try #require(store.archive.privatePOIs.first)
        alias.checkIns = archived.checkIns + [newest]
        store.archive.savePOI(alias, publicVersion: nil, audience: .privateMyMap)
        let directory = NearbyTestRepository([apple, apple])
        let empty = NearbyTestRepository([])
        let model = MapTalkViewModel(environment: AppEnvironment(
            build: .init(configuration: .debug, featureFlags: []), location: NearbyTestLocation(origin),
            notifications: NotificationServiceImpl(), activePOIRepo: empty, poiRepo: empty,
            nearbyPOIRepo: directory, realRepo: NearbyTestReelRepository(), myMapArchive: store.archive, backend: store))
        try await waitForDirectory(model, searches: 1, repository: directory)
        let choices = model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
            matching: [apple])

        #expect(choices.map(\.id) == [canonicalID])
        let result = try #require(choices.first)
        #expect(result.isPublicDirectoryPlace && result.isInMyMap)
        #expect(result.ownCheckIns.map(\.id) == [newest.id, memory.id])
        #expect(result.publicVisitorCount == 0)
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
    func appleMetadataCannotWidenCurrentGPSSelectionForLegacyOrNewPlaces() async throws {
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
        #expect(choices.isEmpty)
        #expect(model.nearbyPlaceOptions(near: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
            withinMeters: POISelectionPolicy.searchRadius).isEmpty)
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

    private func rankedOption(id: UUID = UUID(), name: String, category: POICategory,
                              meters: Double, ownVisits: Int = 0,
                              publicVisitors: Int = 0) -> MapTalkNearbyPlaceOption {
        let ownerID = UUID()
        let visits = (0..<ownVisits).map {
            RatedPOI.CheckIn(userId: ownerID, createdAt: Date(timeIntervalSince1970: 1_790_000_000 - Double($0) * 86_400))
        }
        let rated = RatedPOI(poi: .init(id: id, name: name, coordinate: coordinate(metersNorth: meters), category: category),
            highlight: nil, secondary: nil, media: [], checkIns: visits, comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
        return .init(place: rated, distanceMeters: meters, isPublicDirectoryPlace: true,
                     isInMyMap: ownVisits > 0, friendUsers: [], publicVisitorCount: publicVisitors,
                     ownCheckIns: visits)
    }

    private func place(metersNorth: Double, kind: POIDirectoryKind? = nil, name: String = "Directory place") -> RatedPOI {
        .init(poi: .init(id: UUID(), name: name, coordinate: coordinate(metersNorth: metersNorth),
                        category: kind == .airport ? .airport : .other, directoryKind: kind),
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

import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct PostLocationChoiceTests {
    private let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let origin = CLLocation(latitude: 37.3688, longitude: -122.0363)

    @Test
    func customNameSurvivesHistoryReuseWithoutInventingAPlace() throws {
        var custom = post(at: point(north: 240))
        custom.locationName = "Our sunset spot"
        custom.locationID = UUID()
        let choices = MapTalkPostLocations.choices(near: origin,
            ownPosts: [custom], places: [], currentUserID: ownerID)
        let chosen = try #require(choices.first)
        #expect(chosen.selection.title == "Our sunset spot")
        #expect(chosen.selection.locationName == "Our sunset spot")
        #expect(chosen.selection.locationID == custom.locationID)
        #expect(chosen.selection.coordinate.latitude == custom.center.latitude)
        #expect(chosen.category == nil)
        let unnamed = try #require(MapTalkPostLocations.choices(near: origin,
            ownPosts: [post(at: origin.coordinate)], places: [], currentUserID: ownerID).first)
        #expect(unnamed.selection.locationName == nil)
    }

    @Test
    func customNamesUseTheSameUTF16LimitAsTheServer() {
        #expect(PostLocationPolicy.normalizedName("  Sunset  ") == "Sunset")
        #expect(PostLocationPolicy.normalizedName(" \n ") == nil)
        #expect(PostLocationPolicy.normalizedName("One\nTwo") == nil)
        #expect(PostLocationPolicy.normalizedName(String(repeating: "📍", count: 40)) != nil)
        #expect(PostLocationPolicy.normalizedName(String(repeating: "📍", count: 41)) == nil)
    }

    @Test
    func customLocationMetadataRoundTripsWithoutChangingLegacyWireInput() throws {
        var input = BackendMemoryInput(id: UUID(), kind: "reel", visibility: "private",
            location: .init(latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude))
        let legacyBytes = try JSONEncoder().encode(input)
        let legacy = try #require(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        #expect(legacy["locationName"] == nil)
        #expect(legacy["locationId"] == nil)
        #expect(try JSONDecoder().decode(BackendMemoryInput.self, from: legacyBytes).locationId == nil)
        let legacyFingerprint = BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: [])
        input.locationName = "Our sunset spot"
        let restored = try JSONDecoder().decode(BackendMemoryInput.self, from: JSONEncoder().encode(input))
        #expect(restored.locationName == input.locationName)
        #expect(restored.location.latitude == input.location.latitude)
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) != legacyFingerprint)
        input.locationName = nil
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) == legacyFingerprint)
        input.locationId = UUID()
        let withIdentity = try JSONDecoder().decode(BackendMemoryInput.self, from: JSONEncoder().encode(input))
        #expect(withIdentity.locationId == input.locationId)
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) != legacyFingerprint)
        input.locationId = nil
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) == legacyFingerprint)
    }

    @Test
    func explicitIdentitiesStaySeparateEvenAtTheSameNamedCoordinate() throws {
        var first = post(at: origin.coordinate, date: 10)
        first.locationID = UUID()
        first.locationName = "Same label"
        var second = post(at: origin.coordinate, date: 20)
        second.locationID = UUID()
        second.locationName = "Same label"
        var later = post(at: point(north: 1), date: 30)
        later.locationID = first.locationID
        later.locationName = "Same label"
        let choices = MapTalkPostLocations.choices(near: origin, ownPosts: [first, second, later],
            places: [], currentUserID: ownerID)
        #expect(choices.count == 2)
        let reused = try #require(choices.first { $0.selection.locationID == first.locationID })
        #expect(reused.previousPosts.map(\.id) == [later.id, first.id])
        #expect(reused.selection.coordinate.latitude == later.center.latitude)
        #expect(choices.first { $0.selection.locationID == second.locationID }?.postCount == 1)
    }

    @Test
    func directoryCanonicalizationCannotChangePostIdentityOrSupplyItsName() throws {
        let sourceID = UUID()
        let venue = place(at: origin.coordinate)
        var previous = post(at: point(north: 1))
        previous.locationID = sourceID
        let selected = try #require(MapTalkPostLocations.choices(near: origin, ownPosts: [previous],
            places: [venue], currentUserID: ownerID,
            resolvePlaceIdentity: { $0 == venue.id ? sourceID : $0 }).first)
        #expect(selected.selection.locationID == sourceID)
        #expect(selected.previousPosts.map(\.id) == [previous.id])
        #expect(!selected.isPOI)
        #expect(selected.placeOption == nil)
        #expect(selected.selection.title == "Previous post location")
    }

    @Test
    func legacyHistorySeedsAReusableIdentityWithoutRewritingOldPosts() throws {
        let legacy = post(at: origin.coordinate)
        let choice = try #require(MapTalkPostLocations.choices(near: origin, ownPosts: [legacy],
            places: [], currentUserID: ownerID).first)
        #expect(choice.selection.locationID == legacy.id)
        var later = post(at: origin.coordinate, date: 20)
        later.locationID = choice.selection.locationID
        let reused = MapTalkPostLocations.choices(near: origin, ownPosts: [legacy, later],
            places: [], currentUserID: ownerID)
        #expect(reused.count == 1)
        #expect(reused.first?.postCount == 2)
        #expect(legacy.locationID == nil)
    }

    @Test
    func historyOnlyCountsOwnDistinctPostsAndKeepsNewestFirst() throws {
        let coordinate = point(north: 800)
        let older = post(at: coordinate, date: 10)
        let latest = post(at: coordinate, date: 20)
        let someoneElse = post(at: coordinate, owner: otherID, date: 30)
        let venue = place(at: coordinate, publicVisitors: 400)
        let choices = MapTalkPostLocations.choices(near: origin,
            ownPosts: [older, latest, latest, someoneElse], places: [venue, venue], currentUserID: ownerID)
        let result = try #require(choices.first)
        #expect(choices.count == 1)
        #expect(result.postCount == 2)
        #expect(result.previousPosts.map(\.id) == [latest.id, older.id])
        #expect(!result.isPOI)
        #expect(result.selection.title == "Previous post location")
        #expect(result.placeOption == nil)
    }

    @Test
    func globalHistoryIsRecentFirstAndStableAcrossSourceOrder() {
        let far = post(at: point(north: 3_000), date: 40)
        let near = post(at: point(north: 500), date: 20)
        let closestVenue = place(at: point(north: 5))
        let anotherVenue = place(at: point(north: 10))
        let forward = MapTalkPostLocations.choices(near: origin, ownPosts: [far, near],
            places: [closestVenue, anotherVenue], currentUserID: ownerID)
        let reverse = MapTalkPostLocations.choices(near: origin, ownPosts: [near, far],
            places: [anotherVenue, closestVenue], currentUserID: ownerID)
        #expect(forward.map(\.id) == reverse.map(\.id))
        #expect(forward.map { $0.previousPosts.first?.id } == [far.id, near.id])
        #expect(forward.allSatisfy { !$0.isPOI && $0.placeOption == nil })
    }

    @Test
    func POIVisitsAndDirectoryPlacesNeverBecomePostHistoryRows() {
        let oldVisit = RatedPOI.CheckIn(userId: ownerID, createdAt: .now.addingTimeInterval(-30 * 86_400))
        let visited = place(at: point(north: 1_000), name: "A familiar cafe", ownCheckIns: [oldVisit])
        let publicHistory = place(at: point(north: 100), publicVisitors: 4)
        let unused = place(at: point(north: 5))
        let forward = MapTalkPostLocations.choices(near: origin, ownPosts: [],
            places: [unused, publicHistory, visited, visited], currentUserID: ownerID)
        let reverse = MapTalkPostLocations.choices(near: origin, ownPosts: [],
            places: [visited, publicHistory, unused], currentUserID: ownerID)

        #expect(forward.map(\.id) == reverse.map(\.id))
        #expect(forward.isEmpty)
    }

    @Test
    func POIActivityCannotRenameOrChangePostHistoryActivity() throws {
        let coordinate = point(north: 300)
        let olderPost = post(at: coordinate, date: 10)
        let newerVisit = RatedPOI.CheckIn(userId: ownerID,
            createdAt: Date(timeIntervalSince1970: 20), publishedAt: Date(timeIntervalSince1970: 30))
        let venue = place(at: coordinate, ownCheckIns: [newerVisit])
        let outOfRange = place(at: point(north: 5_000.1), ownCheckIns: [newerVisit])
        let choices = MapTalkPostLocations.choices(near: origin, ownPosts: [olderPost],
            places: [outOfRange, venue], currentUserID: ownerID)

        #expect(choices.count == 1)
        let result = try #require(choices.first)
        #expect(result.postCount == 1 && result.ownCheckInCount == 0)
        #expect(result.lastOwnActivityAt == olderPost.activityDate)
        #expect(result.historyBadge == "Posted here")
        #expect(result.historyDetail?.hasPrefix("You · 1 post · Last ") == true)
        #expect(result.selection.coordinate.latitude == coordinate.latitude)
        #expect(result.selection.coordinate.longitude == coordinate.longitude)
        let newerPost = post(at: coordinate, date: 40)
        let updated = try #require(MapTalkPostLocations.choices(near: origin, ownPosts: [olderPost, newerPost],
            places: [venue], currentUserID: ownerID).first)
        #expect(updated.lastOwnActivityAt == newerPost.activityDate)
    }

    @Test
    func nearbyDistinctVenuesNeverAbsorbHistoryThroughProximity() {
        let history = post(at: point(north: 100))
        let first = place(at: point(north: 95), name: "Cafe")
        let second = place(at: point(north: 105), name: "Hotel")
        let choices = MapTalkPostLocations.choices(near: origin, ownPosts: [history],
            places: [first, second], currentUserID: ownerID)
        #expect(choices.count == 1)
        #expect(choices.first?.selection.title == "Previous post location")
        #expect(choices.first?.isPOI == false)
        #expect(choices.filter(\.isPOI).allSatisfy { $0.previousPosts.isEmpty })
    }

    @Test
    func evenExactlyMatchingPOIsCannotBecomePostChoices() {
        let coordinate = point(north: 100)
        let history = post(at: coordinate)
        let first = place(at: coordinate, name: "Cafe")
        let second = place(at: coordinate, name: "Hotel")
        let unique = MapTalkPostLocations.choices(near: origin, ownPosts: [history],
            places: [first], currentUserID: ownerID)
        #expect(unique.count == 1)
        #expect(unique.first?.isPOI == false)
        #expect(unique.first?.postCount == 1)

        let ambiguous = MapTalkPostLocations.choices(near: origin, ownPosts: [history],
            places: [first, second], currentUserID: ownerID)
        #expect(ambiguous.count == 1)
        #expect(ambiguous.first?.isPOI == false)
        #expect(ambiguous.filter(\.isPOI).allSatisfy { $0.postCount == 0 })
    }

    @Test
    func stableCoordinateGroupingPreservesOriginalSelectedPoint() throws {
        let oldCoordinate = CLLocationCoordinate2D(latitude: 37.36880011, longitude: -122.03630011)
        let newCoordinate = CLLocationCoordinate2D(latitude: 37.36880012, longitude: -122.03630012)
        let choices = MapTalkPostLocations.choices(near: origin,
            ownPosts: [post(at: oldCoordinate, date: 10), post(at: newCoordinate, date: 20)],
            places: [], currentUserID: ownerID)
        let selected = try #require(choices.first)
        #expect(choices.count == 1)
        #expect(selected.postCount == 2)
        #expect(selected.selection.coordinate.latitude == newCoordinate.latitude)
        #expect(selected.selection.coordinate.longitude == newCoordinate.longitude)
        let location = try #require(PostLocationPolicy.location(for: selected.selection, near: origin))
        #expect(location.coordinate.latitude == newCoordinate.latitude)
        #expect(location.coordinate.longitude == newCoordinate.longitude)
        // Even an identical POI coordinate cannot supply a history label.
        let venue = place(at: oldCoordinate)
        let withVenue = MapTalkPostLocations.choices(near: origin,
            ownPosts: [post(at: newCoordinate)], places: [venue], currentUserID: ownerID)
        #expect(withVenue.count == 1)
        #expect(withVenue.first?.isPOI == false)
        #expect(withVenue.first?.selection.title == "Previous post location")
    }

    @Test
    func fiveKilometreBoundaryIsRecheckedAgainstCurrentOrigin() {
        #expect(PostLocationPolicy.radius == 5_000)
        let inside = MapTalkPostLocationSelection(coordinate: point(north: 4_999.9), title: "Inside")
        let outside = MapTalkPostLocationSelection(coordinate: point(north: 5_000.1), title: "Outside")
        #expect(PostLocationPolicy.location(for: inside, near: origin) != nil)
        #expect(PostLocationPolicy.location(for: outside, near: origin) == nil)
        let moved = CLLocation(latitude: origin.coordinate.latitude - 0.02, longitude: origin.coordinate.longitude)
        #expect(PostLocationPolicy.location(for: inside, near: moved) == nil)
        let choices = MapTalkPostLocations.choices(near: origin,
            ownPosts: [post(at: outside.coordinate)], places: [place(at: outside.coordinate)], currentUserID: ownerID)
        #expect(choices.count == 1)
    }

    @Test
    func invalidCoordinatesAreRejectedBeforeDistanceOrIdentityConversion() {
        let invalid = [
            CLLocationCoordinate2D(latitude: .nan, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 91, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 181)
        ]
        for coordinate in invalid {
            #expect(PostLocationPolicy.location(for: .init(coordinate: coordinate, title: "Invalid"), near: origin) == nil)
            #expect(MapTalkPostLocations.choices(near: origin, ownPosts: [post(at: coordinate)],
                places: [place(at: coordinate)], currentUserID: ownerID).isEmpty)
        }
        let badOrigin = CLLocation(latitude: .nan, longitude: 0)
        #expect(MapTalkPostLocations.choices(near: badOrigin, ownPosts: [post(at: origin.coordinate)],
            places: [], currentUserID: ownerID).count == 1)
    }

    @Test
    func thumbnailSkipsUnrenderableVideoAndUsesOwnedMediaOnly() throws {
        let poster = URL(string: "https://example.test/poster.jpg")!
        let video = URL(string: "https://example.test/video.mp4")!
        let own = post(at: origin.coordinate, attachments: [.init(kind: .video(url: video, poster: nil))])
        let older = post(at: origin.coordinate, date: 0, attachments: [.init(kind: .video(url: video, poster: poster))])
        let foreign = post(at: origin.coordinate, owner: otherID, date: 100,
                           attachments: [.init(kind: .photo(URL(string: "https://example.test/foreign.jpg")!))])
        let choice = try #require(MapTalkPostLocations.choices(near: origin, ownPosts: [own, older, foreign],
            places: [], currentUserID: ownerID).first)
        #expect(choice.thumbnailURL == poster)
    }

    @Test
    func allOwnedVisibilitiesAreAvailableWorldwideWithoutExpiryOrGPS() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
            CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        ]
        let visibilities: [RealPost.Visibility] = [.privateOnly, .publicAll, .friendsOnly, .anonymous]
        let posts = zip(coordinates, visibilities).enumerated().map { index, pair in
            var value = post(at: pair.0, date: Double(index))
            value.visibility = pair.1
            value.expiresAt = .distantPast
            value.locationName = "Memory \(index)"
            return value
        }
        let library = MapTalkPostLocationLibrary(ownPosts: posts, visitedPlaces: [], currentUserID: ownerID)
        #expect(library.choices.count == 4)
        #expect(library.choices.map(\.selection.title) == ["Memory 3", "Memory 2", "Memory 1", "Memory 0"])
        for choice in library.choices {
            let reused = try #require(library.location(for: choice.selection, currentLocation: nil))
            #expect(reused.coordinate.latitude == choice.selection.coordinate.latitude)
            #expect(reused.coordinate.longitude == choice.selection.coordinate.longitude)
            #expect(library.location(for: choice.selection, currentLocation: origin) != nil)
        }
        #expect(library.choices(matching: "  mEmOrY 1 ").count == 1)
        #expect(library.choices(matching: "Unknown").isEmpty)
        #expect(library.coverage.areas.isEmpty)
    }

    @Test
    func historicalReuseRequiresOriginalIdentityCoordinateAndName() throws {
        var original = post(at: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129))
        original.locationName = "Grand Canyon"
        original.locationID = UUID()
        let library = MapTalkPostLocationLibrary(ownPosts: [original], visitedPlaces: [], currentUserID: ownerID)
        let selection = try #require(library.choices.first?.selection)
        #expect(library.location(for: selection, currentLocation: nil) != nil)
        var wrongIdentity = selection
        wrongIdentity.locationID = UUID()
        #expect(library.location(for: wrongIdentity, currentLocation: nil) == nil)
        var renamed = selection
        renamed.locationName = "Different place"
        let atOriginal = CLLocation(latitude: original.center.latitude, longitude: original.center.longitude)
        #expect(library.location(for: renamed, currentLocation: atOriginal) == nil)
        let moved = MapTalkPostLocationSelection(coordinate: origin.coordinate, title: selection.title,
            locationName: selection.locationName, locationID: selection.locationID)
        #expect(library.location(for: moved, currentLocation: origin) == nil)
        renamed.locationID = UUID()
        #expect(library.location(for: renamed, currentLocation: atOriginal) != nil)
    }

    @Test
    func remotePostHistoryDoesNotCreateAnExpandableNewLocationArea() throws {
        let remote = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let library = MapTalkPostLocationLibrary(ownPosts: [post(at: remote)], visitedPlaces: [], currentUserID: ownerID)
        let history = try #require(library.choices.first?.selection)
        #expect(library.location(for: history, currentLocation: nil) != nil)
        let new = MapTalkPostLocationSelection(coordinate: remote, title: "New", locationName: "New", locationID: UUID())
        #expect(library.location(for: new, currentLocation: nil) == nil)
        #expect(library.location(for: new, currentLocation: origin) == nil)
    }

    @Test
    func onlyOwnedPOICheckInsUnlockLandmarkAreasWithoutExpiry() throws {
        let remote = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let veryOld = RatedPOI.CheckIn(userId: ownerID, createdAt: .distantPast)
        let visited = ratedPlace(at: remote, checkIns: [veryOld])
        var savedOnly = ratedPlace(at: origin.coordinate, checkIns: [])
        savedOnly.isFavoritedByCurrentUser = true
        let friend = ratedPlace(at: point(north: 30_000), checkIns: [.init(userId: otherID)])
        let library = MapTalkPostLocationLibrary(ownPosts: [], visitedPlaces: [visited, savedOnly, friend, visited],
                                                currentUserID: ownerID)
        #expect(library.choices.isEmpty)
        #expect(library.coverage.areas.map(\.id) == [visited.id])
        #expect(library.coverage.contains(remote, currentLocation: nil))
        #expect(!library.coverage.contains(origin.coordinate, currentLocation: nil))
        #expect(!library.coverage.contains(friend.poi.coordinate, currentLocation: nil))
        let new = MapTalkPostLocationSelection(coordinate: remote, title: "Lookout", locationName: "Lookout", locationID: UUID())
        #expect(library.location(for: new, currentLocation: nil) != nil)
        #expect(library.location(for: .init(coordinate: remote, title: "Fallback"), currentLocation: nil) == nil)
    }

    @Test
    func currentGPSAndEveryOwnedVisitUseTheSameExactFiveKilometreBoundary() {
        let coverage = MapTalkPostLocationLibrary(ownPosts: [],
            visitedPlaces: [ratedPlace(at: origin.coordinate, checkIns: [.init(userId: ownerID)])],
            currentUserID: ownerID).coverage
        #expect(coverage.contains(point(north: 4_999.9), currentLocation: nil))
        #expect(!coverage.contains(point(north: 5_000.1), currentLocation: nil))
        #expect(MapTalkPostLocationLibrary.empty.coverage.contains(point(north: 4_999.9), currentLocation: origin))
        #expect(!MapTalkPostLocationLibrary.empty.coverage.contains(point(north: 5_000.1), currentLocation: origin))
        let moved = CLLocation(latitude: 51.5074, longitude: -0.1278)
        #expect(coverage.contains(moved.coordinate, currentLocation: moved))
        #expect(coverage.contains(origin.coordinate, currentLocation: moved))
        #expect(coverage.contains(origin.coordinate, currentLocation: CLLocation(latitude: .nan, longitude: 0)))
        #expect(!coverage.contains(.init(latitude: .nan, longitude: 0), currentLocation: origin))
    }

    @Test
    func spatialIndexCrossesDateLineAndPolesWithoutGrantingDistantAreas() {
        let dateLine = ratedPlace(at: .init(latitude: 0, longitude: 179.99), checkIns: [.init(userId: ownerID)])
        let pole = ratedPlace(at: .init(latitude: 89.99, longitude: 0), checkIns: [.init(userId: ownerID)])
        let coverage = MapTalkPostLocationLibrary(ownPosts: [], visitedPlaces: [dateLine, pole], currentUserID: ownerID).coverage
        #expect(coverage.contains(.init(latitude: 0, longitude: -179.99), currentLocation: nil))
        #expect(coverage.contains(.init(latitude: 89.99, longitude: 180), currentLocation: nil))
        #expect(!coverage.contains(.init(latitude: 0, longitude: -179.9), currentLocation: nil))
        #expect(!coverage.contains(.init(latitude: 89.9, longitude: 180), currentLocation: nil))
        #expect(coverage.areas(near: .init(latitude: 0, longitude: -179.99), within: 5_000).map(\.id) == [dateLine.id])
        #expect(coverage.areas(near: .init(latitude: 90, longitude: 0), within: 5_000).map(\.id) == [pole.id])
    }

    @Test
    func cacheIgnoresUnrelatedChangesButInvalidatesDeletedHistoryAndRevokedVisits() throws {
        var own = post(at: origin.coordinate)
        var visited = ratedPlace(at: origin.coordinate, checkIns: [.init(userId: ownerID)])
        var cache = MapTalkPostLocationCache()
        let initialized = cache.update(ownPosts: [own], visitedPlaces: [visited], currentUserID: ownerID)
        #expect(initialized)
        let initialRevision = cache.library.revision
        let areaRevision = cache.library.coverage.revision
        let oldSelection = try #require(cache.library.choices.first?.selection)
        own.likes = [otherID]
        own.comments = [.init(userId: otherID, text: "Nice")]
        visited.checkIns[0].comment = "Updated feedback"
        visited.media = [.init(kind: .photo(URL(string: "https://example.test/visit.jpg")!))]
        let unrelatedChanged = cache.update(ownPosts: [own, own], visitedPlaces: [visited, visited], currentUserID: ownerID)
        #expect(!unrelatedChanged)
        #expect(cache.library.revision == initialRevision)
        #expect(cache.library.coverage.revision == areaRevision)
        own.message = "New snippet"
        let snippetChanged = cache.update(ownPosts: [own], visitedPlaces: [visited], currentUserID: ownerID)
        #expect(snippetChanged)
        #expect(cache.library.revision != initialRevision)
        #expect(cache.library.coverage.revision == areaRevision)
        let deletedPost = cache.update(ownPosts: [], visitedPlaces: [visited], currentUserID: ownerID)
        #expect(deletedPost)
        #expect(cache.library.choices.isEmpty)
        #expect(cache.library.location(for: oldSelection, currentLocation: nil) == nil)
        visited.checkIns = [.init(userId: otherID)]
        let revokedVisit = cache.update(ownPosts: [], visitedPlaces: [visited], currentUserID: ownerID)
        #expect(revokedVisit)
        #expect(cache.library.coverage.revision != areaRevision)
        #expect(!cache.library.coverage.contains(origin.coordinate, currentLocation: nil))
    }

    @Test
    func cacheOnlyRebuildsForDisplayedMediaAndNeverLeaksPreviousOwner() throws {
        let video = URL(string: "https://example.test/video.mp4")!
        let poster = URL(string: "https://example.test/poster.jpg")!
        var own = post(at: origin.coordinate, attachments: [.init(kind: .video(url: video, poster: nil))])
        var cache = MapTalkPostLocationCache()
        let initialized = cache.update(ownPosts: [own], visitedPlaces: [], currentUserID: ownerID)
        #expect(initialized)
        own.attachments[0].videoMetadata = .init(width: 1920, height: 1080, duration: 3)
        let videoMetadataChanged = cache.update(ownPosts: [own], visitedPlaces: [], currentUserID: ownerID)
        #expect(!videoMetadataChanged)
        own.attachments[0].kind = .video(url: video, poster: poster)
        let thumbnailChanged = cache.update(ownPosts: [own], visitedPlaces: [], currentUserID: ownerID)
        #expect(thumbnailChanged)
        #expect(cache.library.choices.first?.thumbnailURL == poster)
        let ownerChanged = cache.update(ownPosts: [own], visitedPlaces: [], currentUserID: otherID)
        #expect(ownerChanged)
        #expect(cache.library.choices.isEmpty)
    }

    @Test
    func everyIndexedLookupAgreesWithExactDistanceAcrossManyVisitAreas() {
        let centers = (0..<600).map { index in
            CLLocationCoordinate2D(latitude: Double((index * 37) % 178) - 89,
                                   longitude: Double((index * 73) % 360) - 180)
        }
        let coverage = PostLocationCoverage(areas: centers.map {
            .init(id: UUID(), name: "Visited", coordinate: $0)
        })
        let queries = centers.prefix(30).flatMap { center in
            [center, .init(latitude: min(90, center.latitude + 0.044), longitude: center.longitude),
             .init(latitude: min(90, center.latitude + 0.046), longitude: center.longitude)]
        }
        for query in queries {
            let location = CLLocation(latitude: query.latitude, longitude: query.longitude)
            let exact = centers.contains {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: location) <= 5_000
            }
            #expect(coverage.contains(query, currentLocation: nil) == exact)
        }
    }

    private func point(north meters: Double) -> CLLocationCoordinate2D {
        // CoreLocation's distance, not a spherical approximation, defines the
        // same radius used by production validation (including boundary cases).
        var lower = origin.coordinate.latitude
        var upper = lower + 1
        for _ in 0..<60 {
            let middle = (lower + upper) / 2
            let location = CLLocation(latitude: middle, longitude: origin.coordinate.longitude)
            if location.distance(from: origin) <= meters { lower = middle }
            else { upper = middle }
        }
        return .init(latitude: lower, longitude: origin.coordinate.longitude)
    }

    private func post(at coordinate: CLLocationCoordinate2D, owner: UUID? = nil, date: TimeInterval = 10,
                      attachments: [RealPost.Attachment] = []) -> RealPost {
        RealPost(id: UUID(), userId: owner ?? ownerID, center: coordinate, radiusMeters: 220,
                 message: "A memory", attachments: attachments, likes: [], comments: [],
                 visibility: .privateOnly, createdAt: Date(timeIntervalSince1970: date), expiresAt: .distantFuture)
    }

    private func place(at coordinate: CLLocationCoordinate2D, name: String = "A place",
                       publicVisitors: Int = 0, ownCheckIns: [RatedPOI.CheckIn] = []) -> MapTalkNearbyPlaceOption {
        let rated = ratedPlace(at: coordinate, name: name, checkIns: ownCheckIns)
        return .init(place: rated, distanceMeters: 0, isPublicDirectoryPlace: true,
                     isInMyMap: !ownCheckIns.isEmpty, friendUsers: [], publicVisitorCount: publicVisitors,
                     ownCheckIns: ownCheckIns)
    }

    private func ratedPlace(at coordinate: CLLocationCoordinate2D, name: String = "A place",
                            checkIns: [RatedPOI.CheckIn]) -> RatedPOI {
        RatedPOI(poi: .init(id: UUID(), name: name, coordinate: coordinate, category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: checkIns, comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }
}

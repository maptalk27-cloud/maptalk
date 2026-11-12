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
        let choices = MapTalkPostLocations.choices(near: origin,
            ownPosts: [custom], places: [], currentUserID: ownerID)
        let chosen = try #require(choices.first)
        #expect(chosen.selection.title == "Our sunset spot")
        #expect(chosen.selection.locationName == "Our sunset spot")
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
        let legacyFingerprint = BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: [])
        input.locationName = "Our sunset spot"
        let restored = try JSONDecoder().decode(BackendMemoryInput.self, from: JSONEncoder().encode(input))
        #expect(restored.locationName == input.locationName)
        #expect(restored.location.latitude == input.location.latitude)
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) != legacyFingerprint)
        input.locationName = nil
        #expect(BackendStore.publicationFingerprint(for: input, urls: [], contentTypes: []) == legacyFingerprint)
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
        #expect(result.isPOI)
        #expect(result.selection.title == venue.place.poi.name)
    }

    @Test
    func personalHistoryRanksAboveCloserPOIsAndIsStableAcrossSourceOrder() {
        let far = post(at: point(north: 3_000), date: 40)
        let near = post(at: point(north: 500), date: 20)
        let closestVenue = place(at: point(north: 5))
        let anotherVenue = place(at: point(north: 10))
        let forward = MapTalkPostLocations.choices(near: origin, ownPosts: [far, near],
            places: [closestVenue, anotherVenue], currentUserID: ownerID)
        let reverse = MapTalkPostLocations.choices(near: origin, ownPosts: [near, far],
            places: [anotherVenue, closestVenue], currentUserID: ownerID)
        #expect(forward.map(\.id) == reverse.map(\.id))
        #expect(forward.prefix(2).map { $0.previousPosts.first?.id } == [near.id, far.id])
        #expect(forward.suffix(2).allSatisfy { $0.isPOI && $0.postCount == 0 })
    }

    @Test
    func ownPOIHistoryWithoutPostsRanksBeforePublicHistoryAndCloserDirectoryPlaces() throws {
        let oldVisit = RatedPOI.CheckIn(userId: ownerID, createdAt: .now.addingTimeInterval(-30 * 86_400))
        let visited = place(at: point(north: 1_000), name: "A familiar cafe", ownCheckIns: [oldVisit])
        let publicHistory = place(at: point(north: 100), publicVisitors: 4)
        let unused = place(at: point(north: 5))
        let forward = MapTalkPostLocations.choices(near: origin, ownPosts: [],
            places: [unused, publicHistory, visited, visited], currentUserID: ownerID)
        let reverse = MapTalkPostLocations.choices(near: origin, ownPosts: [],
            places: [visited, publicHistory, unused], currentUserID: ownerID)

        #expect(forward.map(\.id) == reverse.map(\.id))
        #expect(forward.map { $0.placeOption?.id } == [visited.id, publicHistory.id, unused.id])
        try #require(forward.count == 3)
        #expect(forward.map(\.historyPriority) == [0, 1, 2])
        let ownHistory = try #require(forward.first)
        #expect(ownHistory.isPOI && ownHistory.hasHistory)
        #expect(ownHistory.postCount == 0)
        #expect(ownHistory.ownCheckInCount == 1)
        #expect(ownHistory.lastOwnActivityAt == oldVisit.activityDate)
        #expect(ownHistory.selection.title == visited.place.poi.name)
        #expect(ownHistory.category == .coffee)
        #expect(ownHistory.placeOption?.publicVisitorCount == 0)
        #expect(ownHistory.historyBadge == "Been here")
        #expect(ownHistory.historyDetail?.hasPrefix("You · 1 check-in · Last ") == true)
        #expect(ownHistory.locationSubtitle.contains(POICategory.coffee.displayName))
        #expect(forward[1].hasHistory && forward[1].ownCheckInCount == 0)
        #expect(forward[1].lastOwnActivityAt == nil)
        #expect(forward[1].historyBadge == "Check-ins")
        #expect(forward[1].historyDetail == "4 people checked in")
        #expect(!forward[2].hasHistory)
    }

    @Test
    func combinedPostAndPOIHistoryKeepsNewestOwnActivityAndStillRejectsOutOfRangePlaces() throws {
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
        #expect(result.postCount == 1 && result.ownCheckInCount == 1)
        #expect(result.lastOwnActivityAt == newerVisit.activityDate)
        #expect(result.historyBadge == "Posted here")
        #expect(result.historyDetail?.hasPrefix("You · 1 post · 1 check-in · Last ") == true)
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
        #expect(choices.count == 3)
        #expect(choices.first?.selection.title == "Previous post location")
        #expect(choices.first?.isPOI == false)
        #expect(choices.filter(\.isPOI).allSatisfy { $0.previousPosts.isEmpty })
    }

    @Test
    func exactlyMatchingUniquePOIMergesButCoLocatedPOIsStayIndependent() {
        let coordinate = point(north: 100)
        let history = post(at: coordinate)
        let first = place(at: coordinate, name: "Cafe")
        let second = place(at: coordinate, name: "Hotel")
        let unique = MapTalkPostLocations.choices(near: origin, ownPosts: [history],
            places: [first], currentUserID: ownerID)
        #expect(unique.count == 1)
        #expect(unique.first?.isPOI == true)
        #expect(unique.first?.postCount == 1)

        let ambiguous = MapTalkPostLocations.choices(near: origin, ownPosts: [history],
            places: [first, second], currentUserID: ownerID)
        #expect(ambiguous.count == 3)
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
        // Matching the rounded grouping key is not permission to label a GPS
        // location as a venue; only exact original POI coordinates may merge.
        let venue = place(at: oldCoordinate)
        let withVenue = MapTalkPostLocations.choices(near: origin,
            ownPosts: [post(at: newCoordinate)], places: [venue], currentUserID: ownerID)
        #expect(withVenue.count == 2)
        #expect(withVenue.first?.isPOI == false)
        #expect(withVenue.last?.postCount == 0)
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
        #expect(choices.isEmpty)
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
            places: [], currentUserID: ownerID).isEmpty)
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
        let rated = RatedPOI(poi: .init(id: UUID(), name: name, coordinate: coordinate, category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
        return .init(place: rated, distanceMeters: 0, isPublicDirectoryPlace: true,
                     isInMyMap: !ownCheckIns.isEmpty, friendUsers: [], publicVisitorCount: publicVisitors,
                     ownCheckIns: ownCheckIns)
    }
}

import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct ApplePOISearchTests {
    @Test
    func landmarkClassifiedHotelStillRanksAsAMainDestination() {
        let origin = CLLocationCoordinate2D(latitude: 36.1272, longitude: -115.1657)
        let wynn = place("Wynn Las Vegas", north: 80, from: origin, category: .landmark)
        let cafe = place("Espresso counter", north: 10, from: origin, category: .cafe)
        #expect(wynn.poi.category == .viewpoint)
        #expect(ApplePOIRepository.candidates([cafe, wynn], near: origin).first?.id == wynn.id)
    }

    @Test
    func supplementaryCacheReusesOnlyRecentNearbySnapshots() {
        let origin = CLLocationCoordinate2D(latitude: 36.1272, longitude: -115.1657)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hotel = place("Hotel", north: 80, from: origin, category: .hotel)
        var cache = AppleNearbyPlaceCache()
        #expect(cache.freshPlaces(for: .destinations, near: origin, at: now) == nil)
        _ = cache.resolve([hotel], for: .destinations, near: origin, at: now)
        let nearby = CLLocationCoordinate2D(latitude: origin.latitude + 10 / 111_200, longitude: origin.longitude)
        #expect(cache.freshPlaces(for: .destinations, near: nearby, at: now.addingTimeInterval(30))?.map(\.id) == [hotel.id])
        #expect(cache.freshPlaces(for: .destinations, near: origin, at: now.addingTimeInterval(61)) == nil)
        let moved = CLLocationCoordinate2D(latitude: origin.latitude + 30 / 111_200, longitude: origin.longitude)
        #expect(cache.freshPlaces(for: .destinations, near: moved, at: now) == nil)
        #expect(cache.freshPlaces(for: .nearby, near: origin, at: now) == nil)
    }

    @Test
    func existingRepositoriesKeepADeterministicLocalSearchFallback() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let item = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        item.name = "Café at the terminal"
        let place = ApplePOIRepository.makeRatedPOI(from: item)!
        let repository = LocalSearchTestRepository(places: [place])
        var received: [RatedPOI] = []
        let subscription = repository.search("CAFE", near: origin).sink { received = $0 }
        #expect(received.map(\.id) == [place.id])
        #expect(repository.lookupCount == 1)
        let blank = repository.search("  ", near: origin).sink { received = $0 }
        #expect(received.isEmpty)
        #expect(repository.lookupCount == 1)
        withExtendedLifetime((subscription, blank)) {}
    }

    @Test
    func statusAwareSearchKeepsLegacyRepositoriesCompatible() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let repository: any POIRepository = LocalSearchTestRepository(places: [])
        var results: [POISearchResult] = []
        let nearby = repository.nearResult(origin).sink { results.append($0) }
        let named = repository.searchResult("hotel", near: origin).sink { results.append($0) }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.places.isEmpty && $0.issue == nil })
        withExtendedLifetime((nearby, named)) {}
    }

    @Test
    func directoryFailureIsDifferentFromASuccessfulEmptyResult() {
        let successfulEmpty = ApplePOIRepository.searchResult(mapItems: [], error: nil)
        #expect(successfulEmpty.places.isEmpty)
        #expect(successfulEmpty.issue == nil)
        let notFound = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))
        #expect(ApplePOIRepository.searchResult(mapItems: nil, error: notFound).issue == nil)
        let failures = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue)),
            NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue)),
        ]
        for error in failures {
            let result = ApplePOIRepository.searchResult(mapItems: nil, error: error)
            #expect(result.places.isEmpty)
            #expect(result.issue == .temporarilyUnavailable)
        }
        #expect(ApplePOIRepository.searchResult(mapItems: nil, error: nil).issue == .temporarilyUnavailable)
    }

    @Test
    func recoveredSearchClearsItsFailureWithoutLosingPlaces() throws {
        let item = MKMapItem(location: CLLocation(latitude: 47.448, longitude: -122.308), address: nil)
        item.name = "Airport Hotel"
        item.pointOfInterestCategory = .hotel
        let result = ApplePOIRepository.searchResult(mapItems: [item], error: nil)
        #expect(result.issue == nil)
        let place = try #require(result.places.first)
        #expect(place.poi.category == .hotel)
        #expect(place.poi.directoryKind == nil, "An airport in a hotel name cannot expand its check-in radius")
    }

    @Test
    func namedLookupSearchesApplePlacesInsteadOfOnlyFilteringSuggestions() throws {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let request = try #require(ApplePOIRepository.namedSearchRequest("  SeaTac Airport \n", near: origin))
        #expect(request.naturalLanguageQuery == "SeaTac Airport")
        #expect(request.resultTypes == .pointOfInterest)
        #expect(request.regionPriority == .required)
        #expect(request.region.center.latitude == origin.latitude)
        #expect(request.region.center.longitude == origin.longitude)
        #expect(request.pointOfInterestFilter?.includes(.airport) == true)
        #expect(request.pointOfInterestFilter?.includes(.restaurant) == true)
        #expect(ApplePOIRepository.namedSearchRequest(" \n", near: origin) == nil)
        #expect(ApplePOIRepository.namedSearchRequest("Coffee", near: .init(latitude: .nan, longitude: 0)) == nil)
        // A single Chinese character is a valid place query; do not impose
        // an English-only two/three-character minimum.
        #expect(ApplePOIRepository.namedSearchRequest("茶", near: origin)?.naturalLanguageQuery == "茶")
    }

    @Test
    func lookupMatchesKeepTheSameProximityAndGPSContract() throws {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        func item(_ name: String, north: Double, category: MKPointOfInterestCategory) -> RatedPOI {
            let item = MKMapItem(location: CLLocation(latitude: origin.latitude + north / 111_000,
                longitude: origin.longitude), address: nil)
            item.name = name
            item.pointOfInterestCategory = category
            return ApplePOIRepository.makeRatedPOI(from: item)!
        }
        let cafe = item("Cafe", north: 80, category: .cafe)
        let remoteCafe = item("Cafe", north: 500, category: .cafe)
        let airport = item("Airport", north: 120, category: .airport)
        let terminal = item("Airport terminal", north: 140, category: .airport)
        let remoteAirport = item("Airport", north: 2_500, category: .airport)
        let candidates = ApplePOIRepository.candidates([remoteCafe, airport, cafe, remoteAirport, cafe], near: origin)
        #expect(candidates.map(\.id) == [airport.id, cafe.id])
        #expect(candidates.first?.poi.coordinate.latitude == airport.poi.coordinate.latitude)
        #expect(candidates.last?.poi.coordinate.latitude == cafe.poi.coordinate.latitude)
        let namedMatches = ApplePOIRepository.searchCandidates([terminal, airport, remoteAirport], near: origin)
        #expect(Set(namedMatches.map(\.id)) == Set([airport.id, terminal.id]))
    }

    @Test
    func recommendationsRemain150MetersWhileNamedSearchAllows500() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let close = place("Nearby", north: 140, from: origin)
        let searchable = place("Search only", north: 490, from: origin)
        let outside = place("Too far", north: 550, from: origin)
        let places = [outside, searchable, close]
        #expect(ApplePOIRepository.candidates(places, near: origin).map(\.id) == [close.id])
        #expect(ApplePOIRepository.searchCandidates(places, near: origin).map(\.id)
            == [close.id, searchable.id])
        #expect(ApplePOIRepository.explicitSearchRadius(configuredRadius: 150) == 500)
    }

    @Test
    func namedSearchUsesOnlyTheCurrentCircleAndDoesNotMoveTheLandmark() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let eligible = place("Nearby cafe", north: 400, from: origin)
        let tooFar = place("Too far", north: 600, from: origin)
        let distantAirport = place("Airport too far", north: 1_200, from: origin, category: .airport)
        let candidates = ApplePOIRepository.searchCandidates(
            [tooFar, eligible, distantAirport, eligible], near: origin)
        #expect(candidates.map(\.id) == [eligible.id])
        #expect(candidates.first?.poi.coordinate.latitude == eligible.poi.coordinate.latitude)
        #expect(candidates.first?.poi.coordinate.longitude == eligible.poi.coordinate.longitude)
        #expect(ApplePOIRepository.searchCandidates([eligible], near: origin,
            maximumResults: 0).isEmpty)
        #expect(ApplePOIRepository.searchCandidates([eligible],
            near: .init(latitude: .nan, longitude: 0)).isEmpty)
    }

    @Test
    func namedSearchKeepsPostScopeWithoutAnAirportDistanceException() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let airport = place("Airport", north: 1_500, from: origin, category: .airport)
        let remoteAirport = place("Remote airport", north: 2_500, from: origin, category: .airport)
        let postPlace = place("Post place", north: 4_500, from: origin)
        let outsidePost = place("Outside Post range", north: 5_500, from: origin)
        let places = [outsidePost, postPlace, remoteAirport, airport]
        #expect(ApplePOIRepository.searchCandidates(places, near: origin).isEmpty)
        #expect(ApplePOIRepository.searchCandidates(places, near: origin,
            configuredRadius: 5_000).map(\.id) == [airport.id, remoteAirport.id, postPlace.id])
        #expect(ApplePOIRepository.explicitSearchRadius(configuredRadius: 5_000) == 5_000)
    }

    @Test
    func focusedDiscoveryRescuesMainVenuesWithoutWideningTheCircle() {
        let origin = CLLocationCoordinate2D(latitude: 36.126, longitude: -115.165)
        let broad = ApplePOIRepository.nearbyRequest(near: origin, radius: 150, destinationsOnly: false)
        let focused = ApplePOIRepository.nearbyRequest(near: origin, radius: 150, destinationsOnly: true)
        #expect(broad.pointOfInterestFilter?.includes(.restaurant) == true)
        #expect(focused.pointOfInterestFilter?.includes(.hotel) == true)
        #expect(focused.pointOfInterestFilter?.includes(.airport) == true)
        #expect(focused.pointOfInterestFilter?.includes(.landmark) == true)
        #expect(focused.pointOfInterestFilter?.includes(.restaurant) == false)
        #expect(focused.pointOfInterestFilter?.includes(.parking) == false)
        #expect(focused.radius == broad.radius)
        #expect(focused.radius == 150)
        #expect(focused.coordinate.latitude == origin.latitude)
        #expect(focused.coordinate.longitude == origin.longitude)
    }

    @Test
    func discoveryMergesOnceAndKeepsValidPartialResultsOnFailure() {
        let origin = CLLocationCoordinate2D(latitude: 36.126, longitude: -115.165)
        let cafe = place("Cafe", north: 20, from: origin)
        let hotel = place("Wynn", north: 120, from: origin, category: .hotel)
        let result = ApplePOIRepository.mergedNearbyResults(
            .init(places: [cafe, hotel]), .init(places: [hotel]))
        #expect(result.places.map(\.id) == [cafe.id, hotel.id])
        #expect(result.issue == nil)
        let partial = ApplePOIRepository.mergedNearbyResults(
            .init(places: [], issue: .temporarilyUnavailable), .init(places: [hotel]))
        #expect(partial.places.map(\.id) == [hotel.id])
        #expect(partial.issue == .temporarilyUnavailable)
        var cache = AppleNearbyPlaceCache()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = cache.resolve([cafe], for: .nearby, near: origin, at: now)
        _ = cache.resolve([hotel], for: .destinations, near: origin, at: now)
        #expect(cache.resolve(nil, for: .nearby, near: origin, at: now).map(\.id) == [cafe.id])
        #expect(cache.resolve(nil, for: .destinations, near: origin, at: now).map(\.id) == [hotel.id])
    }

    @Test
    func mainVenuesAreRankedBeforeTheResultCapInsteadOfLosingToNearbyFacilities() {
        let origin = CLLocationCoordinate2D(latitude: 36.126, longitude: -115.165)
        let offices = (0..<35).map {
            place("Office \($0)", north: Double(5 + $0), from: origin, category: .bank)
        }
        let elevator = place("Elevator", north: 1, from: origin, category: .parking)
        let escalator = place("Escalator", north: 2, from: origin, category: .parking)
        let hotel = place("Wynn", north: 140, from: origin, category: .hotel)
        let restaurant = place("Wing Lei", north: 120, from: origin, category: .restaurant)
        let result = ApplePOIRepository.candidates(offices + [elevator, escalator, hotel, restaurant],
            near: origin, maximumResults: 30)
        #expect(result.count == 30)
        #expect(result.first?.id == hotel.id)
        #expect(result[1].id == restaurant.id)
        #expect(!result.contains { $0.id == elevator.id || $0.id == escalator.id })
        #expect(result.contains { $0.poi.category == .other }, "Unknown venues are not blanket-deleted")
    }

    @Test
    func explicitNameMatchWinsOverCloserSubsidiaryVenuesAndStillObeys500Meters() {
        let origin = CLLocationCoordinate2D(latitude: 36.126, longitude: -115.165)
        let hotel = place("Wynn", north: 450, from: origin, category: .hotel)
        let cafe = place("Wynn Cafe", north: 10, from: origin)
        let unrelated = place("Hotel next door", north: 5, from: origin, category: .hotel)
        let remote = place("Wynn", north: 550, from: origin, category: .hotel)
        let results = ApplePOIRepository.searchCandidates([cafe, remote, unrelated, hotel],
            near: origin, maximumResults: 2, query: "wynn")
        #expect(results.map(\.id) == [hotel.id, cafe.id])
        #expect(results.first?.poi.coordinate.latitude == hotel.poi.coordinate.latitude)
    }

    @Test
    func legitimateVenuesAreNotLostForContainingFacilityWords() {
        let origin = CLLocationCoordinate2D(latitude: 36.126, longitude: -115.165)
        let brewery = place("Elevator Brewing", north: 20, from: origin, category: .brewery)
        let unknown = place("Community center", north: 30, from: origin, category: .school)
        let elevator = place("Elevator", north: 5, from: origin, category: .parking)
        let result = ApplePOIRepository.searchCandidates([elevator, brewery, unknown], near: origin)
        #expect(Set(result.map(\.id)) == Set([brewery.id, unknown.id]))
    }

    @Test
    func smallGPSDriftDoesNotReorderEquallyRelevantDirectoryChoices() {
        let origin = CLLocationCoordinate2D(latitude: 47.448, longitude: -122.308)
        let first = place("Cafe A", north: 120, from: origin)
        let second = place("Cafe B", north: 130, from: origin)
        let moved = CLLocationCoordinate2D(latitude: origin.latitude + 3 / 111_000,
            longitude: origin.longitude)
        let initial = ApplePOIRepository.candidates([first, second], near: origin).map(\.id)
        let updated = ApplePOIRepository.candidates([second, first], near: moved).map(\.id)
        #expect(initial == updated)
    }

    private func place(_ name: String, north: Double, from coordinate: CLLocationCoordinate2D,
                       category: MKPointOfInterestCategory = .cafe) -> RatedPOI {
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude + north / 111_000,
            longitude: coordinate.longitude), address: nil)
        item.name = name
        item.pointOfInterestCategory = category
        return ApplePOIRepository.makeRatedPOI(from: item)!
    }

    @Test
    func categoriesUseExactDirectoryTypesInsteadOfSubstringMatching() {
        #expect(ApplePOIRepository.category(for: .foodMarket) == .market)
        #expect(ApplePOIRepository.category(for: .store) == .market)
        #expect(ApplePOIRepository.category(for: .restaurant) == .restaurant)
        #expect(ApplePOIRepository.category(for: .cafe) == .coffee)
        #expect(ApplePOIRepository.category(for: .bakery) == .coffee)
        #expect(ApplePOIRepository.category(for: .parking) == .other)
        #expect(ApplePOIRepository.category(for: .skatePark) == .other)
        #expect(ApplePOIRepository.category(for: .hotel) == .hotel)
        #expect(ApplePOIRepository.category(for: .airport) == .airport)
    }

    @Test
    func newCategoriesPreserveOldWireValuesAndHaveDistinctIcons() throws {
        let original = ["viewpoint", "restaurant", "coffee", "nightlife", "art", "market", "other"]
        for rawValue in original {
            let data = try JSONEncoder().encode(rawValue)
            let category = try JSONDecoder().decode(POICategory.self, from: data)
            #expect(category.rawValue == rawValue)
        }
        #expect(POICategory.hotel.displayName == "Hotel")
        #expect(POICategory.hotel.symbolName == "bed.double.fill")
        #expect(POICategory.airport.symbolName == "airplane")
        #expect(POICategory.allCases.count == original.count + 2)
    }

    @Test
    func knownLandmarksAndArtsDoNotFallThroughToOther() {
        let landmarks: [MKPointOfInterestCategory] = [
            .castle, .fortress, .nationalMonument, .landmark, .aquarium,
            .zoo, .hiking, .campground, .nationalPark, .beach, .park,
        ]
        for category in landmarks {
            #expect(ApplePOIRepository.category(for: category) == .viewpoint)
        }
        let arts: [MKPointOfInterestCategory] = [.museum, .theater, .movieTheater, .library, .planetarium]
        for category in arts {
            #expect(ApplePOIRepository.category(for: category) == .art)
        }
        let nightlife: [MKPointOfInterestCategory] = [.nightlife, .musicVenue, .brewery, .winery, .distillery]
        for category in nightlife {
            #expect(ApplePOIRepository.category(for: category) == .nightlife)
        }
    }

    @Test
    func unknownAndUnrelatedDirectoryTypesAreNotMisrepresented() {
        let unsupported: [MKPointOfInterestCategory?] = [
            nil, .hospital, .school, .publicTransport,
            .init(rawValue: "FutureRestaurantDistrict"),
        ]
        for category in unsupported {
            #expect(ApplePOIRepository.category(for: category) == .other)
        }
        let item = MKMapItem(location: CLLocation(latitude: 47.448, longitude: -122.308), address: nil)
        item.name = "Coffee Market Airport Hotel"
        item.pointOfInterestCategory = .hospital
        #expect(ApplePOIRepository.makeRatedPOI(from: item)?.poi.category == .other)
        #expect(ApplePOIRepository.makeRatedPOI(from: item)?.poi.directoryKind == nil)
    }
}

@MainActor
private final class LocalSearchTestRepository: POIRepository {
    let places: [RatedPOI]
    var lookupCount = 0

    init(places: [RatedPOI]) { self.places = places }

    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        lookupCount += 1
        return Just(places).eraseToAnyPublisher()
    }
}

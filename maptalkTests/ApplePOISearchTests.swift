import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct ApplePOISearchTests {
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
        let airport = item("Airport", north: 1_200, category: .airport)
        let terminal = item("Airport terminal", north: 1_400, category: .airport)
        let remoteAirport = item("Airport", north: 2_500, category: .airport)
        let candidates = ApplePOIRepository.candidates([remoteCafe, airport, cafe, remoteAirport, cafe], near: origin)
        #expect(candidates.map(\.id) == [cafe.id, airport.id])
        #expect(candidates.first?.poi.coordinate.latitude == cafe.poi.coordinate.latitude)
        #expect(candidates.last?.poi.coordinate.latitude == airport.poi.coordinate.latitude)
        let namedMatches = ApplePOIRepository.candidates([terminal, airport, remoteAirport],
            near: origin, reservesOneAirport: false)
        #expect(namedMatches.map(\.id) == [airport.id, terminal.id])
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
            nil, .airport, .hotel, .hospital, .school, .publicTransport,
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

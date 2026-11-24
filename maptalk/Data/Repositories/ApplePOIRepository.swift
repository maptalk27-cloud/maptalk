import Combine
import CoreLocation
import CryptoKit
import Foundation
import MapKit

/// Apple Maps is used as a lightweight public place directory for the
/// camera-first Place publisher. These results are deliberately kept out of
/// the main MapTalk content map; they only help identify where a capture was
/// made.
final class ApplePOIRepository: POIRepository {
    private let searchRadius: CLLocationDistance
    private let maximumResults: Int
    private var cache = AppleNearbyPlaceCache()

    init(
        // Unsolicited suggestions stay close; explicit search has its own radius.
        searchRadius: CLLocationDistance = POISelectionPolicy.nearbyRadius,
        maximumResults: Int = 30
    ) {
        self.searchRadius = searchRadius
        self.maximumResults = maximumResults
    }

    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        nearResult(coordinate).map(\.places).eraseToAnyPublisher()
    }

    func nearResult(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never> {
        Deferred { [self] in
            fetch(near: coordinate)
            .map { nearby in
                POISearchResult(
                    places: Self.candidates(nearby.places, near: coordinate,
                        nearbyRadius: self.searchRadius, maximumResults: self.maximumResults),
                    issue: nearby.issue)
            }
        }
        .eraseToAnyPublisher()
    }

    /// A nearby directory response is a suggestion list, not an exhaustive
    /// catalogue. When a person types a place name, ask Maps for that name
    /// instead of filtering only the suggestions it happened to return.
    func search(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        searchResult(query, near: coordinate).map(\.places).eraseToAnyPublisher()
    }

    func searchResult(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never> {
        let lookupRadius = Self.explicitSearchRadius(configuredRadius: searchRadius)
        guard let request = Self.namedSearchRequest(query, near: coordinate, radius: lookupRadius) else {
            return Just(POISearchResult(places: [])).eraseToAnyPublisher()
        }
        return fetchNamed(request)
            .map { [self] result in
                POISearchResult(places: Self.searchCandidates(result.places,
                    near: coordinate, configuredRadius: searchRadius,
                    maximumResults: maximumResults, query: query), issue: result.issue)
            }
            .eraseToAnyPublisher()
    }

    private func fetchNamed(_ request: MKLocalSearch.Request) -> AnyPublisher<POISearchResult, Never> {
        Deferred {
            let search = MKLocalSearch(request: request)
            return Future<POISearchResult, Never> { promise in
                search.start { response, error in
                    promise(.success(Self.searchResult(mapItems: response?.mapItems, error: error)))
                }
            }
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveCancel: search.cancel)
        }
        .eraseToAnyPublisher()
    }

    static func namedSearchRequest(_ query: String, near coordinate: CLLocationCoordinate2D,
                                   radius: CLLocationDistance = POISelectionPolicy.searchRadius) -> MKLocalSearch.Request? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = .includingAll
        request.regionPriority = .required
        // Only a lookup rectangle. The composer supplies current GPS;
        // exact distance still bounds results independently of the map viewport.
        request.region = MKCoordinateRegion(center: coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2)
        return request
    }

    static func explicitSearchRadius(configuredRadius: CLLocationDistance) -> CLLocationDistance {
        max(configuredRadius, POISelectionPolicy.searchRadius)
    }

    /// POI name search is 500 m around the supplied search origin. Post keeps its
    /// separately configured 5 km directory scope.
    static func searchCandidates(_ places: [RatedPOI], near coordinate: CLLocationCoordinate2D,
                                 configuredRadius: CLLocationDistance = POISelectionPolicy.nearbyRadius,
                                 maximumResults: Int = 30, query: String = "") -> [RatedPOI] {
        rankedCandidates(places, near: coordinate,
            radius: explicitSearchRadius(configuredRadius: configuredRadius),
            maximumResults: maximumResults, query: query)
    }

    private func fetch(near coordinate: CLLocationCoordinate2D)
        -> AnyPublisher<POISearchResult, Never> {
        // A crowded broad response can omit the venue itself. One focused
        // request gives destinations another chance without widening the GPS
        // radius or requesting every category separately. Publish one merged
        // snapshot, not two lists that reshuffle as requests finish.
        let broad = Self.nearbyRequest(near: coordinate, radius: searchRadius, destinationsOnly: false)
        let destinations = Self.nearbyRequest(near: coordinate, radius: searchRadius, destinationsOnly: true)
        return Publishers.Zip(
            fetchNearby(broad, cacheKey: .nearby, near: coordinate),
            fetchNearby(destinations, cacheKey: .destinations, near: coordinate)
        )
        .map { Self.mergedNearbyResults($0, $1) }
        .eraseToAnyPublisher()
    }

    static func nearbyRequest(near coordinate: CLLocationCoordinate2D,
                              radius: CLLocationDistance, destinationsOnly: Bool) -> MKLocalPointsOfInterestRequest {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        request.pointOfInterestFilter = destinationsOnly
            ? MKPointOfInterestFilter(including: [.hotel, .airport, .landmark])
            : .includingAll
        return request
    }

    static func mergedNearbyResults(_ broad: POISearchResult, _ destinations: POISearchResult) -> POISearchResult {
        var seen = Set<UUID>()
        let places = (broad.places + destinations.places).filter { seen.insert($0.id).inserted }
        return POISearchResult(places: places, issue: broad.issue ?? destinations.issue)
    }

    private func fetchNearby(_ request: MKLocalPointsOfInterestRequest,
                             cacheKey: AppleNearbyPlaceCache.Query,
                             near coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never> {
        // Reuse the supplementary lookup across small GPS adjustments. The
        // merged candidates still undergo an exact current-distance check.
        if cacheKey == .destinations,
           let places = cache.freshPlaces(for: cacheKey, near: coordinate, at: .now) {
            return Just(POISearchResult(places: places)).eraseToAnyPublisher()
        }
        return Deferred {
            let search = MKLocalSearch(request: request)
            return Future<POISearchResult, Never> { promise in
                search.start { response, error in
                    promise(.success(Self.searchResult(mapItems: response?.mapItems, error: error)))
                }
            }
            .handleEvents(receiveCancel: search.cancel)
        }
        .receive(on: DispatchQueue.main)
        .map { [weak self] result -> POISearchResult in
            guard let self else { return result }
            let places = cache.resolve(result.issue == nil ? result.places : nil,
                for: cacheKey, near: coordinate, at: .now)
            return POISearchResult(places: places, issue: result.issue)
        }
        .eraseToAnyPublisher()
    }

    /// MapKit reports a genuine miss as `placemarkNotFound`; network,
    /// throttling and server failures must not impersonate a successful miss.
    nonisolated static func searchResult(mapItems: [MKMapItem]?, error: Error?) -> POISearchResult {
        if let error {
            let error = error as NSError
            let isMissingPlace = error.domain == MKErrorDomain
                && error.code == Int(MKError.Code.placemarkNotFound.rawValue)
            return POISearchResult(places: [], issue: isMissingPlace ? nil : .temporarilyUnavailable)
        }
        guard let mapItems else {
            return POISearchResult(places: [], issue: .temporarilyUnavailable)
        }
        return POISearchResult(places: mapItems.compactMap(makeRatedPOI))
    }

    /// Distance is measured to the real landmark point. The caller keeps the
    /// device's live GPS as the publication anchor, not this directory location.
    static func candidates(_ places: [RatedPOI], near coordinate: CLLocationCoordinate2D,
                           nearbyRadius: CLLocationDistance = POISelectionPolicy.nearbyRadius,
                           maximumResults: Int = 30) -> [RatedPOI] {
        rankedCandidates(places, near: coordinate, radius: nearbyRadius,
            maximumResults: maximumResults, query: "")
    }

    private static func rankedCandidates(_ places: [RatedPOI], near coordinate: CLLocationCoordinate2D,
                                         radius: CLLocationDistance, maximumResults: Int,
                                         query: String) -> [RatedPOI] {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return [] }
        var seenIDs = Set<UUID>()
        let sorted = places.compactMap { place -> (place: RatedPOI, match: Int, score: Int, band: Int)? in
            guard CLLocationCoordinate2DIsValid(place.poi.coordinate),
                  !POIRecommendationPolicy.isSupportingFacility(name: place.poi.name,
                      category: place.poi.category) else { return nil }
            let distance = POISelectionPolicy.distance(from: coordinate, to: place.poi.coordinate)
            guard distance.isFinite, distance <= radius,
                  seenIDs.insert(place.id).inserted else { return nil }
            return (place,
                POIRecommendationPolicy.nameMatch(place.poi.name, query: query),
                POIRecommendationPolicy.score(category: place.poi.category, distanceMeters: distance),
                POIRecommendationPolicy.distanceBand(distance))
        }.sorted {
            if $0.match != $1.match { return $0.match > $1.match }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.band != $1.band { return $0.band < $1.band }
            return $0.place.id.uuidString < $1.place.id.uuidString
        }
        return Array(sorted.prefix(max(0, maximumResults))).map(\.place)
    }

    nonisolated static func makeRatedPOI(from mapItem: MKMapItem) -> RatedPOI? {
        guard let rawName = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawName.isEmpty == false else {
            return nil
        }

        let coordinate = mapItem.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let sourceKey: String
        if let identifier = mapItem.identifier?.rawValue {
            sourceKey = "apple-maps:\(identifier)"
        } else {
            let fallbackCoordinate = String(
                format: "%.6f,%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                coordinate.latitude,
                coordinate.longitude
            )
            sourceKey = "apple-maps-fallback:\(rawName.lowercased()):\(fallbackCoordinate)"
        }

        let poi = POI(
            id: stableUUID(for: sourceKey),
            name: rawName,
            coordinate: coordinate,
            category: category(for: mapItem.pointOfInterestCategory),
            directoryKind: mapItem.pointOfInterestCategory == .airport ? .airport : nil
        )
        return RatedPOI(
            poi: poi,
            highlight: nil,
            secondary: nil,
            media: [],
            checkIns: [],
            comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: [],
            isFavoritedByCurrentUser: false,
            favoritesCount: 0
        )
    }

    nonisolated static func category(
        for category: MKPointOfInterestCategory?
    ) -> POICategory {
        // Apple's category identifiers are structured values, not keywords.
        // Substring matching made FoodMarket a restaurant, and overlooked
        // landmarks such as castles and national monuments entirely.
        switch category {
        case .cafe, .bakery:
            return .coffee
        case .restaurant:
            return .restaurant
        case .nightlife, .musicVenue, .brewery, .winery, .distillery:
            return .nightlife
        case .museum, .theater, .movieTheater, .library, .planetarium:
            return .art
        case .store, .foodMarket:
            return .market
        case .hotel:
            return .hotel
        case .airport:
            return .airport
        case .park, .nationalPark, .beach, .marina, .landmark,
             .castle, .fortress, .nationalMonument, .aquarium, .zoo,
             .amusementPark, .fairground, .campground, .rvPark, .hiking:
            return .viewpoint
        default:
            // Do not guess from a business's name. Transport, healthcare,
            // schools and services do not belong to the app's leisure types.
            return .other
        }
    }

    /// `POI.id` predates external place identifiers and is a UUID. Hashing the
    /// Apple Place ID into a namespaced UUID keeps one Apple place stable
    /// across searches and lets future public/friend check-ins merge cleanly.
    nonisolated private static func stableUUID(for sourceKey: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(sourceKey.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// A transient Maps error must not erase valid choices while a person is
/// standing still. Never borrow a different location's results or keep them
/// indefinitely, and treat a successful empty response as authoritative.
struct AppleNearbyPlaceCache {
    enum Query: Hashable { case nearby, airports, destinations }
    private struct Entry {
        let coordinate: CLLocationCoordinate2D
        let date: Date
        let places: [RatedPOI]
    }
    private var entries: [Query: Entry] = [:]

    func freshPlaces(for query: Query, near coordinate: CLLocationCoordinate2D, at date: Date) -> [RatedPOI]? {
        guard let entry = entries[query],
              (0...60).contains(date.timeIntervalSince(entry.date)),
              POISelectionPolicy.distance(from: coordinate, to: entry.coordinate) <= 25 else { return nil }
        return entry.places
    }

    mutating func resolve(_ response: [RatedPOI]?, for query: Query,
                          near coordinate: CLLocationCoordinate2D, at date: Date) -> [RatedPOI] {
        if let response {
            entries[query] = Entry(coordinate: coordinate, date: date, places: response)
            return response
        }
        guard let previous = entries[query],
              (0...300).contains(date.timeIntervalSince(previous.date)),
              CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: previous.coordinate.latitude,
                    longitude: previous.coordinate.longitude)) <= 25 else { return [] }
        return previous.places
    }
}

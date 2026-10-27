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
        // Keep a small buffer beyond the visible picker radius so the UI can
        // fill a sparse list without searching an entire neighborhood.
        searchRadius: CLLocationDistance = POISelectionPolicy.nearbyRadius,
        maximumResults: Int = 30
    ) {
        self.searchRadius = searchRadius
        self.maximumResults = maximumResults
    }

    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Deferred { [self] in
            // An airport's directory point can be far from its gates. Only
            // this explicit category gets the wider query; ordinary shops do not.
            Publishers.Zip(
                fetch(.nearby, near: coordinate),
                fetch(.airports, near: coordinate)
            )
            .map { nearby, airports in
                Self.candidates(nearby + airports, near: coordinate,
                    nearbyRadius: searchRadius, maximumResults: maximumResults)
            }
        }
        .eraseToAnyPublisher()
    }

    /// A nearby directory response is a suggestion list, not an exhaustive
    /// catalogue. When a person types a place name, ask Maps for that name
    /// instead of filtering only the suggestions it happened to return.
    func search(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        guard let request = Self.namedSearchRequest(query, near: coordinate) else {
            return Just([]).eraseToAnyPublisher()
        }
        return Deferred { [self] in
            let search = MKLocalSearch(request: request)
            return Future<[RatedPOI], Never> { promise in
                search.start { response, _ in
                    promise(.success(response?.mapItems.compactMap(Self.makeRatedPOI) ?? []))
                }
            }
            .receive(on: DispatchQueue.main)
            .map { Self.candidates($0, near: coordinate,
                nearbyRadius: searchRadius, maximumResults: maximumResults,
                reservesOneAirport: false) }
            .handleEvents(receiveCancel: search.cancel)
        }
        .eraseToAnyPublisher()
    }

    static func namedSearchRequest(_ query: String, near coordinate: CLLocationCoordinate2D) -> MKLocalSearch.Request? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = .includingAll
        request.regionPriority = .required
        // This is only the lookup region. Results still pass through the
        // same per-place distance policy as nearby suggestions, so a match
        // never moves the user's GPS or silently allows a remote check-in.
        request.region = MKCoordinateRegion(center: coordinate,
            latitudinalMeters: POISelectionPolicy.airportRadius * 2,
            longitudinalMeters: POISelectionPolicy.airportRadius * 2)
        return request
    }

    private func fetch(_ kind: AppleNearbyPlaceCache.Query, near coordinate: CLLocationCoordinate2D)
        -> AnyPublisher<[RatedPOI], Never> {
        let radius = kind == .airports ? POISelectionPolicy.airportRadius : searchRadius
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        request.pointOfInterestFilter = kind == .airports
            ? MKPointOfInterestFilter(including: [.airport]) : .includingAll
        let search = MKLocalSearch(request: request)
        return Future<[RatedPOI]?, Never> { promise in
            search.start { response, error in
                guard error == nil, let response else {
                    promise(.success(nil))
                    return
                }
                let places = response.mapItems.compactMap(Self.makeRatedPOI)
                    .filter { kind != .airports || $0.poi.directoryKind == .airport }
                promise(.success(places))
            }
        }
        .receive(on: DispatchQueue.main)
        .map { [weak self] response -> [RatedPOI] in
            guard let self else { return [] }
            return cache.resolve(response, for: kind, near: coordinate, at: .now)
        }
        .handleEvents(receiveCancel: search.cancel)
        .eraseToAnyPublisher()
    }

    /// Distance is measured to the real landmark point. The caller keeps the
    /// device's live GPS as the publication anchor, not this directory location.
    static func candidates(_ places: [RatedPOI], near coordinate: CLLocationCoordinate2D,
                           nearbyRadius: CLLocationDistance = POISelectionPolicy.nearbyRadius,
                           maximumResults: Int = 30,
                           reservesOneAirport: Bool = true) -> [RatedPOI] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var seenIDs = Set<UUID>()
        let sorted = places.compactMap { place -> (RatedPOI, CLLocationDistance)? in
            guard seenIDs.insert(place.id).inserted else { return nil }
            let distance = CLLocation(latitude: place.poi.coordinate.latitude,
                longitude: place.poi.coordinate.longitude).distance(from: origin)
            let limit = place.poi.directoryKind == .airport ? POISelectionPolicy.airportRadius : nearbyRadius
            guard distance.isFinite, distance <= limit else { return nil }
            return (place, distance)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        // Name search must retain all matching places. The single airport
        // slot is only a curation rule for the unsolicited nearby shortlist.
        guard reservesOneAirport else {
            return Array(sorted.prefix(max(0, maximumResults))).map(\.0)
        }
        let airport = sorted.first { $0.0.poi.directoryKind == .airport }?.0
        let capacity = max(0, maximumResults - (airport == nil ? 0 : 1))
        let ordinary = sorted.filter { $0.0.poi.directoryKind != .airport }.prefix(capacity).map(\.0)
        return maximumResults > 0 ? ordinary + (airport.map { [$0] } ?? []) : []
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
    enum Query: Hashable { case nearby, airports }
    private struct Entry {
        let coordinate: CLLocationCoordinate2D
        let date: Date
        let places: [RatedPOI]
    }
    private var entries: [Query: Entry] = [:]

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

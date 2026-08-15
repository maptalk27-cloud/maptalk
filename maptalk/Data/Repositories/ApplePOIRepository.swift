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

    init(
        // Keep a small buffer beyond the visible picker radius so the UI can
        // fill a sparse list without searching an entire neighborhood.
        searchRadius: CLLocationDistance = 150,
        maximumResults: Int = 30
    ) {
        self.searchRadius = searchRadius
        self.maximumResults = maximumResults
    }

    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Deferred { [searchRadius, maximumResults] in
            let request = MKLocalPointsOfInterestRequest(
                center: coordinate,
                radius: searchRadius
            )
            request.pointOfInterestFilter = .includingAll

            let search = MKLocalSearch(request: request)
            return Future<[RatedPOI], Never> { promise in
                search.start { response, _ in
                    guard let response else {
                        promise(.success([]))
                        return
                    }

                    let origin = CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                    var seenIDs = Set<UUID>()
                    let places = response.mapItems
                        .compactMap(Self.makeRatedPOI)
                        .compactMap { place -> (RatedPOI, CLLocationDistance)? in
                            guard seenIDs.insert(place.id).inserted else { return nil }
                            let placeLocation = CLLocation(
                                latitude: place.poi.coordinate.latitude,
                                longitude: place.poi.coordinate.longitude
                            )
                            let distance = placeLocation.distance(from: origin)
                            guard distance <= searchRadius else { return nil }
                            return (place, distance)
                        }
                        .sorted { $0.1 < $1.1 }
                        .prefix(maximumResults)
                        .map(\.0)

                    promise(.success(places))
                }
            }
            .handleEvents(receiveCancel: search.cancel)
        }
        .eraseToAnyPublisher()
    }

    nonisolated private static func makeRatedPOI(from mapItem: MKMapItem) -> RatedPOI? {
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
            category: category(for: mapItem.pointOfInterestCategory)
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

    nonisolated private static func category(
        for category: MKPointOfInterestCategory?
    ) -> POICategory {
        let value = category?.rawValue.lowercased() ?? ""

        if value.contains("cafe")
            || value.contains("coffee")
            || value.contains("bakery") {
            return .coffee
        }
        if value.contains("restaurant") || value.contains("food") {
            return .restaurant
        }
        if value.contains("nightlife")
            || value.contains("musicvenue")
            || value.contains("brewery")
            || value.contains("winery")
            || value.contains("distillery") {
            return .nightlife
        }
        if value.contains("museum")
            || value.contains("theater")
            || value.contains("library") {
            return .art
        }
        if value.contains("store")
            || value.contains("market")
            || value.contains("mall") {
            return .market
        }
        if value.contains("parking") {
            return .other
        }
        if value.contains("park")
            || value.contains("beach")
            || value.contains("marina")
            || value.contains("landmark") {
            return .viewpoint
        }
        return .other
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

import Combine
import CoreLocation
import MapKit

/// A directory outage is not an empty neighbourhood. Results stay usable
/// during partial failures, while the publisher can offer a quiet retry.
nonisolated enum POISearchIssue: Equatable {
    case temporarilyUnavailable
}

nonisolated struct POISearchResult {
    let places: [RatedPOI]
    let issue: POISearchIssue?

    init(places: [RatedPOI], issue: POISearchIssue? = nil) {
        self.places = places
        self.issue = issue
    }
}

/// Search projection for the map. Results may change as the camera moves and
/// must never be used as the source of truth for the top active feed.
protocol POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
    func search(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
    func nearResult(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never>
    func searchResult(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never>
}

extension POIRepository {
    func nearResult(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never> {
        near(coordinate).map { POISearchResult(places: $0) }.eraseToAnyPublisher()
    }

    func searchResult(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<POISearchResult, Never> {
        search(query, near: coordinate).map { POISearchResult(places: $0) }.eraseToAnyPublisher()
    }

    /// Mock and social repositories already own a finite set of places.
    /// Public directory repositories override this with a real provider query.
    func search(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Just([]).eraseToAnyPublisher() }
        return near(coordinate)
            .map { places in
                places.filter { $0.poi.name.localizedStandardContains(trimmed) }
            }
            .eraseToAnyPublisher()
    }
}

/// Public POI activity that belongs in MapTalk's top feed. This mirrors
/// `RealRepository.active(in:)` and is deliberately independent of the
/// device location and the map's current search results.
protocol ActivePOIRepository {
    func active(in region: MKMapRect?) -> AnyPublisher<[RatedPOI], Never>
}

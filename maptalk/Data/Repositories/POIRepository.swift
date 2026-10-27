import Combine
import CoreLocation
import MapKit

/// Search projection for the map. Results may change as the camera moves and
/// must never be used as the source of truth for the top active feed.
protocol POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
    func search(_ query: String, near coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
}

extension POIRepository {
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

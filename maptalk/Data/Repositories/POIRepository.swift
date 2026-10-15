import Combine
import CoreLocation
import MapKit

/// Search projection for the map. Results may change as the camera moves and
/// must never be used as the source of truth for the top active feed.
protocol POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
}

/// Public POI activity that belongs in MapTalk's top feed. This mirrors
/// `RealRepository.active(in:)` and is deliberately independent of the
/// device location and the map's current search results.
protocol ActivePOIRepository {
    func active(in region: MKMapRect?) -> AnyPublisher<[RatedPOI], Never>
}

import Combine
import CoreLocation

protocol POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never>
}

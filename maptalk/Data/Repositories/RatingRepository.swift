import Combine
import MapKit

protocol RatingRepository {
    func recent(in region: MKMapRect?) -> AnyPublisher<[Rating], Never>
}


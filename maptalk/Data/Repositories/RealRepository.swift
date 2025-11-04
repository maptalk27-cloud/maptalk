import Combine
import MapKit

protocol RealRepository {
    func active(in region: MKMapRect?) -> AnyPublisher<[RealPost], Never>
}


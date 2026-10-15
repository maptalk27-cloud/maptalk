import Combine
import CoreLocation
import MapKit

final class InMemoryPOIRepository: POIRepository, ActivePOIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Just(PreviewData.sampleRatedPOIs).eraseToAnyPublisher()
    }

    func active(in region: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> {
        Just(PreviewData.sampleRatedPOIs).eraseToAnyPublisher()
    }
}

import Combine
import CoreLocation

final class InMemoryPOIRepository: POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Just(PreviewData.sampleRatedPOIs).eraseToAnyPublisher()
    }
}

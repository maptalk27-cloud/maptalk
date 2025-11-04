import Combine
import CoreLocation

final class InMemoryPOIRepository: POIRepository {
    func near(_ coordinate: CLLocationCoordinate2D) -> AnyPublisher<[POI], Never> {
        Just(PreviewData.samplePOIs).eraseToAnyPublisher()
    }
}


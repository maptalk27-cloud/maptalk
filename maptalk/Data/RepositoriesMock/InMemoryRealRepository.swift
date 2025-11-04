import Combine
import MapKit

final class InMemoryRealRepository: RealRepository {
    func active(in region: MKMapRect?) -> AnyPublisher<[RealPost], Never> {
        Just(PreviewData.sampleReals).eraseToAnyPublisher()
    }
}


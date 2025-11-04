import Combine
import MapKit

final class InMemoryRatingRepository: RatingRepository {
    func recent(in region: MKMapRect?) -> AnyPublisher<[Rating], Never> {
        Just(PreviewData.sampleRatings).eraseToAnyPublisher()
    }
}


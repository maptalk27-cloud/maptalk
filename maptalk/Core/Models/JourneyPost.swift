import CoreLocation
import Foundation

struct JourneyPost: Identifiable {
    struct Comment: Identifiable {
        let id: UUID
        let userId: UUID
        let text: String
        let createdAt: Date
    }

    let id: UUID
    let userId: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
    let createdAt: Date
    let reels: [RealPost]
    let pois: [RatedPOI]
    let likes: [UUID]
    let comments: [Comment]
}

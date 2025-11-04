import CoreLocation
import Foundation

struct RealPost: Identifiable, Hashable {
    enum Visibility {
        case publicAll
        case friendsOnly
        case anonymous
    }

    let id: UUID
    let userId: UUID
    var center: CLLocationCoordinate2D
    var radiusMeters: CLLocationDistance
    var mediaType: String
    var visibility: Visibility
    var createdAt: Date
    var expiresAt: Date

    static func == (lhs: RealPost, rhs: RealPost) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

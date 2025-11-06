import CoreLocation
import Foundation

struct RealPost: Identifiable, Hashable {
    enum Visibility {
        case publicAll
        case friendsOnly
        case anonymous
    }

    enum Media: Hashable {
        case none
        case photo(URL)
        case video(url: URL, poster: URL?)
        case emoji(String)
    }

    struct Metrics: Hashable {
        var likeCount: Int
        var commentCount: Int
    }

    let id: UUID
    let userId: UUID
    var center: CLLocationCoordinate2D
    var radiusMeters: CLLocationDistance
    var message: String?
    var media: Media
    var metrics: Metrics
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

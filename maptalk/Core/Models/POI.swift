import CoreLocation
import Foundation

struct POI: Identifiable, Hashable {
    let id: UUID
    var name: String
    var coordinate: CLLocationCoordinate2D
    var category: POICategory

    static func == (lhs: POI, rhs: POI) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

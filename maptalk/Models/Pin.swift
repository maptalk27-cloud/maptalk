import MapKit

struct Pin: Identifiable, Hashable, Equatable {
    let id = UUID()
    var title: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: Pin, rhs: Pin) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

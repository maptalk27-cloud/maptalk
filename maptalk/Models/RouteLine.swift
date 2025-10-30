import MapKit

struct RouteLine: Identifiable, Hashable, Equatable {
    let id = UUID()
    var coordinates: [CLLocationCoordinate2D]
    /// Use palette index to keep neon color selection stable.
    var colorIndex: Int

    static func == (lhs: RouteLine, rhs: RouteLine) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

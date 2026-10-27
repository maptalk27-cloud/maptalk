import CoreLocation
import Foundation

/// Directory classification, separate from the app's visual categories. This
/// is supplied by the place directory, never inferred from a name the person types.
nonisolated enum POIDirectoryKind: String, Codable, Sendable {
    case airport
}

nonisolated enum POISelectionPolicy {
    static let nearbyRadius: CLLocationDistance = 150
    static let airportRadius: CLLocationDistance = 2_000

    static func radius(for kind: POIDirectoryKind?) -> CLLocationDistance {
        kind == .airport ? airportRadius : nearbyRadius
    }
}

struct POI: Identifiable, Hashable {
    let id: UUID
    var name: String
    var coordinate: CLLocationCoordinate2D
    var category: POICategory
    var directoryKind: POIDirectoryKind? = nil

    static func == (lhs: POI, rhs: POI) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

import CoreLocation
import Foundation

/// Directory classification, separate from the app's visual categories. This
/// is supplied by the place directory, never inferred from a name the person types.
nonisolated enum POIDirectoryKind: String, Codable, Sendable {
    case airport
}

nonisolated enum POISelectionPolicy {
    static let nearbyRadius: CLLocationDistance = 150
    static let searchRadius: CLLocationDistance = 500

    /// Familiar places can appear without typing a search, but only within
    /// the same current-GPS limit that applies when actually checking in.
    /// Saving a place or somebody else's visit does not qualify.
    static func recommendationRadius(hasOwnCheckIns: Bool) -> CLLocationDistance {
        hasOwnCheckIns ? searchRadius : nearbyRadius
    }

    static func radius(for kind: POIDirectoryKind?) -> CLLocationDistance {
        nearbyRadius
    }

    static func publicationRadius(for kind: POIDirectoryKind?) -> CLLocationDistance {
        searchRadius
    }

    /// Match the API's eligibility calculation exactly at the radius boundary.
    /// Core Location remains the source of fixes, not the map viewport.
    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        guard CLLocationCoordinate2DIsValid(a), CLLocationCoordinate2DIsValid(b) else { return .infinity }
        let radians = Double.pi / 180
        let latitude = (b.latitude - a.latitude) * radians
        let longitude = (b.longitude - a.longitude) * radians
        let haversine = pow(sin(latitude / 2), 2)
            + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(longitude / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, haversine))))
    }

    static func canPublish(at coordinate: CLLocationCoordinate2D, kind: POIDirectoryKind?,
                           from location: CLLocation) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate),
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0 else { return false }
        return distance(from: location.coordinate, to: coordinate) <= publicationRadius(for: kind)
    }
}

/// Display relevance only. Never changes a place's identity, coordinates or
/// check-in eligibility. The picker ranks personal/public history before this
/// venue score; the directory itself has no personal or public visit evidence.
nonisolated enum POIRecommendationPolicy {
    static func distanceBand(_ meters: Double) -> Int {
        guard meters.isFinite, meters >= 0 else { return 100_000 }
        // Metre-level GPS drift should not keep swapping otherwise equal rows.
        return Int(min(100_000, meters / 50))
    }

    static func score(category: POICategory, distanceMeters: Double) -> Int {
        let destination: Int
        switch category {
        // Apple also classifies some major hotels (e.g. Wynn Las Vegas) as
        // landmarks, which map to the app's viewpoint category.
        case .hotel, .airport, .viewpoint: destination = 24
        case .other: destination = 10
        default: destination = 20
        }
        // A main venue gets a small head start among otherwise equal history.
        return destination - 2 * distanceBand(distanceMeters)
    }

    static func nameMatch(_ name: String, query: String) -> Int {
        let query = normalized(query)
        guard !query.isEmpty else { return 0 }
        let name = normalized(name)
        if name == query { return 3 }
        if name.hasPrefix(query) { return 2 }
        if name.contains(query) { return 1 }
        let words = query.split(separator: " ")
        return words.allSatisfy { name.contains($0) } ? 1 : 0
    }

    static func isSupportingFacility(name: String, category: POICategory) -> Bool {
        // Unknown is not synonymous with useless. Preserve restaurants, hotels
        // and legitimate custom venues, including names like "Elevator Cafe".
        guard category == .other else { return false }
        let name = normalized(name)
        let words = name.split(separator: " ").map(String.init)
        let facilities: Set<String> = ["elevator", "elevators", "escalator", "escalators",
            "lift", "lifts", "stairs", "staircase", "stairwell", "entrance", "exit",
            "restroom", "restrooms", "toilet", "toilets"]
        if let last = words.last, facilities.contains(last) {
            // "The Entrance" can be a named destination, not an entrance label.
            if words.count == 2 && words.first == "the" { return false }
            return true
        }
        // Facility numbers/directions, e.g. "Wynn elevator A" or "Entrance 2".
        if words.count >= 2, facilities.contains(words[words.count - 2]), let last = words.last {
            if last.count == 1 || last.allSatisfy(\.isNumber)
                || ["north", "south", "east", "west"].contains(last) { return true }
        }
        let withoutNumber = name.trimmingCharacters(in: .decimalDigits.union(.whitespaces))
        return ["电梯", "電梯", "扶梯", "直梯", "升降机", "升降機", "楼梯", "樓梯",
                "洗手间", "洗手間", "卫生间", "衛生間", "出入口", "入口", "出口"]
            .contains { withoutNumber.hasSuffix($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
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

import CoreLocation

/// Deterministic local framing for a fixed set of browsable stops, not a
/// geographic search. Every member resolves to the same group and zoom tier.
struct MapBrowsingNeighborhood {
    let coordinates: [CLLocationCoordinate2D]
    let span: CLLocationDistance
    private let sourceStops: [CLLocationCoordinate2D]

    private static let duplicateDistance: CLLocationDistance = 25
    private static let maximumDiameter: CLLocationDistance = 3_000
    private static let spanTiers: [CLLocationDistance] = [800, 1_200, 2_000, 3_500, 5_000, 8_000]

    static func resolve(around target: CLLocationCoordinate2D,
                        coordinates: [CLLocationCoordinate2D]) -> MapBrowsingNeighborhood? {
        guard isValid(target) else { return nil }
        let sorted = coordinates.filter(isValid).sorted {
            $0.latitude == $1.latitude ? $0.longitude < $1.longitude : $0.latitude < $1.latitude
        }
        var stops: [CLLocationCoordinate2D] = []
        for coordinate in sorted where !stops.contains(where: {
            distance($0, coordinate) <= duplicateDistance
        }) {
            stops.append(coordinate)
        }
        guard let targetStop = stops.first(where: {
            distance($0, target) <= duplicateDistance
        }) else { return nil }

        var remaining = stops
        while let anchor = remaining.first {
            var group = [anchor]
            var outside: [CLLocationCoordinate2D] = []
            for candidate in remaining.dropFirst() {
                // Require a bounded diameter, not just a nearby neighbor:
                // a chain of stops must never join an entire city together.
                if group.allSatisfy({ distance($0, candidate) <= maximumDiameter }) {
                    group.append(candidate)
                } else {
                    outside.append(candidate)
                }
            }
            if group.contains(where: { sameCoordinate($0, targetStop) }) {
                guard group.count > 1 else { return nil }
                let spacing = group.map { stop in
                    group.filter { !sameCoordinate($0, stop) }
                        .map { distance(stop, $0) }.min() ?? 0
                }.sorted()
                let desiredSpan = spacing[spacing.count / 2] * 2.2
                let span = spanTiers.first { $0 >= desiredSpan } ?? 8_000
                return .init(coordinates: group, span: span, sourceStops: stops)
            }
            remaining = outside
        }
        return nil
    }

    /// Membership follows the same stable duplicate anchor as resolve, rather
    /// than treating every point inside the group's bounding circle as a stop.
    func contains(_ target: CLLocationCoordinate2D) -> Bool {
        guard Self.isValid(target), let stop = sourceStops.first(where: {
            Self.distance($0, target) <= Self.duplicateDistance
        }) else { return false }
        return coordinates.contains { Self.sameCoordinate($0, stop) }
    }

    private static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && CLLocationCoordinate2DIsValid(coordinate)
    }

    private static func sameCoordinate(_ lhs: CLLocationCoordinate2D,
                                       _ rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }

    private static func distance(_ lhs: CLLocationCoordinate2D,
                                 _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}

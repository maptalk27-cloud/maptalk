import CoreLocation
import Foundation
import MapKit

/// Maintains a sliding window of route geometry near the user's current position.
protocol CorridorProviderType: AnyObject {
    /// Loads or clears the active route geometry that downstream components reference.
    func update(route: MKRoute?)

    /// Updates corridor configuration such as window length when matcher presets change.
    func update(windowLength: CLLocationDistance)

    /// Updates the corridor focus based on the latest position to keep nearby geometry indexed.
    func refreshCorridor(around coordinate: CLLocationCoordinate2D)

    /// Returns the closest segment to the provided coordinate, including cached metadata when available.
    func nearestSegment(to coordinate: CLLocationCoordinate2D) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, distance: CLLocationDistance, cumulative: CLLocationDistance)?

    /// Provides the currently indexed corridor portion of the route as a lightweight polyline.
    func currentCorridor() -> [CLLocationCoordinate2D]

    /// Returns segment metadata within the active window for candidate generation.
    func windowSegments() -> [CorridorSegmentMetadata]
}

struct CorridorSegmentMetadata {
    let index: Int
    let startCoordinate: CLLocationCoordinate2D
    let endCoordinate: CLLocationCoordinate2D
    let startPoint: MKMapPoint
    let endPoint: MKMapPoint
    let length: CLLocationDistance
    let cumulativeDistance: CLLocationDistance
    let tangent: CLLocationDirection
    let curvature: Double
    let stepIndex: Int
    let distanceToNextManeuver: CLLocationDistance
}

final class CorridorIndexer: CorridorProviderType {
    private let minimumWindowLength: CLLocationDistance = 100

    private var segments: [CorridorSegmentMetadata] = []
    private var windowLength: CLLocationDistance = MapMatcher.Config.city.corridorWindowLength
    private var windowRange: Range<Int>?
    private var route: MKRoute?

    func update(route: MKRoute?) {
        self.route = route
        segments = Self.prepareSegments(from: route)
        windowRange = nil
    }

    func update(windowLength: CLLocationDistance) {
        self.windowLength = max(minimumWindowLength, windowLength)
        // Window will be recalculated on next refresh call.
    }

    func refreshCorridor(around coordinate: CLLocationCoordinate2D) {
        guard !segments.isEmpty else {
            windowRange = nil
            return
        }

        let point = MKMapPoint(coordinate)
        var bestIndex = effectiveRange()?.lowerBound ?? 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        let searchRange = effectiveRange() ?? segments.indices
        for index in searchRange {
            let segment = segments[index]
            let distance = point.distance(toSegmentFrom: segment.startPoint, to: segment.endPoint)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        // Fallback to global search if the coordinate drifted outside the cached window.
        if bestDistance == .greatestFiniteMagnitude {
            for index in segments.indices {
                let segment = segments[index]
                let distance = point.distance(toSegmentFrom: segment.startPoint, to: segment.endPoint)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
        }

        windowRange = windowRangeCentered(at: bestIndex)
    }

    func nearestSegment(to coordinate: CLLocationCoordinate2D) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, distance: CLLocationDistance, cumulative: CLLocationDistance)? {
        guard !segments.isEmpty else { return nil }

        let point = MKMapPoint(coordinate)
        let searchRange = effectiveRange() ?? segments.indices
        var best: CorridorSegmentMetadata?
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in searchRange {
            let segment = segments[index]
            let distance = point.distance(toSegmentFrom: segment.startPoint, to: segment.endPoint)
            if distance < bestDistance {
                best = segment
                bestDistance = distance
            }
        }

        guard let segment = best else { return nil }
        return (segment.startCoordinate, segment.endCoordinate, bestDistance, segment.cumulativeDistance)
    }

    func currentCorridor() -> [CLLocationCoordinate2D] {
        guard let range = effectiveRange(), !segments.isEmpty else { return [] }

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(range.count + 1)

        let first = segments[range.lowerBound]
        coordinates.append(first.startCoordinate)
        for index in range {
            coordinates.append(segments[index].endCoordinate)
        }
        return coordinates
    }

    func windowSegments() -> [CorridorSegmentMetadata] {
        guard let range = effectiveRange() else {
            return []
        }
        return Array(segments[range])
    }

    private func windowRangeCentered(at index: Int) -> Range<Int> {
        guard segments.indices.contains(index) else {
            return segments.startIndex..<segments.startIndex
        }

        let halfLength = windowLength / 2
        var lower = index
        var accumulatedLower: CLLocationDistance = segments[index].length / 2

        while lower > segments.startIndex, accumulatedLower < halfLength {
            lower -= 1
            accumulatedLower += segments[lower].length
        }

        var upper = index
        var accumulatedUpper: CLLocationDistance = segments[index].length / 2

        while upper < segments.endIndex - 1, accumulatedUpper < halfLength {
            upper += 1
            accumulatedUpper += segments[upper].length
        }

        return lower..<(upper + 1)
    }

    private func effectiveRange() -> Range<Int>? {
        guard let range = windowRange else { return nil }
        let lower = max(range.lowerBound, segments.startIndex)
        let upper = min(range.upperBound, segments.endIndex)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private static func prepareSegments(from route: MKRoute?) -> [CorridorSegmentMetadata] {
        guard let route else { return [] }
        var results: [CorridorSegmentMetadata] = []
        var cumulative: CLLocationDistance = 0

        for (stepIndex, step) in route.steps.enumerated() {
            let coordinates = step.polyline.coordinates
            guard coordinates.count > 1 else { continue }

            var distanceWithinStep: CLLocationDistance = 0
            for i in 0..<(coordinates.count - 1) {
                let startCoord = coordinates[i]
                let endCoord = coordinates[i + 1]
                let startPoint = MKMapPoint(startCoord)
                let endPoint = MKMapPoint(endCoord)
                let length = startPoint.distance(to: endPoint)
                guard length > 0 else { continue }

                let tangent = Self.bearing(from: startCoord, to: endCoord)
                let nextHeading: CLLocationDirection?
                if i < coordinates.count - 2 {
                    nextHeading = Self.bearing(from: endCoord, to: coordinates[i + 2])
                } else if let nextStepCoord = route.steps[safe: stepIndex + 1]?.polyline.coordinates.first {
                    nextHeading = Self.bearing(from: endCoord, to: nextStepCoord)
                } else {
                    nextHeading = nil
                }

                let curvature: Double
                if let nextHeading {
                    curvature = Self.angularDifference(between: tangent, and: nextHeading) / max(length, 1)
                } else {
                    curvature = 0
                }

                let distanceToNextManeuver = max(0, step.distance - distanceWithinStep)
                let metadata = CorridorSegmentMetadata(
                    index: results.count,
                    startCoordinate: startCoord,
                    endCoordinate: endCoord,
                    startPoint: startPoint,
                    endPoint: endPoint,
                    length: length,
                    cumulativeDistance: cumulative,
                    tangent: tangent,
                    curvature: curvature,
                    stepIndex: stepIndex,
                    distanceToNextManeuver: distanceToNextManeuver
                )

                results.append(metadata)
                cumulative += length
                distanceWithinStep += length
            }
        }

        return results
    }

    private static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = start.latitude.toRadians
        let lon1 = start.longitude.toRadians
        let lat2 = end.latitude.toRadians
        let lon2 = end.longitude.toRadians

        let deltaLon = lon2 - lon1
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearingRadians = atan2(y, x)
        let bearingDegrees = bearingRadians.toDegrees
        let normalized = (bearingDegrees + 360).truncatingRemainder(dividingBy: 360)
        return normalized
    }

    private static func angularDifference(between angleA: CLLocationDirection, and angleB: CLLocationDirection) -> CLLocationDirection {
        let diff = abs(angleA - angleB).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension CLLocationDegrees {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
}

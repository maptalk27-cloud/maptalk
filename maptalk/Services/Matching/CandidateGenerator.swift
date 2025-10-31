import CoreLocation
import Foundation
import MapKit

/// Projects the current location onto nearby route segments, producing multiple candidate positions.
protocol CandidateGeneratorType: AnyObject {
    /// Returns ordered candidates representing potential on-route positions for the supplied location.
    func generateCandidates(for location: CLLocation,
                            segments: [CorridorSegmentMetadata],
                            config: MapMatcher.Config) -> [MapMatchingCandidate]
}

final class CandidateGenerator: CandidateGeneratorType {
    func generateCandidates(for location: CLLocation,
                            segments: [CorridorSegmentMetadata],
                            config: MapMatcher.Config) -> [MapMatchingCandidate] {
        guard !segments.isEmpty else { return [] }

        let observationHeading = location.course >= 0 ? location.course : nil
        let mapPoint = MKMapPoint(location.coordinate)

        var candidates: [MapMatchingCandidate] = []
        candidates.reserveCapacity(min(config.maxCandidates, segments.count))

        for segment in segments {
            let projection = Self.project(point: mapPoint, onto: segment)
            let lateralDistance = mapPoint.distance(to: projection.projectedPoint)
            let progress = segment.cumulativeDistance + projection.progressAlongSegment

            let headingDifference: CLLocationDirection
            if let observationHeading {
                headingDifference = Self.angularDifference(between: observationHeading, and: segment.tangent)
            } else {
                headingDifference = 0
            }

            let candidate = MapMatchingCandidate(
                coordinate: projection.projectedPoint.coordinate,
                distanceFromRoute: lateralDistance,
                progressAlongRoute: progress,
                heading: segment.tangent,
                segmentIndex: segment.index,
                stepIndex: segment.stepIndex,
                curvature: segment.curvature,
                distanceToNextManeuver: segment.distanceToNextManeuver,
                headingDifference: headingDifference,
                isNearFork: segment.distanceToNextManeuver <= config.nearForkRadius,
                score: nil
            )
            candidates.append(candidate)
        }

        candidates.sort { lhs, rhs in
            if lhs.distanceFromRoute != rhs.distanceFromRoute {
                return lhs.distanceFromRoute < rhs.distanceFromRoute
            }
            return lhs.headingDifference < rhs.headingDifference
        }

        if candidates.count > config.maxCandidates {
            candidates = Array(candidates.prefix(config.maxCandidates))
        }
        return candidates
    }

    private static func project(point: MKMapPoint,
                                onto segment: CorridorSegmentMetadata) -> (projectedPoint: MKMapPoint, progressAlongSegment: CLLocationDistance) {
        let start = segment.startPoint
        let end = segment.endPoint
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy

        guard denominator > 0 else {
            return (start, 0)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        let projected = MKMapPoint(x: start.x + t * dx, y: start.y + t * dy)
        let progress = start.distance(to: projected)
        return (projected, progress)
    }

    private static func angularDifference(between angleA: CLLocationDirection,
                                          and angleB: CLLocationDirection) -> CLLocationDirection {
        let diff = abs(angleA - angleB).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
}

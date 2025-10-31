import CoreLocation
import Foundation

/// Represents a snapped location along the route, paired with metadata for UI and analytics.
struct EnhancedLocation {
    /// The matched position on the route.
    let coordinate: CLLocationCoordinate2D

    /// Smoothed heading aligned with the driving corridor, when available.
    let heading: CLLocationDirection?

    /// Forward speed in meters per second, derived from raw sensors or progress integration.
    let speed: CLLocationSpeed?

    /// Timestamp associated with the upstream raw sensor sample.
    let timestamp: Date

    /// Confidence in the snap, normalized between 0 (unknown) and 1 (high certainty).
    let confidence: Double

    /// Back-reference to the candidate used to generate this enhanced location.
    let candidate: MapMatchingCandidate
}

/// Intermediate representation of a map-matching hypothesis used throughout the pipeline.
struct MapMatchingCandidate {
    /// Candidate position projected onto the route geometry.
    let coordinate: CLLocationCoordinate2D

    /// Distance in meters from the raw location to this candidate projection.
    let distanceFromRoute: CLLocationDistance

    /// Accumulated distance along the polyline where this candidate resides.
    var progressAlongRoute: CLLocationDistance

    /// Estimated heading for the candidate, useful for transition scoring.
    let heading: CLLocationDirection?

    /// Identifier for the underlying route segment.
    let segmentIndex: Int

    /// Route step index associated with this segment.
    let stepIndex: Int

    /// Estimated curvature at the candidate location.
    let curvature: Double

    /// Remaining distance to the next maneuver in meters.
    let distanceToNextManeuver: CLLocationDistance

    /// Absolute heading difference between the observation and the segment tangent.
    let headingDifference: CLLocationDirection

    /// Indicates whether the candidate lies within the near-fork radius.
    let isNearFork: Bool

    /// Optional score assigned by the scoring engine (higher is better).
    var score: Double? = nil

    /// Emission component of the score, for diagnostics.
    var emissionScore: Double? = nil

    /// Transition component of the score, for diagnostics.
    var transitionScore: Double? = nil

    /// Returns a copy of the candidate with updated progress along the route.
    func withProgress(_ newProgress: CLLocationDistance) -> MapMatchingCandidate {
        MapMatchingCandidate(
            coordinate: coordinate,
            distanceFromRoute: distanceFromRoute,
            progressAlongRoute: newProgress,
            heading: heading,
            segmentIndex: segmentIndex,
            stepIndex: stepIndex,
            curvature: curvature,
            distanceToNextManeuver: distanceToNextManeuver,
            headingDifference: headingDifference,
            isNearFork: isNearFork,
            score: score,
            emissionScore: emissionScore,
            transitionScore: transitionScore
        )
    }

    /// Returns a copy of the candidate with updated score components.
    func withScores(score: Double?, emission: Double?, transition: Double?) -> MapMatchingCandidate {
        MapMatchingCandidate(
            coordinate: coordinate,
            distanceFromRoute: distanceFromRoute,
            progressAlongRoute: progressAlongRoute,
            heading: heading,
            segmentIndex: segmentIndex,
            stepIndex: stepIndex,
            curvature: curvature,
            distanceToNextManeuver: distanceToNextManeuver,
            headingDifference: headingDifference,
            isNearFork: isNearFork,
            score: score,
            emissionScore: emission,
            transitionScore: transition
        )
    }
}

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
    let progressAlongRoute: CLLocationDistance

    /// Estimated heading for the candidate, useful for transition scoring.
    let heading: CLLocationDirection?

    /// Optional score assigned by the scoring engine (higher is better).
    var score: Double?
}

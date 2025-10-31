import CoreLocation
import Foundation

/// Aggregates metrics describing how far the user has advanced along the active route.
struct RouteProgress {
    /// Total distance traveled along the route in meters.
    let distanceTraveled: CLLocationDistance

    /// Remaining distance along the route in meters.
    let distanceRemaining: CLLocationDistance

    /// Fraction of the route completed, clamped between 0 and 1.
    let fractionTraveled: Double

    /// Index of the current route step, if segmentation is available.
    let stepIndex: Int
}

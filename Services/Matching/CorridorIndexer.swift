import CoreLocation
import Foundation
import MapKit

/// Maintains a sliding window of route geometry near the user's current position.
protocol CorridorProviderType: AnyObject {
    /// Loads or clears the active route geometry that downstream components reference.
    func update(route: MKRoute?)

    /// Updates the corridor focus based on the latest position to keep nearby geometry indexed.
    func refreshCorridor(around coordinate: CLLocationCoordinate2D)

    /// Returns the closest segment to the provided coordinate, including cached metadata when available.
    func nearestSegment(to coordinate: CLLocationCoordinate2D) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, distance: CLLocationDistance, cumulative: CLLocationDistance)?

    /// Provides the currently indexed corridor portion of the route as a lightweight polyline.
    func currentCorridor() -> [CLLocationCoordinate2D]
}

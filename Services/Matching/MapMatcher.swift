import Combine
import CoreLocation
import Foundation
import MapKit

/// Actor that coordinates the map-matching pipeline and publishes enhanced locations.
protocol MapMatcherType: AnyObject {
    /// Emits snapped location updates with confidence metadata for UI consumption.
    var enhancedLocations: AnyPublisher<EnhancedLocation, Never> { get }

    /// Configures the matcher for a new route, resetting any cached corridor or scoring state.
    func update(route: MKRoute?)

    /// Accepts a normalized location from the feed and triggers the matching pipeline.
    func ingest(normalizedLocation: CLLocation)

    /// Clears cached state such as the previous candidate or dead-reckoning flags.
    func reset()
}

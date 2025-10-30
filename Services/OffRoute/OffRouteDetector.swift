import Combine
import Foundation
import MapKit

/// Determines on-route versus off-route status using snapped positions and heading deviation.
protocol OffRouteDetectorType: AnyObject {
    /// Emits transition events whenever the on/off-route classification changes.
    var events: AnyPublisher<OffRouteEvent, Never> { get }

    /// Updates tolerances or cached route geometry when a new route is selected.
    func update(route: MKRoute?)

    /// Evaluates the latest enhanced location to detect potential off-route conditions.
    func ingest(enhancedLocation: EnhancedLocation)

    /// Resets internal hysteresis and time-based thresholds.
    func reset()
}

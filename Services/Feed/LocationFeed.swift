import Combine
import CoreLocation
import Foundation

/// Actor responsible for normalizing incoming `CLLocation` updates before they enter the matching pipeline.
protocol LocationFeedType: AnyObject {
    /// Emits sanitized locations at the cadence the matcher expects (≥ 5 Hz once filtered).
    var output: AnyPublisher<CLLocation, Never> { get }

    /// Pushes a newly received raw location into the feed for filtering or throttling.
    func push(rawLocation: CLLocation)

    /// Resets internal filters and state, typically after a new route is selected.
    func reset()
}

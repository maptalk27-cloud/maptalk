import CoreLocation
import Foundation

/// Describes a transition in on/off-route classification for the current navigation session.
struct OffRouteEvent {
    /// Indicates whether the user is currently off the planned route.
    let isOffRoute: Bool

    /// Timestamp of the classification update.
    let timestamp: Date

    /// Lateral deviation in meters when the state changed, if available.
    let lateralDeviation: CLLocationDistance?

    /// Absolute heading difference in degrees compared to the route direction.
    let headingDeviation: CLLocationDirection?
}

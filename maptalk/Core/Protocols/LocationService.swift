import Combine
import CoreLocation

protocol LocationService: AnyObject {
    var authorization: CurrentValueSubject<CLAuthorizationStatus, Never> { get }
    var location: CurrentValueSubject<CLLocation?, Never> { get }
    /// A visible map needs coarse movement, not continuously precise GPS.
    func setBrowsingActive(_ active: Bool)
    /// Only the visible publisher needs continuous, precise device fixes.
    func setPreciseUpdatesActive(_ active: Bool)
    /// Request permission and one fresh fix (for example the Locate button).
    func requestWhenInUse()
    func stop()
}

extension LocationService {
    func setBrowsingActive(_ active: Bool) {}
    func setPreciseUpdatesActive(_ active: Bool) {}
    func stop() {}
}


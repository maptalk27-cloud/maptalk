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

actor LocationFeed: LocationFeedType {
    private let subject = PassthroughSubject<CLLocation, Never>()
    private var lastLocation: CLLocation?
    private var lastTimestamp: Date?

    private let targetInterval: TimeInterval = 1.0 / 5.0
    private let accuracyCeiling: CLLocationAccuracy = 65

    nonisolated var output: AnyPublisher<CLLocation, Never> {
        subject.eraseToAnyPublisher()
    }

    func push(rawLocation: CLLocation) {
        guard shouldAccept(rawLocation) else { return }

        if let lastTimestamp,
           rawLocation.timestamp.timeIntervalSince(lastTimestamp) < targetInterval * 0.4 {
            // Drop extremely high-frequency updates that only add jitter.
            return
        }

        let normalized = normalize(location: rawLocation)
        subject.send(normalized)
        lastLocation = normalized
        lastTimestamp = normalized.timestamp
    }

    func reset() {
        lastLocation = nil
        lastTimestamp = nil
    }

    private func shouldAccept(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        if location.horizontalAccuracy > accuracyCeiling * 4 {
            return false
        }
        if let last = lastLocation {
            let delta = location.timestamp.timeIntervalSince(last.timestamp)
            if delta < 0 {
                return false
            }
        }
        return true
    }

    private func normalize(location: CLLocation) -> CLLocation {
        guard location.horizontalAccuracy > accuracyCeiling else { return location }
        return CLLocation(coordinate: location.coordinate,
                          altitude: location.altitude,
                          horizontalAccuracy: accuracyCeiling,
                          verticalAccuracy: location.verticalAccuracy,
                          course: location.course,
                          speed: location.speed,
                          timestamp: location.timestamp)
    }
}

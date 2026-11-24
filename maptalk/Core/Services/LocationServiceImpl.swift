import Combine
import CoreLocation
import UIKit

enum LocationUpdateMode: Equatable {
    case off, browsing, oneShot, precise

    static func resolve(browsing: Bool, precise: Bool, oneShot: Bool) -> Self {
        if precise { return .precise }
        if oneShot { return .oneShot }
        return browsing ? .browsing : .off
    }

    var accuracy: CLLocationAccuracy {
        self == .browsing ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
    }

    var distanceFilter: CLLocationDistance {
        self == .browsing ? 25 : kCLDistanceFilterNone
    }
}

final class LocationServiceImpl: NSObject, LocationService, CLLocationManagerDelegate {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)
    private let manager = CLLocationManager()
    private var browsingActive = false
    private var preciseUpdatesActive = false
    private var wantsOneFix = false
    private var updateMode = LocationUpdateMode.off
    private var isStopped = false

    override init() {
        super.init()
        manager.delegate = self
        authorization.send(manager.authorizationStatus)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // Retire an earlier build's app-wide visit registration. This version
        // only reads the current fix and never collects a location history.
        manager.stopMonitoringVisits()
    }

    func requestWhenInUse() {
        guard !isStopped else { return }
        // Retain an explicit consumer's request even if another screen is
        // currently precise and is about to release its continuous demand.
        wantsOneFix = true
        requestAuthorizationAndApplyDemand()
    }

    func setBrowsingActive(_ active: Bool) {
        guard !isStopped else { return }
        browsingActive = active
        requestAuthorizationAndApplyDemand()
    }

    func setPreciseUpdatesActive(_ active: Bool) {
        guard !isStopped else { return }
        preciseUpdatesActive = active
        requestAuthorizationAndApplyDemand()
    }

    private func requestAuthorizationAndApplyDemand() {
        switch manager.authorizationStatus {
        case .notDetermined:
            if browsingActive || preciseUpdatesActive || wantsOneFix {
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            applyDemand()
        case .restricted, .denied:
            break
        @unknown default:
            break
        }
    }

    /// Retire an account's service before replacing its environment. Delayed
    /// delegates from the old manager must not resume recording after sign-out.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        browsingActive = false
        preciseUpdatesActive = false
        wantsOneFix = false
        updateMode = .off
        manager.stopUpdatingLocation()
        manager.stopMonitoringVisits()
        manager.delegate = nil
        NotificationCenter.default.removeObserver(self)
        location.send(nil)
    }

    /// Visits registration is app-wide and may survive process termination.
    /// Use only once authentication has established that no session is active.
    static func stopBackgroundVisits() {
        CLLocationManager().stopMonitoringVisits()
    }

    private func applyDemand() {
        let authorized = manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse
        let mode: LocationUpdateMode = !isStopped && authorized
            && UIApplication.shared.applicationState != .background
            ? .resolve(browsing: browsingActive, precise: preciseUpdatesActive, oneShot: wantsOneFix)
            : .off
        guard mode != updateMode else { return }
        // requestLocation is ignored while standard updates are running. Stop
        // the previous mode once, then let its success/error finish the one-shot.
        manager.stopUpdatingLocation()
        updateMode = mode
        guard mode != .off else { return }
        manager.desiredAccuracy = mode.accuracy
        manager.distanceFilter = mode.distanceFilter
        if mode == .oneShot {
            manager.requestLocation()
        } else {
            manager.startUpdatingLocation()
        }
    }

    @objc private func didEnterBackground() {
        wantsOneFix = false
        updateMode = .off
        manager.stopUpdatingLocation()
    }

    @objc private func didBecomeActive() {
        guard !isStopped else { return }
        applyDemand()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard !isStopped else { return }
        authorization.send(status)
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            applyDemand()
        } else if status == .denied || status == .restricted {
            wantsOneFix = false
            updateMode = .off
            manager.stopUpdatingLocation()
            location.send(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isStopped, updateMode != .off else { return }
        location.send(locations.last)
        finishRequestedFixIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed explicit locate must not leave GPS in precise mode. The
        // publisher can retry and the browsing map can keep its last viewport.
        finishRequestedFixIfNeeded()
    }

    private func finishRequestedFixIfNeeded() {
        guard wantsOneFix else { return }
        wantsOneFix = false
        applyDemand()
    }
}

import Combine
import CoreLocation

final class LocationServiceImpl: NSObject, LocationService, CLLocationManagerDelegate {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorization.send(status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location.send(locations.last)
    }
}


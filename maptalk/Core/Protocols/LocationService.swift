import Combine
import CoreLocation

protocol LocationService: AnyObject {
    var authorization: CurrentValueSubject<CLAuthorizationStatus, Never> { get }
    var location: CurrentValueSubject<CLLocation?, Never> { get }
    func requestWhenInUse()
}


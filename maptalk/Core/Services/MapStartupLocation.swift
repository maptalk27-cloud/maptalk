import CoreLocation
import MapKit

/// A startup camera must come from the device, never from demo content.
/// Cached fixes older than a few minutes can be from another city, so keep
/// the existing viewport while waiting for a fresh, accuracy-bearing sample.
enum MapStartupLocation {
    static func usable(_ location: CLLocation?, now: Date = .now) -> CLLocation? {
        guard let location,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSince(now)) <= 5 * 60 else {
            return nil
        }
        return location
    }

    static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
        )
    }

    /// No city is implied before the person has shared a usable location.
    static var worldRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 300)
        )
    }
}

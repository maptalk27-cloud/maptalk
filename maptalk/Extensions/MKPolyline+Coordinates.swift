import MapKit

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }

        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

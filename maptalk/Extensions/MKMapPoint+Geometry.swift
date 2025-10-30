import MapKit

extension MKMapPoint {
    func distance(toSegmentFrom a: MKMapPoint, to b: MKMapPoint) -> CLLocationDistance {
        let dx = b.x - a.x
        let dy = b.y - a.y

        if dx == 0 && dy == 0 {
            return distance(to: a)
        }

        let projection = max(
            0,
            min(
                1,
                ((x - a.x) * dx + (y - a.y) * dy) / (dx * dx + dy * dy)
            )
        )
        let projectedPoint = MKMapPoint(x: a.x + projection * dx, y: a.y + projection * dy)
        return distance(to: projectedPoint)
    }
}

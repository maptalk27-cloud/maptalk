import Combine
import CoreLocation
import Foundation
import MapKit

@MainActor
final class NavigationModel: ObservableObject {
    enum Mode {
        case automobile
        case walking
        case transit
    }

    @Published var destination: CLLocationCoordinate2D?
    @Published var route: MKRoute?
    @Published var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var etaText: String?
    @Published var distanceText: String?
    @Published var isComputing = false

    var mode: Mode = .automobile
    var offRouteToleranceMeters: CLLocationDistance = 28
    var maxProgressDropMeters: CLLocationDistance = 22
    var minRerouteInterval: TimeInterval = 5
    var headingSmoothingFactor: Double = 0.2

    private var lastRerouteAt: Date?
    private var lastSmoothedHeading: CLLocationDirection?
    private var lastSmoothedCoordinate: CLLocationCoordinate2D?
    private var lastProgressAlongRoute: CLLocationDistance = 0
    var positionSmoothingFactor: Double = 0.12

    func setDestination(_ coord: CLLocationCoordinate2D) {
        destination = coord
    }

    func planRoute(from start: CLLocationCoordinate2D,
                   to end: CLLocationCoordinate2D,
                   mode: Mode = .automobile) {
        isComputing = true
        self.mode = mode
        destination = end

        let sourceItem = MKMapItem(placemark: MKPlacemark(coordinate: start))
        let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: end))

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.requestsAlternateRoutes = false

        switch mode {
        case .automobile:
            request.transportType = .automobile
        case .walking:
            request.transportType = .walking
        case .transit:
            request.transportType = .transit
        }

        MKDirections(request: request).calculate { [weak self] response, error in
            guard let self else { return }
            Task { @MainActor in
                self.isComputing = false
                guard error == nil, let bestRoute = response?.routes.first else {
                    self.route = nil
                    self.routeCoordinates = []
                    self.etaText = nil
                    self.distanceText = nil
                    self.resetFilters(resetHeading: true)
                    return
                }

                self.route = bestRoute
                self.routeCoordinates = bestRoute.polyline.coordinates
                let minutes = Int(ceil(bestRoute.expectedTravelTime / 60))
                self.etaText = "\(minutes) min"
                let miles = bestRoute.distance / 1_609.344
                self.distanceText = String(format: "%.1f mi", miles)
                self.resetFilters()
            }
        }
    }

    func considerReroute(current: CLLocationCoordinate2D) {
        guard let destination,
              let route,
              !isComputing else { return }

        if let lastRerouteAt,
           Date().timeIntervalSince(lastRerouteAt) < minRerouteInterval {
            return
        }

        let metrics = offRouteMetrics(for: current, route: route)
        if metrics.lateralDistance > offRouteToleranceMeters ||
            metrics.progressDelta < -maxProgressDropMeters {
            lastRerouteAt = Date()
            planRoute(from: current, to: destination, mode: mode)
        }
    }

    func headingAlongRoute(from coordinate: CLLocationCoordinate2D) -> CLLocationDirection? {
        guard let segment = nearestRouteSegment(to: coordinate) else { return nil }
        return bearing(from: segment.start, to: segment.end)
    }

    func smoothedHeading(for location: CLLocation) -> CLLocationDirection? {
        let rawHeading: CLLocationDirection?
        if location.course >= 0 {
            rawHeading = location.course
        } else {
            rawHeading = headingAlongRoute(from: location.coordinate)
        }

        guard let heading = rawHeading else {
            return lastSmoothedHeading
        }

        if let last = lastSmoothedHeading {
            let blended = Self.interpolateAngle(from: last, to: heading, factor: headingSmoothingFactor)
            lastSmoothedHeading = blended
            return blended
        } else {
            lastSmoothedHeading = heading
            return heading
        }
    }

    func smoothedCoordinate(after coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if let last = lastSmoothedCoordinate {
            let lat = last.latitude + (coordinate.latitude - last.latitude) * positionSmoothingFactor
            let lon = last.longitude + (coordinate.longitude - last.longitude) * positionSmoothingFactor
            let smoothed = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lastSmoothedCoordinate = smoothed
            return smoothed
        } else {
            lastSmoothedCoordinate = coordinate
            return coordinate
        }
    }

    func resetFilters(resetHeading: Bool = false) {
        if resetHeading {
            lastSmoothedHeading = nil
        }
        lastSmoothedCoordinate = nil
        lastProgressAlongRoute = 0
    }

    private func distanceToCurrentRouteMeters(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        nearestRouteSegment(to: coordinate)?.distance ?? .greatestFiniteMagnitude
    }

    private func offRouteMetrics(for coordinate: CLLocationCoordinate2D, route: MKRoute) -> (lateralDistance: CLLocationDistance, progressDelta: CLLocationDistance) {
        guard let segment = nearestRouteSegment(to: coordinate) else {
            return (.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        }

        let lateralDistance = segment.distance

        let projected = projectPoint(coordinate, onto: segment)
        let startPoint = MKMapPoint(segment.start)
        let projectedPoint = MKMapPoint(projected)
        let segmentLength = startPoint.distance(to: MKMapPoint(segment.end))
        let progressOnSegment = min(segmentLength, startPoint.distance(to: projectedPoint))
        let progress = segment.cumulative + progressOnSegment
        let delta = progress - lastProgressAlongRoute
        lastProgressAlongRoute = progress

        return (lateralDistance, delta)
    }

    private func projectPoint(_ coordinate: CLLocationCoordinate2D, onto segment: (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, distance: CLLocationDistance, cumulative: CLLocationDistance)) -> CLLocationCoordinate2D {
        let startPoint = MKMapPoint(segment.start)
        let endPoint = MKMapPoint(segment.end)
        let targetPoint = MKMapPoint(coordinate)

        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let denom = dx * dx + dy * dy
        guard denom > 0 else { return segment.start }

        let t = max(0, min(1, ((targetPoint.x - startPoint.x) * dx + (targetPoint.y - startPoint.y) * dy) / denom))
        let projected = MKMapPoint(x: startPoint.x + t * dx, y: startPoint.y + t * dy)
        return projected.coordinate
    }

    private func nearestRouteSegment(to coordinate: CLLocationCoordinate2D) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, distance: CLLocationDistance, cumulative: CLLocationDistance)? {
        guard routeCoordinates.count > 1 else { return nil }
        let point = MKMapPoint(coordinate)
        var shortestDistance = CLLocationDistance.greatestFiniteMagnitude
        var closestStart = routeCoordinates[0]
        var closestEnd = routeCoordinates[1]
        var bestCumulative: CLLocationDistance = 0

        var previousPoint = MKMapPoint(routeCoordinates[0])
        var cumulative: CLLocationDistance = 0
        for coord in routeCoordinates.dropFirst() {
            let nextPoint = MKMapPoint(coord)
            let distance = point.distance(toSegmentFrom: previousPoint, to: nextPoint)
            if distance < shortestDistance {
                shortestDistance = distance
                closestStart = previousPoint.coordinate
                closestEnd = nextPoint.coordinate
                bestCumulative = cumulative
            }
            cumulative += previousPoint.distance(to: nextPoint)
            previousPoint = nextPoint
        }
        return (closestStart, closestEnd, shortestDistance, bestCumulative)
    }

    private func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = start.latitude.toRadians
        let lon1 = start.longitude.toRadians
        let lat2 = end.latitude.toRadians
        let lon2 = end.longitude.toRadians

        let deltaLon = lon2 - lon1
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearingRadians = atan2(y, x)
        let bearingDegrees = bearingRadians.toDegrees
        return (bearingDegrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angularDifference(between angleA: CLLocationDirection, and angleB: CLLocationDirection) -> CLLocationDirection {
        let diff = abs(angleA - angleB).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    private static func interpolateAngle(from start: CLLocationDirection, to end: CLLocationDirection, factor: Double) -> CLLocationDirection {
        let startRad = start * .pi / 180
        let endRad = end * .pi / 180
        let x = (1 - factor) * cos(startRad) + factor * cos(endRad)
        let y = (1 - factor) * sin(startRad) + factor * sin(endRad)
        var result = atan2(y, x) * 180 / .pi
        if result < 0 { result += 360 }
        return result
    }
}

private extension CLLocationDegrees {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
}

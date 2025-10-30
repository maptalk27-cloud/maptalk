import Combine
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
    var offRouteToleranceMeters: CLLocationDistance = 45
    var minRerouteInterval: TimeInterval = 8

    private var lastRerouteAt: Date?

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
                    return
                }

                self.route = bestRoute
                self.routeCoordinates = bestRoute.polyline.coordinates
                let minutes = Int(ceil(bestRoute.expectedTravelTime / 60))
                self.etaText = "\(minutes) min"
                let miles = bestRoute.distance / 1_609.344
                self.distanceText = String(format: "%.1f mi", miles)
            }
        }
    }

    func considerReroute(current: CLLocationCoordinate2D) {
        guard let destination,
              route != nil,
              !isComputing else { return }

        if let lastRerouteAt, Date().timeIntervalSince(lastRerouteAt) < minRerouteInterval {
            return
        }

        let distance = distanceToCurrentRouteMeters(from: current)
        if distance > offRouteToleranceMeters {
            lastRerouteAt = Date()
            planRoute(from: current, to: destination, mode: mode)
        }
    }

    private func distanceToCurrentRouteMeters(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        guard routeCoordinates.count > 1 else { return .greatestFiniteMagnitude }
        let point = MKMapPoint(coordinate)
        var shortestDistance = CLLocationDistance.greatestFiniteMagnitude

        var previous = MKMapPoint(routeCoordinates[0])
        for coordinate in routeCoordinates.dropFirst() {
            let next = MKMapPoint(coordinate)
            let distance = point.distance(toSegmentFrom: previous, to: next)
            if distance < shortestDistance {
                shortestDistance = distance
            }
            previous = next
        }
        return shortestDistance
    }
}

import CoreLocation
import Foundation

nonisolated enum MapDirectionsProvider: String, CaseIterable, Identifiable, Sendable {
    case appleMaps
    case googleMaps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMaps: "Apple Maps"
        case .googleMaps: "Google Maps"
        }
    }
}

/// A validated destination whose display name stays inside MapTalk.
nonisolated struct MapDirectionsDestination: Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double

    init?(name: String, coordinate: CLLocationCoordinate2D) {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90.0...90.0).contains(coordinate.latitude),
              (-180.0...180.0).contains(coordinate.longitude) else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "Selected location" : trimmedName
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    /// Builds a route-planning URL, leaving current location and travel mode to the map app.
    /// Apple unified URLs are supported on iOS 18.4+ (MapTalk targets iOS 26+):
    /// https://developer.apple.com/documentation/mapkit/unified-map-urls
    /// Google universal URLs open the app when installed and otherwise the browser:
    /// https://developers.google.com/maps/documentation/urls/get-started
    func url(for provider: MapDirectionsProvider) -> URL {
        // Double's String conversion is locale-independent and preserves precision.
        let coordinate = String(latitude) + "," + String(longitude)
        var components = URLComponents()
        components.scheme = "https"
        switch provider {
        case .appleMaps:
            components.host = "maps.apple.com"
            components.path = "/directions"
            components.queryItems = [URLQueryItem(name: "destination", value: coordinate)]
        case .googleMaps:
            components.host = "www.google.com"
            components.path = "/maps/dir/"
            components.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: coordinate)
            ]
        }
        // Encode the coordinate separator as required by Google's Maps URL guide.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: ",", with: "%2C")

        // Only fixed URL components and validated finite numbers reach this point.
        return components.url!
    }
}

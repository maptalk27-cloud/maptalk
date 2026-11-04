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

/// The selected place's name and coordinate, never a post caption or the viewer's location.
nonisolated struct MapDirectionsDestination: Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    private let searchName: String?

    init?(name: String, coordinate: CLLocationCoordinate2D) {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90.0...90.0).contains(coordinate.latitude),
              (-180.0...180.0).contains(coordinate.longitude) else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "Selected location" : trimmedName
        self.searchName = trimmedName.isEmpty ? nil : trimmedName
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    /// Opens the place, not a route. Existing POIs don't retain provider place IDs:
    /// Apple gets a named place card at the exact coordinate; Google gets a place
    /// search with a coordinate hint and can show candidates for ambiguous names.
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
            components.path = "/place"
            components.queryItems = [
                URLQueryItem(name: "coordinate", value: coordinate),
                URLQueryItem(name: "name", value: name)
            ]
        case .googleMaps:
            components.host = "www.google.com"
            components.path = "/maps/search/"
            components.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "query", value: searchName.map { "\($0), \(coordinate)" } ?? coordinate)
            ]
        }
        // Maps uses form-style queries: a literal '+' in a place name must not
        // become a space. Google also requires encoded coordinate separators.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: ",", with: "%2C")

        // Maps URLs have a 2,048-character limit. An unusually long custom name
        // must still open its actual location, rather than produce a broken URL.
        if (components.url?.absoluteString.utf8.count ?? 0) > 2_048 {
            components.queryItems = components.queryItems?.map {
                switch $0.name {
                case "query": URLQueryItem(name: "query", value: coordinate)
                case "name": URLQueryItem(name: "name", value: "Selected location")
                default: $0
                }
            }
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
                .replacingOccurrences(of: ",", with: "%2C")
        }

        // Names are encoded query values, never URL hosts, paths or parameters.
        return components.url!
    }
}

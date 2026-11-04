import CoreLocation
import Foundation
import Testing
@testable import maptalk

struct MapDirectionsDestinationTests {
    @Test
    func providersHaveStableIdentityAndDisplayNames() {
        #expect(MapDirectionsProvider.allCases == [.appleMaps, .googleMaps])
        #expect(MapDirectionsProvider.allCases.map(\.id) == ["appleMaps", "googleMaps"])
        #expect(MapDirectionsProvider.allCases.map(\.title) == ["Apple Maps", "Google Maps"])
    }

    @Test
    func coordinateBoundsAreInclusiveAndZeroIsAValidLocation() throws {
        for (latitude, longitude) in [
            (0.0, 0.0), (-90.0, -180.0), (-90.0, 180.0),
            (90.0, -180.0), (90.0, 180.0), (-33.8568, 151.2153)
        ] {
            let destination = try #require(MapDirectionsDestination(
                name: "Place", coordinate: .init(latitude: latitude, longitude: longitude)
            ))
            #expect(destination.latitude == latitude)
            #expect(destination.longitude == longitude)
        }
    }

    @Test
    func invalidCoordinatesAreRejectedWithoutClampingOrInventingADestination() {
        for latitude in [Double.nan, .infinity, -.infinity, 90.0.nextUp, (-90.0).nextDown] {
            #expect(MapDirectionsDestination(
                name: "Place", coordinate: .init(latitude: latitude, longitude: 0)
            ) == nil)
        }
        for longitude in [Double.nan, .infinity, -.infinity, 180.0.nextUp, (-180.0).nextDown] {
            #expect(MapDirectionsDestination(
                name: "Place", coordinate: .init(latitude: 0, longitude: longitude)
            ) == nil)
        }
    }

    @Test
    func displayNameIsTrimmedWithAFallbackForBlankNames() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)
        let named = try #require(MapDirectionsDestination(name: " \n 東京駅 🌏 \t", coordinate: coordinate))
        #expect(named.name == "東京駅 🌏")
        for blank in ["", " \t\n\r", "\u{2003}\u{00a0}"] {
            let destination = try #require(MapDirectionsDestination(name: blank, coordinate: coordinate))
            #expect(destination.name == "Selected location")
        }
        #expect(named == MapDirectionsDestination(name: "東京駅 🌏", coordinate: coordinate))
    }

    @Test
    func providerURLsUseOnlyTheExpectedHTTPSHostPathAndQuery() throws {
        let destination = try #require(MapDirectionsDestination(
            name: "Honolulu", coordinate: .init(latitude: 21.3069, longitude: -157.8583)
        ))
        for provider in MapDirectionsProvider.allCases {
            let url = destination.url(for: provider)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "https")
            #expect(components.host == (provider == .appleMaps ? "maps.apple.com" : "www.google.com"))
            #expect(components.path == (provider == .appleMaps ? "/place" : "/maps/search/"))
            #expect(components.user == nil)
            #expect(components.password == nil)
            #expect(components.port == nil)
            #expect(components.fragment == nil)

            let expectedItems = provider == .appleMaps
                ? [URLQueryItem(name: "coordinate", value: "21.3069,-157.8583"),
                   URLQueryItem(name: "name", value: "Honolulu")]
                : [URLQueryItem(name: "api", value: "1"),
                   URLQueryItem(name: "query", value: "Honolulu, 21.3069,-157.8583")]
            #expect(components.queryItems == expectedItems)
            #expect(components.percentEncodedQuery?.contains("%2C") == true)
            let names = Set(components.queryItems?.map(\.name) ?? [])
            #expect(names.isDisjoint(with: ["destination", "source", "origin", "mode", "travelmode", "start", "dir_action"]))
        }
    }

    @Test
    func coordinatesRemainLatitudeFirstAndRetainRoundTripPrecision() throws {
        let latitude = 37.12345678901234
        let longitude = -122.98765432109876
        let destination = try #require(MapDirectionsDestination(
            name: "Precise pin", coordinate: .init(latitude: latitude, longitude: longitude)
        ))
        for provider in MapDirectionsProvider.allCases {
            let components = try #require(URLComponents(url: destination.url(for: provider), resolvingAgainstBaseURL: false))
            let queryKey = provider == .appleMaps ? "coordinate" : "query"
            let query = try #require(components.queryItems?.first { $0.name == queryKey }?.value)
            let value = provider == .appleMaps ? query : String(query.dropFirst("Precise pin, ".count))
            #expect(value == "37.12345678901234,-122.98765432109876")
            let values = value.split(separator: ",")
            try #require(values.count == 2)
            #expect(Double(values[0]) == latitude)
            #expect(Double(values[1]) == longitude)
        }
    }

    @Test
    func placeNamesRemainEncodedValuesAndCannotInjectRoutingParameters() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945)
        for name in [
            "東京駅 🌏", "Café & Hotel", "C++ Café + Bakery", "A&B?origin=0,0#fragment",
            "https://example.invalid/?destination=0,0&travelmode=driving", "\napi=2&start=0"
        ] {
            let destination = try #require(MapDirectionsDestination(name: name, coordinate: coordinate))
            for provider in MapDirectionsProvider.allCases {
                let components = try #require(URLComponents(url: destination.url(for: provider), resolvingAgainstBaseURL: false))
                #expect(components.host == (provider == .appleMaps ? "maps.apple.com" : "www.google.com"))
                #expect(components.fragment == nil)
                #expect(components.percentEncodedQuery?.contains("+") == false)
                if name.contains("+") {
                    #expect(components.percentEncodedQuery?.contains("%2B") == true)
                }
                let names = Set(components.queryItems?.map(\.name) ?? [])
                #expect(names == (provider == .appleMaps ? ["coordinate", "name"] : ["api", "query"]))
                let query = components.queryItems?.first { $0.name == (provider == .appleMaps ? "name" : "query") }?.value
                #expect(query == (provider == .appleMaps ? destination.name : "\(destination.name), 48.8584,2.2945"))
                if provider == .googleMaps {
                    #expect(components.queryItems?.first { $0.name == "api" }?.value == "1")
                }
            }
        }
    }

    @Test
    func blankOrOverlongNamesStillOpenTheSelectedCoordinateWithoutDirections() throws {
        for name in [" \n\t", String(repeating: "東京 🌏", count: 1_000)] {
            let destination = try #require(MapDirectionsDestination(
                name: name, coordinate: .init(latitude: 35.6812, longitude: 139.7671)
            ))
            for provider in MapDirectionsProvider.allCases {
                let url = destination.url(for: provider)
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(url.absoluteString.utf8.count <= 2_048)
                let coordinateKey = provider == .appleMaps ? "coordinate" : "query"
                #expect(components.queryItems?.first { $0.name == coordinateKey }?.value == "35.6812,139.7671")
                #expect(components.queryItems?.contains { $0.name == "destination" } == false)
            }
        }
    }
}

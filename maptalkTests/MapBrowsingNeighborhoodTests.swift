import CoreLocation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct MapBrowsingNeighborhoodTests {
    @Test
    func everyStopInAPatchHasTheSameSpanAndMembership() throws {
        let stops = [0.0, 400, 900, 1_400].map(coordinate)
        let first = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: stops))
        #expect(first.span == 1_200)
        for target in stops {
            let neighborhood = try #require(MapBrowsingNeighborhood.resolve(around: target, coordinates: stops))
            #expect(neighborhood.span == first.span)
            #expect(neighborhood.coordinates.map(\.longitude) == first.coordinates.map(\.longitude))
            #expect(stops.allSatisfy(neighborhood.contains))
        }
    }

    @Test
    func sourceOrderDoesNotChooseTheNeighborhood() throws {
        let stops = [0.0, 400, 900, 1_400, 20_000].map(coordinate)
        let baseline = try #require(MapBrowsingNeighborhood.resolve(around: stops[2], coordinates: stops))
        for source in [Array(stops.reversed()), [stops[3], stops[1], stops[4], stops[0], stops[2]]] {
            let reordered = try #require(MapBrowsingNeighborhood.resolve(around: stops[2], coordinates: source))
            #expect(reordered.span == baseline.span)
            #expect(reordered.coordinates.map(\.longitude) == baseline.coordinates.map(\.longitude))
        }
    }

    @Test
    func duplicateVisitsAndSmallCoordinateJitterDoNotIncreaseDensity() throws {
        let stops = [0.0, 450, 900].map(coordinate)
        let baseline = try #require(MapBrowsingNeighborhood.resolve(around: stops[1], coordinates: stops))
        let repeated = stops + Array(repeating: stops[1], count: 40) + [coordinate(458)]
        let neighborhood = try #require(MapBrowsingNeighborhood.resolve(around: coordinate(458), coordinates: repeated))
        #expect(neighborhood.coordinates.count == 3)
        #expect(neighborhood.span == baseline.span)
        #expect(neighborhood.contains(coordinate(458)))
    }

    @Test
    func remoteOutliersDoNotChangeLocalZoomOrMembership() throws {
        let stops = [0.0, 200, 450].map(coordinate)
        let baseline = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: stops))
        let remote = [coordinate(-20_000), coordinate(50_000)]
        let neighborhood = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: remote + stops))
        #expect(neighborhood.span == baseline.span)
        #expect(neighborhood.coordinates.map(\.longitude) == baseline.coordinates.map(\.longitude))
        #expect(remote.allSatisfy { !neighborhood.contains($0) })
    }

    @Test
    func isolatedOrRepeatedSingleStopDoesNotCreateANeighborhood() {
        let target = coordinate(0)
        #expect(MapBrowsingNeighborhood.resolve(around: target, coordinates: []) == nil)
        #expect(MapBrowsingNeighborhood.resolve(around: target, coordinates: [target, coordinate(5_000)]) == nil)
        #expect(MapBrowsingNeighborhood.resolve(around: target, coordinates: Array(repeating: target, count: 30)) == nil)
        #expect(MapBrowsingNeighborhood.resolve(around: target, coordinates: [target, coordinate(20)]) == nil)
    }

    @Test
    func nearbyChainCannotJoinAWholeCity() throws {
        let stops = [0.0, 1_700, 3_400, 5_100].map(coordinate)
        let west = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: stops))
        let east = try #require(MapBrowsingNeighborhood.resolve(around: stops[2], coordinates: stops))
        #expect(west.coordinates.count == 2)
        #expect(east.coordinates.count == 2)
        #expect(west.contains(stops[1]))
        #expect(!west.contains(stops[2]))
        #expect(east.contains(stops[3]))
        #expect(!east.contains(stops[1]))
        let reverse = try #require(MapBrowsingNeighborhood.resolve(around: stops[1], coordinates: Array(stops.reversed())))
        #expect(reverse.coordinates.map(\.longitude) == west.coordinates.map(\.longitude))
    }

    @Test
    func spacingChoosesOnlyTheDocumentedZoomTiers() throws {
        let cases: [(Double, Double)] = [
            (200, 800), (400, 1_200), (700, 2_000),
            (1_200, 3_500), (2_000, 5_000), (2_800, 8_000)
        ]
        for (spacing, expectedSpan) in cases {
            let stops = [coordinate(0), coordinate(spacing)]
            let neighborhood = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: stops))
            #expect(neighborhood.span == expectedSpan)
        }
    }

    @Test
    func controllerCacheRespectsChangedBrowsingScope() throws {
        let controller = MapFlightController()
        let target = MKCoordinateRegion(center: coordinate(0),
                                         latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        let close = [coordinate(0), coordinate(200)]
        let wide = [coordinate(0), coordinate(2_000)]
        let initial = try #require(controller.neighborhoodRegion(for: target, coordinates: close))
        // Canceling a flight does not invalidate geography; changing the
        // active folder/filter must invalidate it even at the same target.
        controller.cancelActiveTransition()
        let reused = try #require(controller.neighborhoodRegion(for: target, coordinates: close))
        #expect(initial.span.longitudeDelta == reused.span.longitudeDelta)
        let changed = try #require(controller.neighborhoodRegion(for: target, coordinates: wide))
        #expect(changed.span.longitudeDelta > initial.span.longitudeDelta * 5)
        #expect(controller.neighborhoodRegion(for: target, coordinates: [coordinate(0)]) == nil)
        #expect(controller.neighborhoodRegion(for: target, coordinates: nil) == nil)
    }

    @Test
    func invalidCoordinatesAndUnknownTargetsAreRejected() throws {
        let stops = [0.0, 200, 450].map(coordinate)
        let invalid: [CLLocationCoordinate2D] = [
            .init(latitude: 91, longitude: 0), .init(latitude: 0, longitude: 181),
            .init(latitude: .nan, longitude: 0), .init(latitude: 0, longitude: .infinity)
        ]
        let neighborhood = try #require(MapBrowsingNeighborhood.resolve(around: stops[0], coordinates: invalid + stops))
        #expect(neighborhood.coordinates.count == stops.count)
        for target in invalid {
            #expect(MapBrowsingNeighborhood.resolve(around: target, coordinates: stops) == nil)
            #expect(!neighborhood.contains(target))
        }
        #expect(MapBrowsingNeighborhood.resolve(around: coordinate(1_500), coordinates: stops) == nil)
        #expect(!neighborhood.contains(coordinate(1_500)))
    }

    private func coordinate(_ eastMeters: Double) -> CLLocationCoordinate2D {
        .init(latitude: 0, longitude: eastMeters / 111_319.49079327358)
    }
}

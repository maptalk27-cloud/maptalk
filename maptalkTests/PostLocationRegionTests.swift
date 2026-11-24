import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct PostLocationRegionTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let seattle = CLLocationCoordinate2D(latitude: 47.606, longitude: -122.332)
    private let hawaii = CLLocationCoordinate2D(latitude: 21.3, longitude: -157.85)

    @Test
    func manyNearbyVisitsBecomeOneRegionWithStableOrderAndIdentity() {
        let points = (0..<1_000).map { index in
            CLLocationCoordinate2D(latitude: seattle.latitude + Double(index % 20) * 0.001,
                                   longitude: seattle.longitude + Double(index / 20) * 0.001)
        } + [hawaii, hawaii]
        let forward = MapTalkPostLocationRegions.make(coordinates: points)
        let reverse = MapTalkPostLocationRegions.make(coordinates: Array(points.reversed()))
        #expect(forward.count == 2)
        #expect(forward.map(\.id) == reverse.map(\.id))
        #expect(forward.allSatisfy { $0.fallbackTitle.hasPrefix("Region · ") })
        #expect(forward.allSatisfy { $0.mapRegion.span.latitudeDelta < 2 })
    }

    @Test
    func nearbyChainsDoNotExpandIntoAnEntireCoast() {
        let regions = MapTalkPostLocationRegions.make(coordinates: [
            .init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.4),
            .init(latitude: 0, longitude: 0.8)
        ])
        #expect(MapTalkPostLocationRegions.groupingDistance == 50_000)
        #expect(regions.count == 2)
        #expect(PostLocationPolicy.radius == 5_000)
    }

    @Test
    func regionsCrossDateLineAndPolesWithoutWorldSpanningDateLineViewport() throws {
        let dateline = try #require(MapTalkPostLocationRegions.make(coordinates: [
            .init(latitude: 0, longitude: 179.9), .init(latitude: 0, longitude: -179.9),
            .init(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0)
        ]).only)
        #expect(abs(dateline.mapRegion.center.longitude) > 179)
        #expect(dateline.mapRegion.span.longitudeDelta < 1)
        let pole = MapTalkPostLocationRegions.make(coordinates: [
            .init(latitude: 89.99, longitude: 0), .init(latitude: 89.99, longitude: 180)
        ])
        #expect(pole.count == 1)
        #expect(pole.first?.mapRegion.span.longitudeDelta == 360)
    }

    @Test
    func regionsIncludeOwnedPostPointsButCannotExpandEligibility() {
        let ownVisit = place(at: seattle, userID: owner)
        let foreignVisit = place(at: .init(latitude: 51.5, longitude: -0.1), userID: other)
        let ownPost = RealPost(id: UUID(), userId: owner, center: hawaii, radiusMeters: 220,
            message: nil, attachments: [], likes: [], comments: [], visibility: .privateOnly,
            createdAt: .distantPast, expiresAt: .distantPast)
        let library = MapTalkPostLocationLibrary(ownPosts: [ownPost], visitedPlaces: [ownVisit, foreignVisit],
                                                currentUserID: owner)
        #expect(library.regions.count == 2)
        #expect(library.coverage.areas.count == 1)
        #expect(!library.coverage.contains(hawaii, currentLocation: nil))
        #expect(library.coverage.contains(seattle, currentLocation: nil))
        #expect(!library.regions.contains { $0.coordinate.latitude == foreignVisit.poi.coordinate.latitude })
    }

    @Test
    func regionNameLookupsAreSerializedDeduplicatedAndCached() async throws {
        let regions = MapTalkPostLocationRegions.make(coordinates: [seattle, hawaii])
        var calls = 0
        var active = 0
        var maximumActive = 0
        let resolver = PostLocationRegionNameResolver(spacing: .zero, defaults: nil) { coordinate in
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            await Task.yield()
            active -= 1
            return coordinate.latitude > 30 ? "Seattle, WA" : "Honolulu, HI"
        }
        let first = try #require(regions.first)
        let second = try #require(regions.last)
        #expect(resolver.title(for: first) == first.fallbackTitle)
        let one = resolver.resolve(first)
        let duplicate = resolver.resolve(first)
        let two = resolver.resolve(second)
        await one.value
        await duplicate.value
        await two.value
        await resolver.resolve(first).value
        #expect(calls == 2)
        #expect(maximumActive == 1)
        #expect(resolver.title(for: first) == "Honolulu, HI")
        #expect(resolver.title(for: second) == "Seattle, WA")
    }

    @Test
    func failedRegionNamingRetainsHonestFallbackWithoutRepeatedRequests() async throws {
        let region = try #require(MapTalkPostLocationRegions.make(coordinates: [seattle]).first)
        var calls = 0
        let resolver = PostLocationRegionNameResolver(spacing: .zero, defaults: nil) { _ in
            calls += 1
            return nil
        }
        await resolver.resolve(region).value
        await resolver.resolve(region).value
        #expect(calls == 1)
        #expect(resolver.title(for: region) == region.fallbackTitle)
    }

    private func place(at coordinate: CLLocationCoordinate2D, userID: UUID) -> RatedPOI {
        RatedPOI(poi: .init(id: UUID(), name: "A visit", coordinate: coordinate, category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: [.init(userId: userID)], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: [], isFavoritedByCurrentUser: false, favoritesCount: 0)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

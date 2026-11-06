import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@MainActor
struct MyMapFlightControllerTests {
    @Test
    func highlightDestinationClearsOnCancellationAndDirectNavigation() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MyMapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: 47.6)
        let target = region(latitude: 47.9)
        var camera = MapCameraPosition.region(origin)
        let binding = Binding(get: { camera }, set: { camera = $0 })
        var settled: MKCoordinateRegion?

        #expect(controller.pendingLandingRegion == nil)
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, cameraPosition: binding, onRegionUpdate: { settled = $0 })
        let pending = try #require(controller.pendingLandingRegion)
        #expect(abs(pending.center.latitude - target.center.latitude) < 0.000_001)
        #expect(settled == nil)

        controller.cancelActiveTransition()
        #expect(controller.pendingLandingRegion == nil)
        let direct = region(latitude: 47.62)
        controller.handleRegionChange(currentRegion: origin, targetRegion: direct,
            cause: .initial, cameraPosition: binding, onRegionUpdate: { settled = $0 })
        #expect(controller.pendingLandingRegion == nil)
        #expect(abs(try #require(settled).center.latitude - direct.center.latitude) < 0.000_001)
        #expect(abs(try #require(camera.region).center.latitude - direct.center.latitude) < 0.000_001)
    }

    @Test
    func finishedFlightDoesNotOverrideHighlightsNextSavedViewport() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MyMapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: 47.6)
        let target = region(latitude: 47.9)
        var camera = MapCameraPosition.region(origin)
        let binding = Binding(get: { camera }, set: { camera = $0 })
        var settled: MKCoordinateRegion?
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, cameraPosition: binding, onRegionUpdate: { settled = $0 })
        let pending = try #require(controller.pendingLandingRegion)

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while settled == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let landing = try #require(settled)
        #expect(abs(landing.center.latitude - pending.center.latitude) < 0.000_001)
        #expect(abs(landing.span.latitudeDelta - pending.span.latitudeDelta) < 0.000_001)
        #expect(controller.pendingLandingRegion == nil)
    }

    private func region(latitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: -122.3),
            latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }
}

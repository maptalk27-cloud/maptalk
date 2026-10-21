import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct StartupLocationTests {
    @Test
    func realMapUsesKnownDeviceLocationBeforeItAppears() {
        let location = StartupTestLocationService()
        let current = CLLocation(latitude: 37.3318, longitude: -122.0312)
        location.location.send(current)
        let model = MapTalkViewModel(environment: environment(location: location))

        expectCenter(model.region, equals: current.coordinate)
        #expect(model.region.span.latitudeDelta == 0.15)
    }

    @Test
    func delayedFirstFixCentersRealMapOnceWithoutLocateButton() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        let firstFix = CLLocation(latitude: 37.3318, longitude: -122.0312)
        #expect(model.region.span.latitudeDelta >= 90)
        #expect(model.region.center.latitude != 47.61)

        model.onAppear()
        #expect(location.requestCount == 1)
        location.location.send(firstFix)
        await drainLocationDelivery()

        expectCenter(model.region, equals: firstFix.coordinate)
        #expect(model.region.span.latitudeDelta == 0.15)
        location.location.send(CLLocation(latitude: 34.0522, longitude: -118.2437))
        await drainLocationDelivery()
        expectCenter(model.region, equals: firstFix.coordinate)

        model.onAppear()
        await drainLocationDelivery()
        expectCenter(model.region, equals: firstFix.coordinate)
    }

    @Test
    func browsingBeforeTheFirstFixCancelsAutomaticFocus() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        model.onAppear()
        let before = model.region
        model.cancelPendingLocationFocus()
        let browsed = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        model.rememberVisibleRegion(browsed)
        location.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        await drainLocationDelivery()

        // Camera updates are model.region publications. Recording the visible
        // viewport must not publish a jump, even when the app reappears.
        expectCenter(model.region, equals: before.center)
        model.onAppear()
        await drainLocationDelivery()
        expectCenter(model.region, equals: before.center)

        model.centerOnUser()
        expectCenter(model.region, equals: location.location.value!.coordinate)
        #expect(model.region.span.latitudeDelta == browsed.span.latitudeDelta)
    }

    @Test
    func selectingAStoryBeforeGPSKeepsItsDestination() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        model.onAppear()
        let story = PreviewData.sampleReals[0]
        model.focus(on: story)
        location.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        await drainLocationDelivery()
        expectCenter(model.region, equals: story.center)
    }

    @Test
    func staleAndInvalidFixesDoNotConsumeStartupFocus() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        let initial = model.region
        model.onAppear()
        location.location.send(fix(accuracy: -1))
        await drainLocationDelivery()
        expectCenter(model.region, equals: initial.center)
        location.location.send(fix(timestamp: Date().addingTimeInterval(-3_600)))
        await drainLocationDelivery()
        expectCenter(model.region, equals: initial.center)
        location.location.send(fix())
        await drainLocationDelivery()
        expectCenter(model.region, equals: fix().coordinate)
    }

    @Test
    func deniedLocationDoesNotSelectDemoCityAndGrantCanCompleteStartup() async {
        let location = StartupTestLocationService()
        location.authorization.send(.denied)
        let model = MapTalkViewModel(environment: environment(location: location))
        model.onAppear()
        await drainLocationDelivery()
        #expect(model.region.center.latitude != 47.61)
        location.authorization.send(.authorizedWhenInUse)
        location.location.send(fix())
        await drainLocationDelivery()
        expectCenter(model.region, equals: fix().coordinate)
    }

    @Test
    func mockMapRetainsItsAuthoredStartingCamera() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location, mock: true))
        let initial = model.region
        model.onAppear()
        location.location.send(fix())
        await drainLocationDelivery()
        expectCenter(model.region, equals: initial.center)
        #expect(initial.center.latitude == 47.61)
    }

    @Test
    func startupFixValidationRejectsInvalidCoordinatesAndNonfiniteAccuracy() {
        let invalidCoordinate = CLLocation(coordinate: .init(latitude: 100, longitude: 0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: .now)
        #expect(MapStartupLocation.usable(invalidCoordinate) == nil)
        #expect(MapStartupLocation.usable(fix(accuracy: .infinity)) == nil)
        #expect(MapStartupLocation.usable(fix(accuracy: .nan)) == nil)
        #expect(MapStartupLocation.usable(fix()) != nil)
    }

    private func environment(location: StartupTestLocationService, mock: Bool = false) -> AppEnvironment {
        AppEnvironment(build: .init(configuration: .debug, featureFlags: mock ? .mock : []),
            location: location, notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(), poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(), myMapArchive: MyMapArchiveStore())
    }

    private func fix(accuracy: CLLocationAccuracy = 5, timestamp: Date = .now) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 37.3318, longitude: -122.0312),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: timestamp)
    }

    private func expectCenter(_ region: MKCoordinateRegion, equals coordinate: CLLocationCoordinate2D) {
        #expect(abs(region.center.latitude - coordinate.latitude) < 0.000_001)
        #expect(abs(region.center.longitude - coordinate.longitude) < 0.000_001)
    }

    private func drainLocationDelivery() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class StartupTestLocationService: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)
    private(set) var requestCount = 0
    func requestWhenInUse() { requestCount += 1 }
}

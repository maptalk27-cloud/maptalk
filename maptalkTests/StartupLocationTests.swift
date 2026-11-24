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
        #expect(location.browsingDemands == [true])
        #expect(location.requestCount == 0)
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

    @Test
    func locationDemandOnlyUsesContinuousPrecisionWhileComposing() {
        #expect(LocationUpdateMode.resolve(browsing: false, precise: false, oneShot: false) == .off)
        #expect(LocationUpdateMode.resolve(browsing: true, precise: false, oneShot: false) == .browsing)
        #expect(LocationUpdateMode.resolve(browsing: true, precise: false, oneShot: true) == .oneShot)
        #expect(LocationUpdateMode.resolve(browsing: false, precise: false, oneShot: true) == .oneShot)
        #expect(LocationUpdateMode.resolve(browsing: true, precise: true, oneShot: true) == .precise)
        #expect(LocationUpdateMode.browsing.accuracy == kCLLocationAccuracyHundredMeters)
        #expect(LocationUpdateMode.browsing.distanceFilter == 25)
        #expect(LocationUpdateMode.precise.accuracy == kCLLocationAccuracyBest)
        #expect(LocationUpdateMode.precise.distanceFilter == kCLDistanceFilterNone)
        #expect(LocationUpdateMode.oneShot.accuracy == kCLLocationAccuracyBest)
    }

    @Test
    func explicitFixDemandSurvivesPreviousMapReleasingContinuousUpdates() {
        // The new screen's explicit request may arrive before the old screen's
        // disappear callbacks. Removing either continuous flag retains it.
        #expect(LocationUpdateMode.resolve(browsing: true, precise: true, oneShot: true) == .precise)
        #expect(LocationUpdateMode.resolve(browsing: true, precise: false, oneShot: true) == .oneShot)
        #expect(LocationUpdateMode.resolve(browsing: false, precise: false, oneShot: true) == .oneShot)
        #expect(LocationUpdateMode.resolve(browsing: false, precise: false, oneShot: false) == .off)
    }

    @Test
    func leavingHomeStopsLocationDemandAndReenteringRestoresOnlyVisibleNeeds() async {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        model.onAppear()
        model.setPublishingLocationActive(true)
        #expect(location.browsingDemands.last == true)
        #expect(location.preciseDemands.last == true)

        model.setMapActivity(false)
        #expect(location.browsingDemands.last == false)
        #expect(location.preciseDemands.last == false)
        location.location.send(fix())
        await drainLocationDelivery()
        #expect(model.liveLocation == nil, "An inactive map must not observe location-driven work")

        model.setPublishingLocationActive(false)
        model.setMapActivity(true)
        await drainLocationDelivery()
        #expect(location.browsingDemands.last == true)
        #expect(location.preciseDemands.last == false)
        #expect(model.liveLocation != nil)
        #expect(location.requestCount == 0, "Tab switches must not request high-accuracy one-shots")
    }

    @Test
    func stationaryJitterDoesNotRepublishMapButPublicationKeepsExactRawFix() async throws {
        let location = StartupTestLocationService()
        let first = fix()
        location.location.send(first)
        let model = MapTalkViewModel(environment: environment(location: location))
        await drainLocationDelivery()
        var displayUpdates = 0
        let observation = model.$userCoordinate.dropFirst().sink { _ in displayUpdates += 1 }
        defer { observation.cancel() }
        let jitter = CLLocation(
            coordinate: .init(latitude: first.coordinate.latitude + 0.000_01,
                              longitude: first.coordinate.longitude),
            altitude: 0, horizontalAccuracy: 4, verticalAccuracy: -1, timestamp: .now)
        location.location.send(jitter)
        await drainLocationDelivery()

        #expect(displayUpdates == 0)
        #expect(model.userCoordinate?.latitude == first.coordinate.latitude)
        let raw = try #require(model.publishableLiveLocation)
        #expect(raw.coordinate.latitude == jitter.coordinate.latitude)
        #expect(raw.horizontalAccuracy == jitter.horizontalAccuracy)
        #expect(raw.timestamp == jitter.timestamp)

        location.location.send(CLLocation(coordinate: .init(latitude: first.coordinate.latitude + 0.001,
                                                             longitude: first.coordinate.longitude),
                                          altitude: 0, horizontalAccuracy: 4, verticalAccuracy: -1, timestamp: .now))
        await drainLocationDelivery()
        #expect(displayUpdates == 1)
    }

    @Test
    func pausedGPSCacheCannotRemainPublishableIndefinitely() {
        let location = StartupTestLocationService()
        let model = MapTalkViewModel(environment: environment(location: location))
        location.location.send(fix(timestamp: .now.addingTimeInterval(-301)))
        #expect(model.publishableLiveLocation == nil)
        location.location.send(fix(accuracy: .infinity))
        #expect(model.publishableLiveLocation == nil)
        let current = fix()
        location.location.send(current)
        #expect(model.publishableLiveLocation === current,
                "Publication should read the raw current fix without waiting for UI delivery")
    }

    @Test
    func explicitLocateRequestsOneFreshFixEvenWhenCameraCanUseCache() {
        let location = StartupTestLocationService()
        location.location.send(fix())
        let model = MapTalkViewModel(environment: environment(location: location))
        model.centerOnUser()
        #expect(location.requestCount == 1)
        expectCenter(model.region, equals: fix().coordinate)
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
    private(set) var browsingDemands: [Bool] = []
    private(set) var preciseDemands: [Bool] = []
    func setBrowsingActive(_ active: Bool) { browsingDemands.append(active) }
    func setPreciseUpdatesActive(_ active: Bool) { preciseDemands.append(active) }
    func requestWhenInUse() { requestCount += 1 }
}

import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

struct MyMapStartupLocationTests {
    @Test
    @MainActor
    func emptyArchiveUsesAnAvailableCurrentLocation() {
        let service = MyMapStartupLocationService()
        let fix = CLLocation(latitude: 37.3318, longitude: -122.0312)
        service.location.send(fix)
        let model = makeModel(location: service)

        #expect(model.mapRegion.center.latitude == fix.coordinate.latitude)
        #expect(model.mapRegion.center.longitude == fix.coordinate.longitude)
        #expect(model.mapRegion.span.latitudeDelta == 0.15)
    }

    @Test
    @MainActor
    func emptyArchiveWaitsAtWorldThenCentersOnlyOnce() {
        let service = MyMapStartupLocationService()
        let model = makeModel(location: service)

        #expect(model.mapRegion.center.latitude == 0)
        #expect(model.mapRegion.center.longitude == 0)
        #expect(model.mapRegion.span.longitudeDelta == 300)

        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        service.location.send(CLLocation(latitude: 34.0522, longitude: -118.2437))

        #expect(model.mapRegion.center.latitude == 37.3318)
        #expect(model.mapRegion.center.longitude == -122.0312)
    }

    @Test
    @MainActor
    func emptyArchiveIgnoresStaleLocationUntilFreshFixArrives() {
        let service = MyMapStartupLocationService()
        service.location.send(CLLocation(
            coordinate: .init(latitude: 47.61, longitude: -122.33),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: .now.addingTimeInterval(-600)
        ))
        let model = makeModel(location: service)

        #expect(model.mapRegion.center.latitude == 0)
        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        #expect(model.mapRegion.center.latitude == 37.3318)
    }

    @Test
    @MainActor
    func manualNavigationCancelsDelayedEmptyArchiveCentering() {
        let service = MyMapStartupLocationService()
        let model = makeModel(location: service)
        model.cancelInitialEmptyMapLocation()

        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        model.refresh()

        #expect(model.mapRegion.center.latitude == 0)
        #expect(model.mapRegion.center.longitude == 0)
    }

    @Test
    @MainActor
    func journalContentTakesPriorityAndDeletingItDoesNotRecenter() {
        let service = MyMapStartupLocationService()
        let archive = MyMapArchiveStore(currentUserID: UUID(), startsEmpty: true)
        let model = makeModel(location: service, archive: archive)
        let reel = RealPost(
            id: UUID(),
            userId: archive.currentUserID,
            center: .init(latitude: 34.0522, longitude: -118.2437),
            radiusMeters: 80,
            message: "A saved memory",
            attachments: [],
            likes: [],
            comments: [],
            visibility: .privateOnly,
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(86_400)
        )
        archive.replaceServerRecords(pois: [], reels: [reel])
        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))

        #expect(model.mapRegion.center.latitude == reel.center.latitude)
        #expect(model.mapRegion.center.longitude == reel.center.longitude)

        archive.replaceServerRecords(pois: [], reels: [])
        service.location.send(CLLocation(latitude: 40.7128, longitude: -74.0060))

        #expect(model.mapRegion.center.latitude == reel.center.latitude)
        #expect(model.mapRegion.center.longitude == reel.center.longitude)
    }

    @Test
    @MainActor
    func mockArchiveKeepsItsExistingPreviewFallback() {
        let service = MyMapStartupLocationService()
        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        let model = makeModel(location: service, isMock: true)

        #expect(model.mapRegion.center.latitude == 47.61)
        #expect(model.mapRegion.center.longitude == -122.33)
    }

    @MainActor
    private func makeModel(
        location: MyMapStartupLocationService,
        archive: MyMapArchiveStore? = nil,
        isMock: Bool = false
    ) -> UserMapViewModel {
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: isMock ? .mock : []),
            location: location,
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: archive ?? MyMapArchiveStore(currentUserID: UUID(), startsEmpty: true)
        )
        return UserMapViewModel(environment: environment, context: .me, dataScope: .privateArchive)
    }
}

private final class MyMapStartupLocationService: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.authorizedWhenInUse)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)

    func requestWhenInUse() {}
}

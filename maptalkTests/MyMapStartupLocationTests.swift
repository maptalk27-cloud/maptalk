import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

struct MyMapStartupLocationTests {
    @Test
    @MainActor
    func emptyArchiveRequestsOnlyOneFixWhenItBecomesVisible() {
        let service = MyMapStartupLocationService()
        let model = makeModel(location: service)
        #expect(service.requestCount == 0, "Constructing an offscreen archive must not activate GPS")
        model.requestInitialEmptyMapLocationIfNeeded()
        #expect(service.requestCount == 1)
        service.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        model.requestInitialEmptyMapLocationIfNeeded()
        #expect(service.requestCount == 1, "Once centered, reopening the archive needs no GPS")
    }

    @Test
    @MainActor
    func emptyArchiveWithCacheOrManualNavigationDoesNotRequestGPS() {
        let cachedService = MyMapStartupLocationService()
        cachedService.location.send(CLLocation(latitude: 37.3318, longitude: -122.0312))
        let cached = makeModel(location: cachedService)
        cached.requestInitialEmptyMapLocationIfNeeded()
        #expect(cachedService.requestCount == 0)

        let browsedService = MyMapStartupLocationService()
        let browsed = makeModel(location: browsedService)
        browsed.cancelInitialEmptyMapLocation()
        browsed.requestInitialEmptyMapLocationIfNeeded()
        #expect(browsedService.requestCount == 0)
    }

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

    @Test
    @MainActor
    func serverRecordsAndBubbleHydrationCommitOneCompleteSynchronousSnapshot() {
        let archive = MyMapArchiveStore(currentUserID: UUID(), startsEmpty: true)
        var reel = RealPost(id: UUID(), userId: archive.currentUserID,
            center: .init(latitude: 34, longitude: -118), radiusMeters: 80,
            message: "Original", attachments: [], likes: [], comments: [],
            visibility: .privateOnly, createdAt: .now, expiresAt: .distantFuture)
        archive.replaceServerRecords(pois: [], reels: [reel])
        let model = makeModel(location: MyMapStartupLocationService(), archive: archive)
        #expect(model.reels.first?.message == "Original", "Initial data is synchronous, not debounced")
        var refreshes = 0
        var committedBubbleCounts: [Int] = []
        let modelSubscription = model.$summary.dropFirst().sink { _ in refreshes += 1 }
        let archiveSubscription = archive.privateSnapshots.dropFirst().sink {
            committedBubbleCounts.append($0.bubbles.count)
        }
        defer { modelSubscription.cancel(); archiveSubscription.cancel() }
        let photo = URL(fileURLWithPath: "/tmp/hydrated-memory.jpg")
        reel.message = "Edited"
        reel.attachments = [.init(kind: .photo(photo))]
        let bubble = JourneyPost(id: UUID(), userId: archive.currentUserID, title: "Frozen memory", content: "",
            coordinate: reel.center, createdAt: .now, orderedMemberReferences: [.reel(reel.id)],
            reels: [reel], pois: [], likes: [], comments: [])
        archive.withSnapshotUpdate {
            archive.replaceServerRecords(pois: [], reels: [reel])
            archive.replaceServerBubbles(privateBubbles: [bubble], publicBubbles: [])
        }
        #expect(refreshes == 1)
        #expect(committedBubbleCounts == [1], "No record-only intermediate archive reaches MyMap")
        #expect(model.reels.first?.message == "Edited")
        #expect(model.reels.first?.attachments.first?.kind == .photo(photo))
        #expect(model.journeyCatalog.first?.id == bubble.id)

        archive.removeFromPrivateArchive(.reel(reel.id))
        #expect(refreshes == 2, "Deleting a record and its folder membership is one update")
        #expect(model.reels.isEmpty)
        #expect(model.journeyCatalog.first?.id == bubble.id, "Deleting a source never rewrites a Bubble snapshot")
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

    private(set) var requestCount = 0
    func requestWhenInUse() { requestCount += 1 }
}

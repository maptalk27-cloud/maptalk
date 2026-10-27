import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct MapTalkHistoryProjectionTests {
    private let hour: TimeInterval = 3_600

    @Test
    func quietMarkersDoNotRenderUnderLocateOrPublishControls() {
        let controls = CGRect(x: 328, y: 588, width: 54, height: 186)
        #expect(FriendFootprintScreenOcclusionPolicy.isCoveredByControls(
            projectedPoint: CGPoint(x: 335.7, y: 633.7), controlsFrame: controls))
        #expect(FriendFootprintScreenOcclusionPolicy.isCoveredByControls(
            projectedPoint: CGPoint(x: 355, y: 740), controlsFrame: controls))
        #expect(!FriendFootprintScreenOcclusionPolicy.isCoveredByControls(
            projectedPoint: CGPoint(x: 260, y: 633.7), controlsFrame: controls))
        #expect(!FriendFootprintScreenOcclusionPolicy.isCoveredByControls(
            projectedPoint: CGPoint(x: 335.7, y: 633.7), controlsFrame: .zero))
    }

    @Test
    func exactlySeventyTwoHoursMovesBothKindsOutOfActiveContent() async {
        let now = Date.now
        let cutoff = now.addingTimeInterval(-72 * hour)
        let justFreshPlace = place(visits: [visit(at: cutoff.addingTimeInterval(0.001))])
        let boundaryPlace = place(visits: [visit(at: cutoff)])
        let justFreshReel = reel(at: cutoff.addingTimeInterval(0.001))
        let boundaryReel = reel(at: cutoff)
        let sources = Sources()
        sources.activePOIs.send([justFreshPlace, boundaryPlace])
        sources.mapPOIs.send([justFreshPlace, boundaryPlace])
        sources.reels.send([justFreshReel, boundaryReel])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(Set(model.activeFeedItems.map(\.id)) == Set([justFreshPlace.id, justFreshReel.id]))
        #expect(model.mapRenderPOIs(retaining: nil).map(\.id) == [justFreshPlace.id])
        #expect(model.mapRenderReels(retaining: nil).map(\.id) == [justFreshReel.id])
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [boundaryPlace.id])
    }

    @Test
    func fortyEightHourPostsAreActiveButOldReelsLeaveTheHomepageWithoutDeletingMemories() async {
        let now = Date.now
        let sources = Sources()
        let freshReel = reel(at: now.addingTimeInterval(-48 * hour))
        let oldReel = reel(at: now.addingTimeInterval(-73 * hour))
        let freshPlace = place(visits: [visit(at: now.addingTimeInterval(-48 * hour))])
        let oldPlace = place(visits: [visit(at: now.addingTimeInterval(-73 * hour))])
        sources.activePOIs.send([freshPlace, oldPlace])
        sources.mapPOIs.send([freshPlace, oldPlace])
        sources.reels.send([freshReel, oldReel])
        sources.archive.saveReel(oldReel, audience: .livePublic)
        let environment = sources.environment()
        let archiveView = UserMapViewModel(environment: environment, context: .me, dataScope: .privateArchive)
        let model = MapTalkViewModel(environment: environment)
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(StoryReadKeys.freshWindow == 72 * hour)
        #expect(Set(model.activeFeedItems.map(\.id)) == Set([freshPlace.id, freshReel.id]))
        #expect(model.mapRenderReels(retaining: nil).map(\.id) == [freshReel.id])
        #expect(model.mapRenderPOIs(retaining: nil).map(\.id) == [freshPlace.id])
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [oldPlace.id])
        #expect(sources.archive.privateReels.contains { $0.id == oldReel.id })
        #expect(sources.archive.publicReelOverlays.contains { $0.id == oldReel.id })
        #expect(archiveView.reels.contains { $0.id == oldReel.id })
        #expect(model.activityReels.contains { $0.id == oldReel.id },
                "The active shelf's TTL must not delete the notification/revisit source")
    }

    @Test
    func aProfileMapDoesNotApplyTheHomepageExpiryRule() throws {
        let model = MapTalkViewModel(environment: Sources().environment(), scope: .user(PreviewData.currentUser))
        let profileReels = model.reals
        let latestExpiry = try #require(profileReels.map(\.expiresAt).max())
        let originalFeedIDs = model.activeFeedItems.map(\.id)

        model.refreshFreshness(asOf: latestExpiry.addingTimeInterval(hour))

        #expect(model.reals.map(\.id) == profileReels.map(\.id))
        #expect(model.mapRenderReels(retaining: nil).map(\.id) == profileReels.map(\.id))
        #expect(model.activeFeedItems.map(\.id) == originalFeedIDs)
        #expect(model.friendFootprints.isEmpty,
                "A person's profile keeps its own collection, not the homepage history layer")
    }

    @Test
    func historicalPlaceUsesCanonicalContentAndCountsPeopleNotVisits() async throws {
        let now = Date.now
        let person = UUID()
        let friend = UUID()
        let photo = RatedPOI.Media(kind: .photo(URL(fileURLWithPath: "/tmp/history-fixture.jpg")))
        let visits = [
            visit(userID: person, at: now.addingTimeInterval(-100 * hour), media: [photo]),
            visit(userID: person, at: now.addingTimeInterval(-80 * hour)),
            visit(userID: friend, at: now.addingTimeInterval(-90 * hour))
        ]
        let historical = place(visits: visits)
        let sources = Sources()
        sources.mapPOIs.send([historical])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        let footprint = try #require(model.friendFootprints.first)
        #expect(model.friendFootprints.count == 1, "A non-demo environment must not seed preview places")
        #expect(footprint.ratedPOI == historical)
        #expect(footprint.friendIDs.count == 2)
        #expect(Set(footprint.friendIDs) == Set([person, friend]))
        #expect(footprint.ratedPOI.checkIns.count == 3)
        #expect(footprint.ratedPOI.checkIns.flatMap(\.media).contains(photo))
        #expect(model.activeFeedItems.isEmpty)
        #expect(model.mapRenderPOIs(retaining: nil).isEmpty)
        let originalID = footprint.id
        model.refreshFreshness(asOf: now.addingTimeInterval(hour))
        #expect(model.friendFootprints.first?.id == originalID,
                "Quiet history must keep a stable identity across freshness updates")
    }

    @Test
    func recentAndOldVisitsAtOnePlaceDoNotCreateTwoMarkers() async {
        let now = Date.now
        let recentVisit = visit(at: now.addingTimeInterval(-hour))
        let oldVisit = visit(at: now.addingTimeInterval(-90 * hour))
        let history = place(visits: [recentVisit, oldVisit])
        let active = place(id: history.id, visits: [recentVisit])
        let sources = Sources()
        sources.activePOIs.send([active])
        sources.mapPOIs.send([history])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(model.activeFeedPOIs.map(\.id) == [history.id])
        #expect(model.mapRenderPOIs(retaining: nil).map(\.id) == [history.id])
        #expect(model.friendFootprints.isEmpty)
        #expect(model.ratedPOIs.first?.checkIns.contains(oldVisit) == true,
                "Suppressing a duplicate quiet marker must not discard its historical visits")
    }

    @Test
    func clockExpiryMovesAFeedOnlyPlaceToHistoryWithoutAnotherSearch() async throws {
        let now = Date.now
        let recent = place(visits: [visit(at: now.addingTimeInterval(-71 * hour))])
        let activeReel = reel(at: now.addingTimeInterval(-71 * hour))
        let sources = Sources()
        sources.activePOIs.send([recent])
        sources.reels.send([activeReel])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)
        #expect(Set(model.activeFeedItems.map(\.id)) == Set([recent.id, activeReel.id]))
        #expect(model.friendFootprints.isEmpty)

        model.refreshFreshness(asOf: now.addingTimeInterval(2 * hour))

        #expect(model.activeFeedItems.isEmpty)
        #expect(model.mapRenderPOIs(retaining: nil).isEmpty)
        #expect(model.mapRenderReels(retaining: nil).isEmpty)
        let footprint = try #require(model.friendFootprints.first)
        #expect(footprint.ratedPOI == recent)
        #expect(model.friendFootprints.count == 1)
        #expect(sources.mapPOIs.searchCount == 1, "Expiry must not need a new map search response")
    }

    @Test
    func aSavedOldCaptureBecomesActiveWhenItIsPublishedNow() async {
        let now = Date.now
        let sources = Sources()
        let publishedVisit = RatedPOI.CheckIn(userId: UUID(),
            createdAt: now.addingTimeInterval(-300 * hour), publishedAt: now.addingTimeInterval(-hour))
        let publishedPlace = place(visits: [publishedVisit])
        sources.activePOIs.send([publishedPlace])
        sources.mapPOIs.send([publishedPlace])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(model.activeFeedPOIs.map(\.id) == [publishedPlace.id])
        #expect(model.mapRenderPOIs(retaining: nil).map(\.id) == [publishedPlace.id])
        #expect(model.friendFootprints.isEmpty)
    }

    @Test
    func removingMapHistoryRemovesItsQuietMarkerInsteadOfLeavingAStaleCopy() async {
        let now = Date.now
        let historical = place(visits: [visit(at: now.addingTimeInterval(-100 * hour))])
        let sources = Sources()
        sources.mapPOIs.send([historical])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [historical.id])

        sources.mapPOIs.send([])
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(model.friendFootprints.isEmpty)
        #expect(model.ratedPOIs.isEmpty)
        #expect(model.mapRenderPOIs(retaining: nil).isEmpty)
    }

    @Test
    func anUnboundedCachedReelStillExpiresFromFeedAndMapAfterThreeDays() async {
        let now = Date.now
        var stale = reel(at: now.addingTimeInterval(-73 * hour))
        stale.expiresAt = .distantFuture
        let sources = Sources()
        sources.reels.send([stale])
        sources.archive.saveReel(stale, audience: .livePublic)
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(model.activeFeedItems.isEmpty)
        #expect(model.mapRenderReels(retaining: nil).isEmpty)
        #expect(model.activityReels.map(\.id) == [stale.id])
        #expect(sources.archive.privateReels.map(\.id) == [stale.id],
                "A public presentation deadline must not delete the person's saved memory")
    }

    @Test
    func publicationStartsTheReelClockAndEngagementDoesNotExtendIt() {
        let now = Date.now
        var saved = reel(at: now.addingTimeInterval(-300 * hour))
        saved.expiresAt = .distantFuture
        saved.publishedAt = now.addingTimeInterval(-48 * hour)
        #expect(StoryReadKeys.isActive(saved, asOf: now))
        #expect(StoryReadKeys.expiresAt(for: saved) == now.addingTimeInterval(24 * hour))

        saved.publishedAt = now.addingTimeInterval(-72 * hour)
        saved.likes = [UUID()]
        saved.comments = [.init(userId: UUID(), text: "New discussion", createdAt: now)]
        #expect(!StoryReadKeys.isActive(saved, asOf: now))
    }

    @Test
    func resumingAfterExpiryReleasesTheRetainedPlaceIntoQuietHistory() async {
        let now = Date.now
        let nearlyExpired = place(visits: [visit(at: now.addingTimeInterval(-71 * hour))])
        let sources = Sources()
        sources.activePOIs.send([nearlyExpired])
        sources.mapPOIs.send([nearlyExpired])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.retainActiveFeedItem(id: nearlyExpired.id)

        model.refreshFreshness(asOf: now.addingTimeInterval(2 * hour))

        #expect(model.activeFeedItems.isEmpty,
                "An old reading session must not pin yesterday's post in today's active feed")
        #expect(model.mapRenderPOIs(retaining: nil).isEmpty)
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [nearlyExpired.id])
    }

    @Test
    func resumingAfterExpiryReleasesTheRetainedReelWithoutChangingOtherFeedItems() async {
        let now = Date.now
        let nearlyExpired = reel(at: now.addingTimeInterval(-71 * hour))
        let recent = reel(at: now.addingTimeInterval(-hour))
        let sources = Sources()
        sources.reels.send([nearlyExpired, recent])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.retainActiveFeedItem(id: nearlyExpired.id)

        model.refreshFreshness(asOf: now.addingTimeInterval(2 * hour))

        #expect(model.activeFeedItems.map(\.id) == [recent.id])
        #expect(model.mapRenderReels(retaining: nil).map(\.id) == [recent.id])
        #expect(Set(model.activityReels.map(\.id)) == Set([nearlyExpired.id, recent.id]))
    }

    @Test
    func aNewCommentDoesNotPromoteAnOldPlaceButANewVisitDoes() async {
        let now = Date.now
        let oldVisit = visit(at: now.addingTimeInterval(-90 * hour))
        var historical = place(visits: [oldVisit])
        historical.comments = [.init(userId: UUID(), content: .text("Is it still open?"), createdAt: now)]
        let sources = Sources()
        sources.activePOIs.send([historical])
        sources.mapPOIs.send([historical])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)
        #expect(model.activeFeedItems.isEmpty)
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [historical.id])

        let returnVisit = visit(userID: oldVisit.userId, at: now)
        historical.checkIns.append(returnVisit)
        sources.activePOIs.send([historical])
        sources.mapPOIs.send([historical])
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)
        #expect(model.activeFeedPOIs.map(\.id) == [historical.id])
        #expect(model.friendFootprints.isEmpty)
        #expect(model.activeFeedPOIs.first?.checkIns.count == 2,
                "A repeat visit brings back the same place, not a duplicate or a replacement history")
    }

    @Test
    func selectingAnOldPlaceDoesNotAddABrightDuplicateOverItsQuietMarker() async {
        let now = Date.now
        let historical = place(visits: [visit(at: now.addingTimeInterval(-100 * hour))])
        let sources = Sources()
        sources.mapPOIs.send([historical])
        let model = MapTalkViewModel(environment: sources.environment())
        await deliverRepositoryValues()
        model.refreshFreshness(asOf: now)

        #expect(model.mapRenderPOIs(retaining: historical.id, selectedMapPOI: historical).isEmpty)
        #expect(model.friendFootprints.map { $0.ratedPOI.id } == [historical.id])
        #expect(model.friendFootprints.first?.ratedPOI.checkIns == historical.checkIns,
                "The history card still uses its complete place content")
    }

    private func deliverRepositoryValues() async {
        // Publishers use receive(on: DispatchQueue.main). Drain that scheduler,
        // rather than depending on wall-clock sleeps or external networking.
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func visit(userID: UUID = UUID(), at date: Date, media: [RatedPOI.Media] = []) -> RatedPOI.CheckIn {
        .init(userId: userID, createdAt: date, media: media)
    }

    private func place(id: UUID = UUID(), visits: [RatedPOI.CheckIn]) -> RatedPOI {
        RatedPOI(poi: POI(id: id, name: "Actual public landmark",
            coordinate: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33), category: .coffee),
            highlight: nil, secondary: nil, media: [], checkIns: visits, comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private func reel(at date: Date) -> RealPost {
        RealPost(id: UUID(), userId: PreviewData.currentUser.id,
            center: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33), radiusMeters: 100,
            message: "Public memory", attachments: [], likes: [], comments: [], visibility: .publicAll,
            createdAt: date, expiresAt: date.addingTimeInterval(72 * hour))
    }
}

@MainActor
private final class Sources {
    let activePOIs = HistoryPOIRepository()
    let mapPOIs = HistoryPOIRepository()
    let reels = HistoryReelRepository()
    let archive = MyMapArchiveStore(startsEmpty: true)

    func environment() -> AppEnvironment {
        AppEnvironment(build: .init(configuration: .debug, featureFlags: []),
            location: HistoryLocationService(), notifications: NotificationServiceImpl(),
            activePOIRepo: activePOIs, poiRepo: mapPOIs, realRepo: reels, myMapArchive: archive)
    }
}

private final class HistoryLocationService: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)
    func requestWhenInUse() { }
}

private final class HistoryPOIRepository: POIRepository, ActivePOIRepository {
    private let subject = CurrentValueSubject<[RatedPOI], Never>([])
    private(set) var searchCount = 0
    func near(_: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        searchCount += 1
        return subject.eraseToAnyPublisher()
    }
    func active(in _: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> { subject.eraseToAnyPublisher() }
    func send(_ places: [RatedPOI]) { subject.send(places) }
}

private final class HistoryReelRepository: RealRepository {
    private let subject = CurrentValueSubject<[RealPost], Never>([])
    func active(in _: MKMapRect?) -> AnyPublisher<[RealPost], Never> { subject.eraseToAnyPublisher() }
    func send(_ reels: [RealPost]) { subject.send(reels) }
}

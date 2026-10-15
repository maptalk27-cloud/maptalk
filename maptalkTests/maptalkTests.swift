import Combine
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import maptalk

struct maptalkTests {

    @Test
    @MainActor
    func locateCompletesWhenTheFirstRealLocationArrives() async {
        let location = DelayedLocationService()
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: location,
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: MyMapArchiveStore()
        )
        let viewModel = MapTalkViewModel(environment: environment)
        let initialCenter = viewModel.region.center
        let currentLocation = CLLocation(latitude: 37.3318, longitude: -122.0312)

        viewModel.centerOnUser()

        #expect(location.requestCount == 1)
        #expect(viewModel.region.center.latitude == initialCenter.latitude)
        #expect(viewModel.region.center.longitude == initialCenter.longitude)

        location.location.send(currentLocation)
        await Task.yield()

        #expect(abs(viewModel.region.center.latitude - currentLocation.coordinate.latitude) < 0.000_001)
        #expect(abs(viewModel.region.center.longitude - currentLocation.coordinate.longitude) < 0.000_001)
    }

    @Test
    @MainActor
    func friendFootprintUsesCanonicalPOIDataForTheSharedCard() {
        let friendIDs = [UUID(), UUID(), UUID()]
        let coordinate = CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312)
        let footprint = MapTalkFriendFootprint(
            id: "nearby-coffee",
            placeName: "Nearby Coffee",
            coordinate: coordinate,
            category: .coffee,
            friendIDs: friendIDs
        )

        #expect(footprint.ratedPOI.poi.name == footprint.placeName)
        #expect(footprint.ratedPOI.poi.coordinate.latitude == coordinate.latitude)
        #expect(footprint.ratedPOI.poi.coordinate.longitude == coordinate.longitude)
        #expect(footprint.ratedPOI.poi.category == footprint.category)
        #expect(footprint.ratedPOI.checkIns.map(\.userId) == friendIDs)
        #expect(footprint.ratedPOI.tags == [.init(tag: .explore, count: friendIDs.count)])
        #expect(footprint.ratedPOI.media.isEmpty)
        #expect(footprint.ratedPOI.comments.isEmpty)
    }

    @Test
    @MainActor
    func publicCaptureDoesNotPromoteEarlierPrivateCheckIn() {
        let archive = MyMapArchiveStore()
        let coordinate = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let ownerID = archive.currentUserID
        let privateMedia = RatedPOI.Media(
            id: UUID(),
            kind: .photo(URL(fileURLWithPath: "/tmp/private.jpg"))
        )
        let privateCheckIn = RatedPOI.CheckIn(
            userId: ownerID,
            media: [privateMedia],
            tag: .explore
        )
        let privatePlace = RatedPOI(
            poi: POI(id: UUID(), name: "Private first", coordinate: coordinate, category: .viewpoint),
            highlight: nil,
            secondary: nil,
            media: [],
            checkIns: [privateCheckIn],
            comments: [],
            endorsements: .init(hype: 0, solid: 1, meh: 0, questionable: 0),
            tags: [.init(tag: .explore, count: 1)],
            isFavoritedByCurrentUser: true,
            favoritesCount: 1
        )
        _ = archive.savePOI(
            privatePlace,
            publicVersion: nil,
            audience: .privateMyMap
        )

        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: LocationServiceImpl(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: archive
        )
        let viewModel = MapTalkViewModel(environment: environment)
        let publicMedia = RatedPOI.Media(
            id: UUID(),
            kind: .photo(URL(fileURLWithPath: "/tmp/public.jpg"))
        )

        let published = viewModel.publishPlace(
            .init(target: .existing(privatePlace), media: publicMedia),
            at: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            audience: .livePublic
        )

        #expect(published != nil)
        let publicOverlay = archive.publicPOIOverlays.first { $0.id == privatePlace.id }
        #expect(publicOverlay?.checkIns.count == 1)
        #expect(publicOverlay?.checkIns.first?.media.first?.id == publicMedia.id)
        #expect(publicOverlay?.checkIns.first?.endorsement == .solid)
        #expect(publicOverlay?.checkIns.first?.tag == .explore)
        #expect(publicOverlay?.endorsements.solid == 1)
        #expect(publicOverlay?.tags.first(where: { $0.tag == .explore })?.count == 1)
        #expect(publicOverlay?.checkIns.contains(where: { $0.id == privateCheckIn.id }) == false)

        let privateArchive = archive.privatePOIs.first { $0.id == privatePlace.id }
        #expect(privateArchive?.checkIns.count == 2)
        #expect(privateArchive?.checkIns.contains(where: { $0.id == privateCheckIn.id }) == true)
    }

    @Test
    @MainActor
    func privatePlaceWithoutMediaSavesOnlyToMyMap() {
        let archive = MyMapArchiveStore()
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: LocationServiceImpl(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: archive
        )
        let viewModel = MapTalkViewModel(environment: environment)
        let privateCount = archive.privatePOIs.count
        let publicIDs = archive.publicPOIOverlays.map(\.id)

        let published = viewModel.publishPlace(
            .init(
                target: .new(name: "No media place", category: .viewpoint),
                media: nil
            ),
            at: CLLocation(latitude: 34.0522, longitude: -118.2437),
            audience: .privateMyMap
        )

        #expect(published != nil)
        #expect(archive.privatePOIs.count == privateCount + 1)
        #expect(archive.publicPOIOverlays.map(\.id) == publicIDs)

        guard let published,
              let saved = archive.privatePOIs.first(where: { $0.id == published.id }) else {
            return
        }
        #expect(saved.checkIns.count == 1)
        #expect(saved.checkIns[0].media.isEmpty)
        #expect(saved.checkIns[0].endorsement == nil)
        #expect(saved.checkIns[0].tag == nil)
        #expect(saved.endorsements.solid == 0)
        #expect(saved.tags.isEmpty)
    }

    @Test
    @MainActor
    func publicPlaceWithoutMediaPublishesANavigableCheckIn() throws {
        let archive = MyMapArchiveStore()
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: LocationServiceImpl(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: archive
        )
        let viewModel = MapTalkViewModel(environment: environment)
        let privateCount = archive.privatePOIs.count
        let publicCount = archive.publicPOIOverlays.count

        let published = viewModel.publishPlace(
            .init(
                target: .new(name: "Public check-in", category: .viewpoint),
                media: nil
            ),
            at: CLLocation(latitude: 34.0522, longitude: -118.2437),
            audience: .livePublic
        )

        let place = try #require(published)
        let privatePlace = try #require(archive.privatePOIs.first { $0.id == place.id })
        let publicPlace = try #require(archive.publicPOIOverlays.first { $0.id == place.id })

        #expect(archive.privatePOIs.count == privateCount + 1)
        #expect(archive.publicPOIOverlays.count == publicCount + 1)
        #expect(privatePlace.checkIns.count == 1)
        #expect(publicPlace.checkIns.count == 1)
        #expect(publicPlace.checkIns[0].userId == archive.currentUserID)
        #expect(publicPlace.checkIns[0].media.isEmpty)
        #expect(publicPlace.checkIns[0].endorsement == nil)
        #expect(publicPlace.checkIns[0].tag == nil)
        #expect(publicPlace.endorsements.solid == 0)
        #expect(publicPlace.tags.isEmpty)
        #expect(publicPlace.isFavoritedByCurrentUser == false)
        #expect(publicPlace.favoritesCount == 0)

        let storyItems = MapStoryFeed.items(
            reals: [],
            ratedPOIs: [publicPlace],
            onlyRecentPOIStories: true,
            userProvider: { PreviewData.user(for: $0) }
        )
        #expect(storyItems.map(\.id) == [place.id])
    }

    @Test
    @MainActor
    func publicPlaceWithoutMediaDoesNotPromotePrivateHistory() throws {
        let archive = MyMapArchiveStore()
        let coordinate = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let privateMedia = RatedPOI.Media(
            id: UUID(),
            kind: .photo(URL(fileURLWithPath: "/tmp/private-only.jpg"))
        )
        let privateCheckIn = RatedPOI.CheckIn(
            userId: archive.currentUserID,
            media: [privateMedia],
            tag: .explore
        )
        let privatePlace = RatedPOI(
            poi: POI(id: UUID(), name: "Private history", coordinate: coordinate, category: .viewpoint),
            highlight: nil,
            secondary: nil,
            media: [],
            checkIns: [privateCheckIn],
            comments: [],
            endorsements: .init(hype: 0, solid: 1, meh: 0, questionable: 0),
            tags: [.init(tag: .explore, count: 1)],
            isFavoritedByCurrentUser: true,
            favoritesCount: 1
        )
        _ = archive.savePOI(privatePlace, publicVersion: nil, audience: .privateMyMap)
        let viewModel = MapTalkViewModel(environment: makeEnvironment(archive: archive))

        let published = viewModel.publishPlace(
            .init(target: .existing(privatePlace), media: nil),
            at: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            audience: .livePublic
        )

        let place = try #require(published)
        let publicPlace = try #require(archive.publicPOIOverlays.first { $0.id == place.id })
        #expect(publicPlace.checkIns.count == 1)
        #expect(publicPlace.checkIns[0].id != privateCheckIn.id)
        #expect(publicPlace.checkIns[0].media.isEmpty)
        #expect(publicPlace.media.isEmpty)
        #expect(publicPlace.comments.isEmpty)
        #expect(publicPlace.tags.isEmpty)
        #expect(publicPlace.endorsements.solid == 0)
    }

    @Test
    @MainActor
    func activeFeedUsesAnInclusiveFixedTwentyFourHourCutoff() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let boundary = makeActiveFeedPOI(
            name: "Boundary place",
            checkInDates: [now.addingTimeInterval(-StoryReadKeys.freshWindow)]
        )
        let expired = makeActiveFeedPOI(
            name: "Expired place",
            checkInDates: [now.addingTimeInterval(-StoryReadKeys.freshWindow - 0.001)]
        )

        let items = MapStoryFeed.items(
            reals: [],
            ratedPOIs: [expired, boundary],
            onlyRecentPOIStories: true,
            userProvider: { _ in nil },
            now: now
        )

        #expect(items.map(\.id) == [boundary.id])
        let item = try #require(items.first)
        guard case let .poi(group) = item.source else {
            Issue.record("The active boundary item must remain a POI")
            return
        }
        #expect(group.sharers.map(\.timestamp) == [now.addingTimeInterval(-StoryReadKeys.freshWindow)])
    }

    @Test
    @MainActor
    func activeFeedSnapshotKeepsPOIIdentityAcrossFocusSearchAndReadState() async throws {
        let now = Date.now
        let activePlace = makeActiveFeedPOI(
            name: "Active feed place",
            checkInDates: [now.addingTimeInterval(-60)],
            includesMedia: true
        )
        let mapSearchPlace = makeActiveFeedPOI(
            name: "Map search only",
            checkInDates: [now.addingTimeInterval(-30)]
        )
        let mapDuplicate = makeActiveFeedPOI(
            id: activePlace.id,
            name: "Directory shell",
            checkInDates: []
        )
        let activeReel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-20))
        let mapSearchReel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-10))
        let mapRepository = MutablePOIRepository(places: [mapDuplicate, mapSearchPlace])
        let location = DelayedLocationService()
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: location,
            notifications: NotificationServiceImpl(),
            activePOIRepo: FixedPOIRepository(places: [activePlace]),
            poiRepo: mapRepository,
            realRepo: FixedRealRepository(
                activeReals: [activeReel],
                mapReals: [mapSearchReel]
            ),
            myMapArchive: MyMapArchiveStore()
        )
        let viewModel = MapTalkViewModel(environment: environment)
        for _ in 0..<5 {
            if viewModel.activeFeedItems.count == 2,
               viewModel.ratedPOIs.map(\.id) == [activePlace.id, mapSearchPlace.id],
               viewModel.reals.map(\.id) == [mapSearchReel.id] {
                break
            }
            await Task.yield()
        }
        let beforeIDs = viewModel.activeFeedItems.map(\.id)
        let suiteName = "MapTalk.active-feed-stability.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let readStore = StoryReadStore(defaults: defaults, storageKey: "viewed")
        let readKeys = viewModel.activeFeedItems.flatMap { item -> [String] in
            guard case let .poi(group) = item.source else { return [] }
            return group.unreadCandidateKeys
        }

        viewModel.retainActiveFeedItem(id: activePlace.id)
        viewModel.focus(on: activePlace)
        viewModel.searchMap(
            in: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
        )
        readStore.markViewed(readKeys)
        await Task.yield()

        #expect(beforeIDs == [activeReel.id, activePlace.id])
        #expect(viewModel.activeFeedItems.map(\.id) == beforeIDs)
        #expect(viewModel.activeFeedPOIs.map(\.id) == [activePlace.id])
        #expect(viewModel.activeFeedReels.map(\.id) == [activeReel.id])
        #expect(viewModel.ratedPOIs.map(\.id) == [activePlace.id, mapSearchPlace.id])
        #expect(viewModel.reals.map(\.id) == [mapSearchReel.id])
        #expect(readKeys.isEmpty == false)
        #expect(readKeys.allSatisfy(readStore.isViewed))

        let initialRender = viewModel.mapRenderPOIs(retaining: nil)
        #expect(Set(initialRender.map(\.id)) == Set([activePlace.id, mapSearchPlace.id]))
        #expect(initialRender.first(where: { $0.id == activePlace.id })?.poi.name == "Active feed place")

        mapRepository.send([])
        for _ in 0..<5 {
            if viewModel.ratedPOIs.isEmpty { break }
            await Task.yield()
        }
        let retainedRender = viewModel.mapRenderPOIs(
            retaining: mapSearchPlace.id,
            selectedMapPOI: mapSearchPlace
        )
        #expect(Set(retainedRender.map(\.id)) == Set([activePlace.id, mapSearchPlace.id]))
    }

    @Test
    @MainActor
    func activeFeedRefreshKeepsStandaloneSearchOnlyMarkersRenderEligible() async {
        let now = Date.now
        let initialActivePOI = makeActiveFeedPOI(
            name: "Initial active place",
            checkInDates: [now.addingTimeInterval(-60)]
        )
        let replacementActivePOI = makeActiveFeedPOI(
            name: "Replacement active place",
            checkInDates: [now.addingTimeInterval(-30)]
        )
        let selectedSearchPOI = makeActiveFeedPOI(
            name: "Selected search-only place",
            checkInDates: []
        )
        let initialActiveReel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-50))
        let replacementActiveReel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-20))
        let selectedSearchReel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-10))
        let activePOIRepository = MutableActivePOIRepository(places: [initialActivePOI])
        let mapPOIRepository = MutablePOIRepository(places: [selectedSearchPOI])
        let realRepository = MutableRealRepository(
            activeReals: [initialActiveReel],
            mapReals: [selectedSearchReel]
        )
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: DelayedLocationService(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: activePOIRepository,
            poiRepo: mapPOIRepository,
            realRepo: realRepository,
            myMapArchive: MyMapArchiveStore()
        )
        let viewModel = MapTalkViewModel(environment: environment)
        for _ in 0..<10 {
            if Set(viewModel.activeFeedItems.map(\.id))
                == Set([initialActivePOI.id, initialActiveReel.id]),
               viewModel.ratedPOIs.map(\.id) == [selectedSearchPOI.id],
               viewModel.reals.map(\.id) == [selectedSearchReel.id] {
                break
            }
            await Task.yield()
        }

        mapPOIRepository.send([])
        realRepository.sendMap([])
        activePOIRepository.send([replacementActivePOI])
        realRepository.sendActive([replacementActiveReel])
        for _ in 0..<20 {
            if Set(viewModel.activeFeedItems.map(\.id))
                == Set([replacementActivePOI.id, replacementActiveReel.id]),
               viewModel.ratedPOIs.isEmpty,
               viewModel.reals.isEmpty {
                break
            }
            await Task.yield()
        }

        let unretainedPOIIDs = Set(viewModel.mapRenderPOIs(retaining: nil).map(\.id))
        let retainedPOIIDs = Set(
            viewModel.mapRenderPOIs(
                retaining: selectedSearchPOI.id,
                selectedMapPOI: selectedSearchPOI
            ).map(\.id)
        )
        let unretainedReelIDs = Set(viewModel.mapRenderReels(retaining: nil).map(\.id))
        let retainedReelIDs = Set(
            viewModel.mapRenderReels(
                retaining: selectedSearchReel.id,
                selectedMapReel: selectedSearchReel
            ).map(\.id)
        )

        #expect(Set(viewModel.activeFeedItems.map(\.id)) == Set([
            replacementActivePOI.id,
            replacementActiveReel.id
        ]))
        #expect(unretainedPOIIDs == Set([replacementActivePOI.id]))
        #expect(retainedPOIIDs == Set([replacementActivePOI.id, selectedSearchPOI.id]))
        #expect(unretainedReelIDs == Set([replacementActiveReel.id]))
        #expect(retainedReelIDs == Set([replacementActiveReel.id, selectedSearchReel.id]))
    }

    @Test
    @MainActor
    func switchingFeedSelectionReleasesAnExpiredRetainedPOI() async {
        let now = Date.now
        let firstID = UUID()
        let firstFresh = makeActiveFeedPOI(
            id: firstID,
            name: "First active place",
            checkInDates: [now.addingTimeInterval(-60)]
        )
        let firstExpired = makeActiveFeedPOI(
            id: firstID,
            name: "First active place",
            checkInDates: [now.addingTimeInterval(-StoryReadKeys.freshWindow - 60)]
        )
        let second = makeActiveFeedPOI(
            name: "Second active place",
            checkInDates: [now.addingTimeInterval(-30)]
        )
        let activeRepository = MutableActivePOIRepository(places: [firstFresh, second])
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: DelayedLocationService(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: activeRepository,
            poiRepo: FixedPOIRepository(places: []),
            realRepo: FixedRealRepository(reals: []),
            myMapArchive: MyMapArchiveStore()
        )
        let viewModel = MapTalkViewModel(environment: environment)
        for _ in 0..<5 {
            if viewModel.activeFeedItems.count == 2 { break }
            await Task.yield()
        }

        viewModel.retainActiveFeedItem(id: firstID)
        activeRepository.send([firstExpired, second])
        for _ in 0..<20 {
            let sourceTimestamp = viewModel.activityPOIs
                .first(where: { $0.id == firstID })?
                .checkIns.first?.createdAt
            if sourceTimestamp == firstExpired.checkIns.first?.createdAt { break }
            await Task.yield()
        }
        #expect(Set(viewModel.activeFeedItems.map(\.id)) == Set([firstID, second.id]))

        viewModel.retainActiveFeedItem(id: second.id)
        #expect(viewModel.activeFeedItems.map(\.id) == [second.id])
    }

    @Test
    @MainActor
    func historicalFriendFootprintNeverEntersTheActiveFeed() async {
        let now = Date.now
        let activePlace = makeActiveFeedPOI(
            name: "Active place",
            checkInDates: [now.addingTimeInterval(-60)]
        )
        let historicalPlace = makeActiveFeedPOI(
            name: "Historical friend place",
            checkInDates: [now.addingTimeInterval(-StoryReadKeys.freshWindow - 1)]
        )
        let footprint = MapTalkFriendFootprint(
            id: "historical-friend-place",
            ratedPOI: historicalPlace,
            friendIDs: [UUID()]
        )
        let environment = AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: DelayedLocationService(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: FixedPOIRepository(places: [activePlace]),
            poiRepo: FixedPOIRepository(places: [footprint.ratedPOI]),
            realRepo: FixedRealRepository(reals: []),
            myMapArchive: MyMapArchiveStore()
        )
        let viewModel = MapTalkViewModel(environment: environment)
        for _ in 0..<5 {
            if viewModel.activeFeedItems.isEmpty == false,
               viewModel.ratedPOIs.isEmpty == false {
                break
            }
            await Task.yield()
        }

        let historicalIDs = Set(viewModel.friendFootprints.map { $0.ratedPOI.id })
            .union([footprint.ratedPOI.id])
        let mapSearchInputIDs = Set(viewModel.ratedPOIs.map(\.id))

        #expect(mapSearchInputIDs == Set([footprint.ratedPOI.id]))
        #expect(viewModel.activeFeedItems.map(\.id) == [activePlace.id])
        #expect(Set(viewModel.activeFeedItems.map(\.id)).isDisjoint(with: historicalIDs))
    }

    @Test
    @MainActor
    func activeFeedMixesReelsAndRecentPOIsInRecencyOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reel = makeActiveFeedReel(createdAt: now.addingTimeInterval(-60))
        let place = makeActiveFeedPOI(
            name: "Recent place",
            checkInDates: [now.addingTimeInterval(-120)]
        )

        let items = MapStoryFeed.items(
            reals: [reel],
            ratedPOIs: [place],
            onlyRecentPOIStories: true,
            userProvider: { _ in nil },
            now: now
        )

        #expect(items.map(\.id) == [reel.id, place.id])
        #expect(items.count == 2)
        if items.count == 2 {
            guard case .real = items[0].source else {
                Issue.record("The newest active item must remain a Reel")
                return
            }
            guard case .poi = items[1].source else {
                Issue.record("The recent place must remain a POI in the mixed feed")
                return
            }
        }
    }

    @Test
    @MainActor
    func timelineFallbackDoesNotRenameAnotherCity() {
        let resolver = TimelineCityResolver()
        let portland = CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784)

        let label = resolver.label(for: portland)

        #expect(label.hasPrefix("Lat "))
        #expect(label.contains("Seattle") == false)
    }

    @Test
    @MainActor
    func privateBubbleSnapshotStaysPrivateAndDoesNotMutateFolders() {
        let archive = MyMapArchiveStore()
        let legacyJourneyIDs = archive.legacyJourneyCatalog.map(\.id)
        let folderSnapshot = archive.journeyFolders.map { folder in
            (folder.id, folder.memberReferences)
        }
        let bubble = makeBubble(
            userID: archive.currentUserID,
            title: "Weekend picks"
        )

        _ = archive.saveBubble(bubble, audience: .privateMyMap)

        #expect(archive.privateBubbleCatalog.map(\.id) == [bubble.id])
        #expect(archive.publicBubbleCatalog.isEmpty)
        #expect(archive.legacyJourneyCatalog.map(\.id) == legacyJourneyIDs)
        #expect(archive.journeyFolders.count == folderSnapshot.count)
        for (folderID, memberReferences) in folderSnapshot {
            #expect(
                archive.journeyFolders.first(where: { $0.id == folderID })?.memberReferences
                    == memberReferences
            )
        }
    }

    @Test
    @MainActor
    func publicBubbleSnapshotIsImmutableAcrossRepeatedSaves() {
        let archive = MyMapArchiveStore()
        let bubbleID = UUID()
        let first = makeBubble(
            id: bubbleID,
            userID: archive.currentUserID,
            title: "First title"
        )
        let updated = makeBubble(
            id: bubbleID,
            userID: archive.currentUserID,
            title: "Updated title"
        )

        _ = archive.saveBubble(first, audience: .livePublic)
        _ = archive.saveBubble(updated, audience: .livePublic)

        #expect(archive.privateBubbleCatalog.count == 1)
        #expect(archive.publicBubbleCatalog.count == 1)
        #expect(archive.privateBubbleCatalog.first?.title == "First title")
        #expect(archive.publicBubbleCatalog.first?.title == "First title")
    }

    @Test
    @MainActor
    func reelUsesFolderAsSnapshotSourceWithoutChangingFolder() throws {
        let archive = MyMapArchiveStore()
        let sourceReel = try #require(archive.privateReels.first)
        let folder = archive.createJourneyFolder(
            title: "Future reel",
            memberReferences: [.reel(sourceReel.id)]
        )
        let originalMembership = folder.memberReferences
        let environment = makeEnvironment(archive: archive)
        let viewModel = MapTalkViewModel(environment: environment)

        let published = viewModel.publishReel(
            .init(
                text: "A new post",
                attachments: [],
                bubbleSource: .folder(folder.id)
            ),
            at: CLLocation(latitude: 47.61, longitude: -122.33),
            audience: .privateMyMap
        )

        let reel = try #require(published)
        let bubbleID = try #require(reel.capsuleId)
        let bubble = try #require(archive.privateBubbleCatalog.first { $0.id == bubbleID })
        #expect(reel.visibility == .privateOnly)
        #expect(bubble.title == folder.title)
        #expect(bubble.reels.map(\.id) == [sourceReel.id])
        #expect(bubble.orderedMemberReferences == originalMembership)
        #expect(bubble.reels.first?.capsuleId == nil)
        #expect(bubble.reels.first?.visibility == .privateOnly)
        #expect(bubble.reels.first?.likes.isEmpty == true)
        #expect(bubble.reels.first?.comments.isEmpty == true)
        #expect(archive.publicBubbleCatalog.isEmpty)
        #expect(archive.publicReelOverlays.isEmpty)
        #expect(
            archive.journeyFolders.first(where: { $0.id == folder.id })?.memberReferences
                == originalMembership
        )
        #expect(originalMembership.contains(.reel(reel.id)) == false)
    }

    @Test
    @MainActor
    func publicReelManualBubbleDeduplicatesAndResolvesOnMapTalk() throws {
        let archive = MyMapArchiveStore()
        let sourceReel = try #require(archive.privateReels.first)
        let environment = makeEnvironment(archive: archive)
        let viewModel = MapTalkViewModel(environment: environment)
        let reference = JourneyFolder.MemberReference.reel(sourceReel.id)

        let published = viewModel.publishReel(
            .init(
                text: "Public with a bubble",
                attachments: [],
                bubbleSource: .memories([reference, reference])
            ),
            at: CLLocation(latitude: 47.61, longitude: -122.33),
            audience: .livePublic
        )

        let reel = try #require(published)
        let bubbleID = try #require(reel.capsuleId)
        #expect(archive.privateBubbleCatalog.count == 1)
        #expect(archive.publicBubbleCatalog.count == 1)
        #expect(archive.publicBubbleCatalog.first?.reels.map(\.id) == [sourceReel.id])
        #expect(archive.publicBubbleCatalog.first?.orderedMemberReferences == [reference])
        #expect(archive.publicBubbleCatalog.first?.reels.first?.visibility == .publicAll)
        #expect(viewModel.journey(for: bubbleID)?.id == bubbleID)
        #expect(archive.publicReelOverlays.contains(where: { $0.id == reel.id }))
    }

    @Test
    @MainActor
    func privateBubbleResolvesOnlyThroughMyMapCatalog() throws {
        let archive = MyMapArchiveStore()
        let sourceReel = try #require(archive.privateReels.first)
        let environment = makeEnvironment(archive: archive)
        let mapTalk = MapTalkViewModel(environment: environment)

        let published = try #require(
            mapTalk.publishReel(
                .init(
                    text: "Private with a bubble",
                    attachments: [],
                    bubbleSource: .memories([.reel(sourceReel.id)])
                ),
                at: CLLocation(latitude: 47.61, longitude: -122.33),
                audience: .privateMyMap
            )
        )
        let bubbleID = try #require(published.capsuleId)
        let myMap = UserMapViewModel(
            environment: environment,
            context: .me,
            dataScope: .privateArchive
        )

        #expect(mapTalk.journey(for: bubbleID)?.id == nil)
        #expect(myMap.journeyCatalog.contains(where: { $0.id == bubbleID }))
    }

    @Test
    @MainActor
    func bubbleScopePreservesMixedPlaceAndReelOrder() throws {
        let archive = MyMapArchiveStore()
        let reel = try #require(archive.privateReels.first)
        let place = try #require(
            archive.privatePOIs.first(where: { rated in
                rated.checkIns.contains { $0.userId == archive.currentUserID }
            })
        )
        let order: [JourneyFolder.MemberReference] = [.poi(place.id), .reel(reel.id)]
        let bubble = JourneyPost(
            id: UUID(),
            userId: archive.currentUserID,
            title: "Ordered bubble",
            content: "",
            coordinate: reel.center,
            createdAt: .now,
            orderedMemberReferences: order,
            reels: [reel],
            pois: [place],
            likes: [],
            comments: []
        )

        let scope = MapJourneyScope(
            journey: bubble,
            userProvider: { PreviewData.user(for: $0) }
        )

        #expect(scope.storyItems.map(\.id) == [place.id, reel.id])
    }

    @Test
    @MainActor
    func friendFootprintViewportUsesOverscanAndRetainsSelection() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
        let bufferedEdge = footprint(id: "edge", latitude: 0.15, longitude: 0)
        let outside = footprint(id: "outside", latitude: 0.151, longitude: 0)
        let selectedOutside = footprint(id: "selected", latitude: 1, longitude: 1)
        let invalid = footprint(id: "invalid", latitude: .nan, longitude: 0)

        let layout = FriendFootprintViewportPolicy.layout(
            footprints: [bufferedEdge, outside, selectedOutside, invalid],
            in: region,
            retaining: selectedOutside.id
        )

        #expect(layout.places.map(\.id) == [bufferedEdge.id, selectedOutside.id])
    }

    @Test
    @MainActor
    func friendFootprintViewportWrapsAcrossDateLine() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 179.9),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
        )
        let acrossDateLine = footprint(id: "across", latitude: 0, longitude: -179.9)
        let tooFar = footprint(id: "far", latitude: 0, longitude: -179.5)

        let layout = FriendFootprintViewportPolicy.layout(
            footprints: [acrossDateLine, tooFar],
            in: region,
            retaining: nil
        )

        #expect(layout.places.map(\.id) == [acrossDateLine.id])
    }

    @Test
    @MainActor
    func friendFootprintUnderBudgetKeepsEveryPointVisible() {
        let canvas = CGSize(width: 393, height: 852)
        let chromeBottom: CGFloat = 220
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: CGPoint(x: 80, y: 360),
            friendCount: 5
        )
        let overlapping = FriendFootprintProjectedPlace(
            id: "second",
            point: CGPoint(x: 84, y: 360),
            friendCount: 4
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, overlapping],
            reservedPoints: [],
            canvasSize: canvas,
            topChromeBottom: chromeBottom,
            selectedID: nil
        )

        #expect(visibility.placeIDs == [first.id, overlapping.id])
        #expect(visibility.expandedPlaceIDs == [first.id])
        #expect(visibility.densityStyle == .sparse)
    }

    @Test
    @MainActor
    func isolatedFriendFootprintsAutomaticallyExpand() {
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: CGPoint(x: 70, y: 360),
            friendCount: 5
        )
        let second = FriendFootprintProjectedPlace(
            id: "second",
            point: CGPoint(x: 180, y: 360),
            friendCount: 4
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, second],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(visibility.placeIDs == [first.id, second.id])
        #expect(visibility.expandedPlaceIDs == [first.id, second.id])
    }

    @Test
    @MainActor
    func friendFootprintDetailLODUsesHysteresis() {
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: CGPoint(x: 80, y: 360),
            friendCount: 5
        )
        let second = FriendFootprintProjectedPlace(
            id: "second",
            point: CGPoint(x: 154, y: 360),
            friendCount: 4
        )
        let newlyCalculated = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, second],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )
        let retained = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, second],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil,
            previouslyExpandedIDs: [first.id, second.id]
        )

        #expect(newlyCalculated.expandedPlaceIDs == [first.id])
        #expect(retained.expandedPlaceIDs == [first.id, second.id])
    }

    @Test
    @MainActor
    func denseNeighborsShareOneRepresentativeDiamond() {
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: CGPoint(x: 80, y: 360),
            friendCount: 5
        )
        let closeNeighbor = FriendFootprintProjectedPlace(
            id: "neighbor",
            point: CGPoint(x: 120, y: 360),
            friendCount: 4
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, closeNeighbor],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(visibility.placeIDs == [first.id, closeNeighbor.id])
        #expect(visibility.expandedPlaceIDs == [first.id])
    }

    @Test
    @MainActor
    func selectedFriendFootprintAlwaysExpandsInDenseArea() {
        let selected = FriendFootprintProjectedPlace(
            id: "selected",
            point: CGPoint(x: 80, y: 360),
            friendCount: 2
        )
        let closeNeighbor = FriendFootprintProjectedPlace(
            id: "neighbor",
            point: CGPoint(x: 120, y: 360),
            friendCount: 5
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [selected, closeNeighbor],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: selected.id
        )

        #expect(visibility.placeIDs == [selected.id, closeNeighbor.id])
        #expect(visibility.expandedPlaceIDs == [selected.id])
    }

    @Test
    @MainActor
    func automaticFriendFootprintDiamondsRespectScreenBudget() {
        let projectedPlaces = (0..<20).map { index in
            FriendFootprintProjectedPlace(
                id: "place-\(index)",
                point: CGPoint(x: 60 + CGFloat(index) * 100, y: 400),
                friendCount: 20 - index
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projectedPlaces,
            reservedPoints: [],
            canvasSize: CGSize(width: 2_100, height: 1_000),
            topChromeBottom: 1,
            selectedID: nil
        )

        #expect(
            visibility.expandedPlaceIDs.count
                == FriendFootprintScreenLayoutPolicy.maximumExpandedMarkerCapacity
        )
        #expect(visibility.placeIDs == Set(projectedPlaces.map(\.id)))
        #expect(visibility.expandedPlaceIDs.isSubset(of: visibility.placeIDs))
        #expect(visibility.densityStyle == .sparse)
    }

    @Test
    @MainActor
    func sunnyvalePreviewProvidesHundredsOfStableFootprints() {
        let footprints = MapTalkFriendFootprint.previewData.filter {
            $0.id.hasPrefix("sunnyvale-")
        }
        let regenerated = MapTalkFriendFootprint.previewData.filter {
            $0.id.hasPrefix("sunnyvale-")
        }
        let identifiers = Set(footprints.map(\.id))

        #expect((300...500).contains(footprints.count))
        #expect(identifiers.count == footprints.count)
        #expect(footprints.allSatisfy { footprint in
            footprint.coordinate.latitude >= 37.335
                && footprint.coordinate.latitude <= 37.423
                && footprint.coordinate.longitude >= -122.08
                && footprint.coordinate.longitude <= -121.99
                && footprint.friendIDs.isEmpty == false
                && footprint.friendIDs.count <= 8
        })
        #expect(regenerated.count == footprints.count)
        #expect(zip(footprints, regenerated).allSatisfy { lhs, rhs in
            lhs.id == rhs.id
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.category == rhs.category
                && lhs.friendIDs == rhs.friendIDs
        })
    }

    @Test
    @MainActor
    func sunnyvalePreviewCoversTheCityWithoutCopiedFlowerClusters() {
        let footprints = MapTalkFriendFootprint.previewData.filter {
            $0.id.hasPrefix("sunnyvale-")
        }
        let latitudeBounds = 37.335...37.423
        let longitudeBounds = -122.08 ... -121.99
        let gridSize = 8
        var cellCounts: [Int: Int] = [:]

        for footprint in footprints {
            let latitudeProgress = (
                footprint.coordinate.latitude - latitudeBounds.lowerBound
            ) / (latitudeBounds.upperBound - latitudeBounds.lowerBound)
            let longitudeProgress = (
                footprint.coordinate.longitude - longitudeBounds.lowerBound
            ) / (longitudeBounds.upperBound - longitudeBounds.lowerBound)
            let row = min(
                gridSize - 1,
                max(0, Int(latitudeProgress * Double(gridSize)))
            )
            let column = min(
                gridSize - 1,
                max(0, Int(longitudeProgress * Double(gridSize)))
            )
            cellCounts[row * gridSize + column, default: 0] += 1
        }

        #expect(cellCounts.count >= 40)
        #expect((cellCounts.values.max() ?? 0) <= 30)

        let mapPoints = footprints.map { MKMapPoint($0.coordinate) }
        let neighborCounts = mapPoints.enumerated().map { index, point in
            mapPoints.enumerated().reduce(into: 0) { count, candidate in
                guard candidate.offset != index else { return }
                if point.distance(to: candidate.element) <= 400 {
                    count += 1
                }
            }
        }
        let sortedNeighborCounts = neighborCounts.sorted()
        let percentileIndex = Int(
            Double(max(0, sortedNeighborCounts.count - 1)) * 0.95
        )

        #expect(sortedNeighborCounts[percentileIndex] <= 22)
        #expect((sortedNeighborCounts.max() ?? 0) <= 30)
    }

    @Test
    @MainActor
    func sunnyvalePreviewCategoriesDoNotFormArtificialRainbows() {
        let footprints = MapTalkFriendFootprint.previewData.filter {
            $0.id.hasPrefix("sunnyvale-")
        }
        let mapPoints = footprints.map { MKMapPoint($0.coordinate) }
        let sameCategoryRatios = footprints.indices.map { index in
            let nearestIndices = footprints.indices
                .filter { $0 != index }
                .sorted {
                    mapPoints[index].distance(to: mapPoints[$0])
                        < mapPoints[index].distance(to: mapPoints[$1])
                }
                .prefix(5)
            let sameCategoryCount = nearestIndices.reduce(into: 0) { count, neighborIndex in
                if footprints[neighborIndex].category == footprints[index].category {
                    count += 1
                }
            }
            return Double(sameCategoryCount) / Double(max(1, nearestIndices.count))
        }
        let averageSameCategoryRatio = sameCategoryRatios.reduce(0, +)
            / Double(max(1, sameCategoryRatios.count))

        #expect(averageSameCategoryRatio >= 0.08)
    }

    @Test
    @MainActor
    func friendFootprintLayoutKeepsSeparatedPlaces() {
        let projectedPlaces = (0..<12).map { index in
            FriendFootprintProjectedPlace(
                id: "place-\(index)",
                point: CGPoint(
                    x: 35 + CGFloat(index % 4) * 95,
                    y: 280 + CGFloat(index / 4) * 130
                ),
                friendCount: 12 - index
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projectedPlaces,
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(visibility.placeIDs.count == projectedPlaces.count)
    }

    @Test
    @MainActor
    func primaryMarkerCollisionYieldsQuietHistoryUnlessSelected() {
        let selected = FriendFootprintProjectedPlace(
            id: "selected",
            point: CGPoint(x: 196, y: 420),
            friendCount: 2
        )
        let hidden = FriendFootprintProjectedPlace(
            id: "hidden",
            point: CGPoint(x: 260, y: 420),
            friendCount: 5
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [selected, hidden],
            reservedPoints: [selected.point, hidden.point],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: selected.id
        )

        #expect(visibility.placeIDs == [selected.id])
        #expect(visibility.expandedPlaceIDs == [selected.id])
    }

    @Test
    @MainActor
    func liveMarkerCornerClearanceRemovesAnUnreachableHistoryMarker() {
        let liveMarkerCenter = CGPoint(x: 100, y: 420)
        let insideSquareCorner = FriendFootprintProjectedPlace(
            id: "inside-live-hit-corner",
            point: CGPoint(x: 142, y: 462),
            friendCount: 6
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [insideSquareCorner],
            reservedPoints: [liveMarkerCenter],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(visibility.placeIDs.isEmpty)
        #expect(visibility.expandedPlaceIDs.isEmpty)
    }

    @Test
    @MainActor
    func denseFriendFootprintLayoutUsesStableRenderBudget() {
        let projectedPlaces = (0..<300).map { index in
            FriendFootprintProjectedPlace(
                id: "place-\(index)",
                point: CGPoint(
                    x: 24 + CGFloat(index % 20) * 17,
                    y: 250 + CGFloat(index / 20) * 38
                ),
                friendCount: index
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projectedPlaces,
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        let reversedVisibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: Array(projectedPlaces.reversed()),
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )
        let capacity = FriendFootprintScreenLayoutPolicy.visibleMarkerCapacity(
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            densityStyle: .dense
        )

        #expect(visibility.placeIDs.count <= capacity)
        #expect(visibility.placeIDs.count < projectedPlaces.count)
        #expect(visibility.placeIDs.count > 60)
        #expect(visibility.placeIDs == reversedVisibility.placeIDs)
        #expect(visibility.expandedPlaceIDs.isSubset(of: visibility.placeIDs))
        #expect(visibility.expandedPlaceIDs.count <= 2)
        #expect(visibility.densityStyle == .dense)
    }

    @Test
    @MainActor
    func rankedSamplingChoosesTheStrongestPlacePerAreaAndCoversTheScreen() {
        var projectedPlaces: [FriendFootprintProjectedPlace] = []
        var expectedIDs = Set<String>()

        for row in 0..<3 {
            for column in 0..<3 {
                for rank in 0..<5 {
                    let id = "cell-\(row)-\(column)-rank-\(rank)"
                    projectedPlaces.append(
                        FriendFootprintProjectedPlace(
                            id: id,
                            point: CGPoint(
                                x: 45 + CGFloat(column) * 60,
                                y: 55 + CGFloat(row) * 60
                            ),
                            friendCount: rank + 1
                        )
                    )
                    if rank == 4 { expectedIDs.insert(id) }
                }
            }
        }

        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projectedPlaces,
            reservedPoints: [],
            canvasSize: CGSize(width: 220, height: 240),
            topChromeBottom: 20,
            selectedID: nil
        )
        let reversed = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: Array(projectedPlaces.reversed()),
            reservedPoints: [],
            canvasSize: CGSize(width: 220, height: 240),
            topChromeBottom: 20,
            selectedID: nil
        )

        #expect(visibility.densityStyle == .dense)
        #expect(visibility.placeIDs == expectedIDs)
        #expect(reversed.placeIDs == expectedIDs)
    }

    @Test
    @MainActor
    func rankedSamplingKeepsThePreviousRepresentativeUntilAnExplicitRerank() {
        let candidates = [
            FriendFootprintProjectedPlace(
                id: "stronger-newcomer",
                point: CGPoint(x: 50, y: 60),
                friendCount: 20
            ),
            FriendFootprintProjectedPlace(
                id: "previous",
                point: CGPoint(x: 50, y: 60),
                friendCount: 2
            )
        ]
        let lowerRanked = (0..<8).map { index in
            FriendFootprintProjectedPlace(
                id: "lower-\(index)",
                point: CGPoint(x: 50, y: 60),
                friendCount: 1
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: candidates + lowerRanked,
            reservedPoints: [],
            canvasSize: CGSize(width: 100, height: 100),
            topChromeBottom: 1,
            selectedID: nil,
            previouslyVisibleIDs: ["previous"]
        )
        let reranked = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: candidates + lowerRanked,
            reservedPoints: [],
            canvasSize: CGSize(width: 100, height: 100),
            topChromeBottom: 1,
            selectedID: nil,
            previouslyVisibleIDs: []
        )

        #expect(visibility.densityStyle == .dense)
        #expect(visibility.placeIDs == ["previous"])
        #expect(reranked.placeIDs == ["stronger-newcomer"])
    }

    @Test
    @MainActor
    func rankedSamplingRetainsAdjacentRepresentativesAcrossAGridBoundaryShift() {
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: CGPoint(x: 31, y: 60),
            friendCount: 2
        )
        let second = FriendFootprintProjectedPlace(
            id: "second",
            point: CGPoint(x: 33, y: 60),
            friendCount: 20
        )
        let fillers = (0..<14).map { index in
            FriendFootprintProjectedPlace(
                id: "filler-\(index)",
                point: CGPoint(x: 85, y: 60),
                friendCount: 1
            )
        }
        let initial = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, second] + fillers,
            reservedPoints: [],
            canvasSize: CGSize(width: 140, height: 120),
            topChromeBottom: 1,
            selectedID: nil
        )
        let shiftedCandidates = ([first, second] + fillers).map { place in
            FriendFootprintProjectedPlace(
                id: place.id,
                point: CGPoint(x: place.point.x + 2, y: place.point.y),
                friendCount: place.friendCount
            )
        }
        let shifted = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: shiftedCandidates,
            reservedPoints: [],
            canvasSize: CGSize(width: 140, height: 120),
            topChromeBottom: 1,
            selectedID: nil,
            previouslyVisibleIDs: initial.placeIDs,
            previousDensityStyle: initial.densityStyle
        )

        #expect(initial.densityStyle == .dense)
        #expect(initial.placeIDs.contains(first.id))
        #expect(initial.placeIDs.contains(second.id))
        #expect(shifted.placeIDs.contains(first.id))
        #expect(shifted.placeIDs.contains(second.id))
    }

    @Test
    @MainActor
    func representativeContinuityKeepsPansButReranksMeaningfulZooms() {
        let initial = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.37, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        let panned = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.39, longitude: -122.01),
            span: MKCoordinateSpan(latitudeDelta: 0.081, longitudeDelta: 0.079)
        )
        let zoomedOut = MKCoordinateRegion(
            center: panned.center,
            span: MKCoordinateSpan(latitudeDelta: 0.095, longitudeDelta: 0.095)
        )

        #expect(
            FriendFootprintSamplingContinuityPolicy.shouldPreserveRepresentatives(
                from: initial,
                to: panned
            )
        )
        #expect(
            FriendFootprintSamplingContinuityPolicy.shouldPreserveRepresentatives(
                from: panned,
                to: zoomedOut
            ) == false
        )
        #expect(
            FriendFootprintSamplingContinuityPolicy.shouldPreserveRepresentatives(
                from: nil,
                to: initial
            ) == false
        )
    }

    @Test
    @MainActor
    func selectedLowRankFootprintReplacesTheCellRepresentative() {
        let selected = FriendFootprintProjectedPlace(
            id: "selected",
            point: CGPoint(x: 50, y: 60),
            friendCount: 1
        )
        let stronger = FriendFootprintProjectedPlace(
            id: "stronger",
            point: CGPoint(x: 50, y: 60),
            friendCount: 20
        )
        let fillers = (0..<8).map { index in
            FriendFootprintProjectedPlace(
                id: "filler-\(index)",
                point: CGPoint(x: 50, y: 60),
                friendCount: 5
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [selected, stronger] + fillers,
            reservedPoints: [],
            canvasSize: CGSize(width: 100, height: 100),
            topChromeBottom: 1,
            selectedID: selected.id
        )

        #expect(visibility.placeIDs == [selected.id])
        #expect(visibility.expandedPlaceIDs == [selected.id])
    }

    @Test
    @MainActor
    func exactlyOverlappingFootprintsRemainRepresented() {
        let point = CGPoint(x: 196, y: 420)
        let first = FriendFootprintProjectedPlace(
            id: "first",
            point: point,
            friendCount: 3
        )
        let second = FriendFootprintProjectedPlace(
            id: "second",
            point: point,
            friendCount: 2
        )
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: [first, second],
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(visibility.placeIDs == [first.id, second.id])
        #expect(visibility.expandedPlaceIDs == [first.id])
    }

    @Test
    @MainActor
    func friendFootprintCompactCircleKeepsOneSizeAcrossDensity() {
        let usableArea: CGFloat = 100_000

        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 29,
                usableArea: usableArea
            ) == .sparse
        )
        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 30,
                usableArea: usableArea
            ) == .medium
        )
        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 90,
                usableArea: usableArea
            ) == .dense
        )
        #expect(FriendFootprintDensityStyle.sparse.compactMarkerSize == 12)
        #expect(FriendFootprintDensityStyle.medium.compactMarkerSize == 12)
        #expect(FriendFootprintDensityStyle.dense.compactMarkerSize == 12)
        #expect(FriendFootprintDensityStyle.sparse.compactMarkerStrokeWidth > 0)
        #expect(FriendFootprintDensityStyle.medium.compactMarkerStrokeWidth > 0)
        #expect(FriendFootprintDensityStyle.dense.compactMarkerStrokeWidth > 0)
        for style in [
            FriendFootprintDensityStyle.sparse,
            .medium,
            .dense
        ] {
            #expect(style.compactControlSize == 16)
            #expect(style.compactControlSize >= style.compactMarkerSize)
            #expect(style.compactControlSize < style.visibleMarkerCellSize)
            #expect(style.compactMarkerOpacity == 0.84)
            #expect(style.compactMarkerStrokeOpacity == 0.9)
            #expect(style.compactMarkerStrokeWidth == 1)
        }
        #expect(
            FriendFootprintScreenOcclusionPolicy.compactMarkerClearance
                >= FriendFootprintDensityStyle.sparse.compactMarkerSize / 2
        )
    }

    @Test
    @MainActor
    func friendFootprintDensityStyleUsesHysteresisAtTierBoundaries() {
        let usableArea: CGFloat = 100_000

        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 75,
                usableArea: usableArea,
                previousStyle: .dense
            ) == .dense
        )
        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 69,
                usableArea: usableArea,
                previousStyle: .dense
            ) == .medium
        )
        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 25,
                usableArea: usableArea,
                previousStyle: .medium
            ) == .medium
        )
        #expect(
            FriendFootprintScreenLayoutPolicy.densityStyle(
                visibleCount: 19,
                usableArea: usableArea,
                previousStyle: .medium
            ) == .sparse
        )
    }

    @Test
    @MainActor
    func compactFriendFootprintButtonWaitsForMapMotionToSettle() {
        let gate = FriendFootprintMapInteractionGate()

        #expect(gate.allowsCompactTap(at: 10))
        gate.noteCameraMotion(at: 10)
        #expect(gate.allowsCompactTap(at: 10.149) == false)
        #expect(gate.allowsCompactTap(at: 10.15))

        gate.noteCameraMotion(at: 20)
        gate.noteCameraMotion(at: 20.1)
        #expect(gate.allowsCompactTap(at: 20.2) == false)
        #expect(gate.allowsCompactTap(at: 20.25))
    }

    @Test
    @MainActor
    func seattleLowDensityFootprintsAreNotNeedlesslySampled() {
        let seattle = MapTalkFriendFootprint.previewData.filter {
            $0.id.hasPrefix("sunnyvale-") == false
        }
        let projected = seattle.enumerated().map { index, footprint in
            FriendFootprintProjectedPlace(
                id: footprint.id,
                point: CGPoint(
                    x: 35 + CGFloat(index % 4) * 90,
                    y: 270 + CGFloat(index / 4) * 100
                ),
                friendCount: footprint.friendIDs.count
            )
        }
        let visibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projected,
            reservedPoints: [],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: nil
        )

        #expect(seattle.count == 17)
        #expect(visibility.densityStyle == .sparse)
        #expect(visibility.placeIDs == Set(seattle.map(\.id)))
    }

    @Test
    @MainActor
    func repeatedTapsCycleFootprintsAtTheSameRealPlace() {
        let first = footprint(
            id: "first",
            latitude: 37.3769,
            longitude: -122.0300
        )
        let second = footprint(
            id: "second",
            latitude: 37.3769,
            longitude: -122.0300
        )
        let topmost = footprint(
            id: "topmost",
            latitude: 37.3769,
            longitude: -122.0300
        )
        let nearbyButSeparate = footprint(
            id: "separate",
            latitude: 37.3770,
            longitude: -122.0300
        )
        let visible = [first, second, topmost, nearbyButSeparate]

        let initial = FriendFootprintTapSelectionPolicy.nextID(
            tappedID: topmost.id,
            selectedID: nil,
            visibleFootprints: visible
        )
        let next = FriendFootprintTapSelectionPolicy.nextID(
            tappedID: topmost.id,
            selectedID: topmost.id,
            visibleFootprints: visible
        )
        let afterNext = FriendFootprintTapSelectionPolicy.nextID(
            tappedID: topmost.id,
            selectedID: next,
            visibleFootprints: visible
        )

        #expect(initial == topmost.id)
        #expect(next == first.id)
        #expect(afterNext == second.id)
    }

    @Test
    @MainActor
    func friendFootprintSelectionCameraOnlyMovesCoveredPointAndKeepsZoom() {
        let canvas = CGSize(width: 393, height: 852)

        let alreadyVisible = FriendFootprintSelectionCameraPolicy.targetPoint(
            projectedPoint: CGPoint(x: 196, y: 420),
            canvasSize: canvas,
            topChromeBottom: 220,
            compactSheetFraction: 0.35
        )
        let covered = FriendFootprintSelectionCameraPolicy.targetPoint(
            projectedPoint: CGPoint(x: 196, y: 760),
            canvasSize: canvas,
            topChromeBottom: 220,
            compactSheetFraction: 0.35
        )
        let adjustedCenter = FriendFootprintSelectionCameraPolicy.adjustedCenter(
            selectedCoordinate: CLLocationCoordinate2D(latitude: 47.60, longitude: -122.30),
            coordinateAtTargetPoint: CLLocationCoordinate2D(
                latitude: 47.64,
                longitude: -122.34
            ),
            currentCenter: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33)
        )

        #expect(alreadyVisible == nil)
        #expect(covered?.x == 196)
        #expect(abs((covered?.y ?? 0) - 481.8) < 0.000_001)
        #expect(abs(adjustedCenter.latitude - 47.5836) < 0.000_001)
        #expect(abs(adjustedCenter.longitude - -122.3036) < 0.000_001)
    }

    @Test
    @MainActor
    func friendFootprintCompactModeKeepsEveryPlaceAtItsRealCoordinate() {
        let first = footprint(
            id: "first",
            latitude: 47.61,
            longitude: -122.33,
            friendIDs: [UUID(), UUID()]
        )
        let second = footprint(
            id: "second",
            latitude: 47.611,
            longitude: -122.331,
            friendIDs: [UUID()]
        )
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )

        let layout = FriendFootprintViewportPolicy.layout(
            footprints: [first, second],
            in: region,
            retaining: nil
        )

        #expect(layout.places.map(\.id) == [first.id, second.id])
        #expect(layout.places[0].coordinate.latitude == first.coordinate.latitude)
        #expect(layout.places[0].coordinate.longitude == first.coordinate.longitude)
        #expect(layout.places[1].coordinate.latitude == second.coordinate.latitude)
        #expect(layout.places[1].coordinate.longitude == second.coordinate.longitude)
    }

    @Test
    @MainActor
    func friendFootprintMarkersYieldToTopStoryChromeWithoutMovingCoordinates() {
        let canvas = CGSize(width: 393, height: 852)
        let chromeBottom: CGFloat = 220

        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: 251),
                canvasSize: canvas,
                topChromeBottom: chromeBottom
            )
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: 252),
                canvasSize: canvas,
                topChromeBottom: chromeBottom
            ) == false
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: 235),
                canvasSize: canvas,
                topChromeBottom: chromeBottom,
                clearance: FriendFootprintScreenOcclusionPolicy.compactMarkerClearance
            )
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: 236),
                canvasSize: canvas,
                topChromeBottom: chromeBottom,
                clearance: FriendFootprintScreenOcclusionPolicy.compactMarkerClearance
            ) == false
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: -80, y: 100),
                canvasSize: canvas,
                topChromeBottom: chromeBottom
            ) == false
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: -80),
                canvasSize: canvas,
                topChromeBottom: chromeBottom
            ) == false
        )
        #expect(
            FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: CGPoint(x: 196, y: 400),
                canvasSize: canvas,
                topChromeBottom: 0
            )
        )
    }

    private func footprint(
        id: String,
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees,
        friendIDs: [UUID] = [UUID()]
    ) -> MapTalkFriendFootprint {
        MapTalkFriendFootprint(
            id: id,
            placeName: id,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            category: .viewpoint,
            friendIDs: friendIDs
        )
    }

    private func makeActiveFeedPOI(
        id: UUID = UUID(),
        name: String,
        checkInDates: [Date],
        includesMedia: Bool = false
    ) -> RatedPOI {
        RatedPOI(
            poi: POI(
                id: id,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
                category: .viewpoint
            ),
            highlight: nil,
            secondary: nil,
            media: [],
            checkIns: checkInDates.map { date in
                RatedPOI.CheckIn(
                    userId: UUID(),
                    createdAt: date,
                    media: includesMedia
                        ? [
                            RatedPOI.Media(
                                kind: .photo(URL(fileURLWithPath: "/tmp/active-feed.jpg"))
                            )
                        ]
                        : []
                )
            },
            comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: [],
            isFavoritedByCurrentUser: false,
            favoritesCount: 0
        )
    }

    private func makeActiveFeedReel(
        id: UUID = UUID(),
        createdAt: Date
    ) -> RealPost {
        RealPost(
            id: id,
            userId: UUID(),
            center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
            radiusMeters: 200,
            message: "Active Reel",
            attachments: [],
            capsuleId: nil,
            likes: [],
            comments: [],
            visibility: .publicAll,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(StoryReadKeys.freshWindow)
        )
    }

    @MainActor
    private func makeEnvironment(archive: MyMapArchiveStore) -> AppEnvironment {
        AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: LocationServiceImpl(),
            notifications: NotificationServiceImpl(),
            activePOIRepo: InMemoryPOIRepository(),
            poiRepo: InMemoryPOIRepository(),
            realRepo: InMemoryRealRepository(),
            myMapArchive: archive
        )
    }

    private func makeBubble(
        id: UUID = UUID(),
        userID: UUID,
        title: String
    ) -> JourneyPost {
        JourneyPost(
            id: id,
            userId: userID,
            title: title,
            content: "",
            coordinate: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
            createdAt: .now,
            reels: [],
            pois: [],
            likes: [],
            comments: []
        )
    }
}

private final class DelayedLocationService: LocationService {
    let authorization = CurrentValueSubject<CLAuthorizationStatus, Never>(.notDetermined)
    let location = CurrentValueSubject<CLLocation?, Never>(nil)
    private(set) var requestCount = 0

    func requestWhenInUse() {
        requestCount += 1
    }
}

private final class FixedPOIRepository: POIRepository, ActivePOIRepository {
    let places: [RatedPOI]

    init(places: [RatedPOI]) {
        self.places = places
    }

    func near(_: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        Just(places).eraseToAnyPublisher()
    }

    func active(in _: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> {
        Just(places).eraseToAnyPublisher()
    }
}

private final class MutableActivePOIRepository: ActivePOIRepository {
    private let subject: CurrentValueSubject<[RatedPOI], Never>

    init(places: [RatedPOI]) {
        subject = CurrentValueSubject(places)
    }

    func active(in _: MKMapRect?) -> AnyPublisher<[RatedPOI], Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ places: [RatedPOI]) {
        subject.send(places)
    }
}

private final class MutablePOIRepository: POIRepository {
    private let subject: CurrentValueSubject<[RatedPOI], Never>

    init(places: [RatedPOI]) {
        subject = CurrentValueSubject(places)
    }

    func near(_: CLLocationCoordinate2D) -> AnyPublisher<[RatedPOI], Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ places: [RatedPOI]) {
        subject.send(places)
    }
}

private final class FixedRealRepository: RealRepository {
    let activeReals: [RealPost]
    let mapReals: [RealPost]

    init(reals: [RealPost]) {
        activeReals = reals
        mapReals = reals
    }

    init(activeReals: [RealPost], mapReals: [RealPost]) {
        self.activeReals = activeReals
        self.mapReals = mapReals
    }

    func active(in region: MKMapRect?) -> AnyPublisher<[RealPost], Never> {
        Just(region == nil ? activeReals : mapReals).eraseToAnyPublisher()
    }
}

private final class MutableRealRepository: RealRepository {
    private let activeSubject: CurrentValueSubject<[RealPost], Never>
    private let mapSubject: CurrentValueSubject<[RealPost], Never>

    init(activeReals: [RealPost], mapReals: [RealPost]) {
        activeSubject = CurrentValueSubject(activeReals)
        mapSubject = CurrentValueSubject(mapReals)
    }

    func active(in region: MKMapRect?) -> AnyPublisher<[RealPost], Never> {
        (region == nil ? activeSubject : mapSubject).eraseToAnyPublisher()
    }

    func sendActive(_ reals: [RealPost]) {
        activeSubject.send(reals)
    }

    func sendMap(_ reals: [RealPost]) {
        mapSubject.send(reals)
    }
}

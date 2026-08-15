import CoreLocation
import Foundation
import Testing
@testable import maptalk

struct maptalkTests {

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

    @MainActor
    private func makeEnvironment(archive: MyMapArchiveStore) -> AppEnvironment {
        AppEnvironment(
            build: .init(configuration: .debug, featureFlags: .mock),
            location: LocationServiceImpl(),
            notifications: NotificationServiceImpl(),
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

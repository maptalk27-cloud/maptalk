import CoreLocation
import Foundation
import SwiftUI
import Testing
@testable import maptalk

@MainActor
struct POIStorySelectionTests {
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func downloadedVisitMediaPreservesPassedPlaceMetadataAndMembership() throws {
        let pending = visit(201, author: alice, media: [], secondsAgo: 10)
        let older = visit(202, author: bob, media: [photo(102)], secondsAgo: 30)
        let original = rated([pending, older])
        let video = RatedPOI.Media(id: uuid(103), kind: .video(url: url(103), poster: nil))
        var downloaded = rated([
            visit(201, author: alice, media: [video], secondsAgo: 999),
            visit(203, author: bob, media: [photo(104)], secondsAgo: 1)
        ])
        downloaded.highlight = "Must not replace the place's text"
        downloaded.comments = []
        downloaded.favoritesCount = 999
        downloaded.endorsements.hype = 999
        downloaded.checkIns[0].comment = "Must not replace the visit's text"
        let merged = ExperienceDetailView.mergingMedia(into: original, from: downloaded)

        #expect(merged.checkIns.map(\.id) == original.checkIns.map(\.id))
        #expect(merged.checkIns[0].media == [video])
        #expect(merged.checkIns[0].createdAt == pending.createdAt)
        #expect(merged.checkIns[0].comment == pending.comment)
        #expect(merged.checkIns[0].endorsement == pending.endorsement)
        #expect(merged.checkIns[1] == older)
        #expect(Set(merged.media.map(\.id)) == Set([uuid(102), uuid(103)]))
        #expect(merged.poi == original.poi)
        #expect(merged.highlight == original.highlight)
        #expect(merged.secondary == original.secondary)
        #expect(merged.comments == original.comments)
        #expect(merged.endorsements == original.endorsements)
        #expect(merged.tags == original.tags)
        #expect(merged.favoritesCount == original.favoritesCount)
        #expect(merged.isFavoritedByCurrentUser == original.isFavoritedByCurrentUser)

        let detail = ExperienceDetailView(mode: .poi(merged), isExpanded: false, poiBrowsingUserID: alice)
        let selection = try #require(detail.browsingPOISelection(for: merged))
        #expect(selection.checkIn.id == pending.id)
        #expect(selection.media == video)
    }

    @Test
    func downloadingDoesNotExpandAnIntentionallyFilteredGalleryOrAcceptOtherOwnersMedia() {
        let included = photo(101)
        let hiddenFromGallery = photo(102)
        var original = rated([visit(201, author: alice, media: [included, hiddenFromGallery], secondsAgo: 10)])
        original.media = [included]
        let differentOwner = rated([visit(201, author: bob, media: [photo(103)], secondsAgo: 1)])
        let unchanged = ExperienceDetailView.mergingMedia(into: original, from: differentOwner)
        #expect(unchanged.checkIns == original.checkIns)
        #expect(unchanged.media == [included])
        #expect(ExperienceDetailView.mergingMedia(into: original, from: original).media == [included])
    }

    @Test
    func downloadedPostMediaDoesNotChangePrivacyCaptionTimeOrEngagement() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let post = RealPost(id: uuid(701), userId: alice,
            center: .init(latitude: 47.6, longitude: -122.3), radiusMeters: 50,
            message: "Original caption", attachments: [], capsuleId: uuid(702), likes: [bob],
            comments: [.init(id: uuid(703), userId: bob, text: "Original comment", createdAt: date)],
            visibility: .privateOnly, createdAt: date, expiresAt: date.addingTimeInterval(3_600),
            publishedAt: nil, locationName: "Original location", locationID: uuid(704))
        var hydrated = post
        hydrated.attachments = [.init(id: uuid(705), kind: .video(url: url(705), poster: nil))]
        hydrated.message = "Stale caption"
        hydrated.likes = []
        hydrated.comments = []
        hydrated.visibility = .publicAll
        hydrated.createdAt = .now
        hydrated.locationName = "Different name"
        hydrated.capsuleId = nil
        let merged = ExperienceDetailView.mergingMedia(into: post, from: hydrated)

        #expect(merged.attachments == hydrated.attachments)
        #expect(merged.message == post.message)
        #expect(merged.visibility == post.visibility)
        #expect(merged.likes == post.likes)
        #expect(merged.comments == post.comments)
        #expect(merged.createdAt == post.createdAt)
        #expect(merged.publishedAt == post.publishedAt)
        #expect(merged.expiresAt == post.expiresAt)
        #expect(merged.center.latitude == post.center.latitude)
        #expect(merged.center.longitude == post.center.longitude)
        #expect(merged.locationName == post.locationName)
        #expect(merged.locationID == post.locationID)
        #expect(merged.capsuleId == post.capsuleId)
    }

    @Test
    func selectedSliceUsesOriginalCardWithoutReplacingPlaceStatistics() throws {
        let first = photo(101)
        let selectedMedia = photo(102)
        let selectedVisit = visit(201, author: alice, media: [first, selectedMedia], secondsAgo: 30)
        let repeatVisit = visit(202, author: alice, media: [photo(103)], secondsAgo: 10)
        let friendVisit = visit(203, author: bob, media: [photo(104)], secondsAgo: 5)
        let place = rated([selectedVisit, repeatVisit, friendVisit])
        let detail = ExperienceDetailView(mode: .poi(place),
            poiStorySelection: .init(checkIn: selectedVisit, media: selectedMedia), userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(data.poiInfo?.name == place.poi.name)
        #expect(data.poiInfo?.category == place.poi.category)
        #expect(data.poiInfo?.directionsDestination == MapDirectionsDestination(
            name: place.poi.name, coordinate: place.poi.coordinate))
        #expect(detail.poi?.poi.coordinate.latitude == place.poi.coordinate.latitude)
        #expect(detail.poi?.poi.coordinate.longitude == place.poi.coordinate.longitude)
        #expect(data.poiStats?.checkIns == 2)
        #expect(data.poiStats?.comments == place.comments.count)
        #expect(data.poiStats?.favorites == place.favoritesCount)
        #expect(data.poiStats?.endorsements == place.endorsements)
        #expect(data.poiStats?.commentTarget == .place(place.id))
        #expect(data.engagement.friendComments.map(\.id) == place.comments.map(\.id))
        #expect(data.badges == detail.poiBadgeStrings(for: place))
        #expect(detail.poi?.isFavoritedByCurrentUser == true)

        #expect(data.recentSharers.map(\.userId) == [alice])
        #expect(data.engagement.storyContributors.map(\.userId) == [alice])
        let contributor = try #require(data.recentSharers.first)
        #expect(contributor.items.map(\.id) == [selectedMedia.id])
        #expect(contributor.items.map(\.readKey) == [StoryReadKeys.poiStoryPage(
            poiId: place.id, checkInId: selectedVisit.id,
            mediaId: selectedMedia.id, timestamp: selectedVisit.activityDate)])
        #expect(data.engagement.friendLikes.map(\.userId) == [alice])
        #expect(data.engagement.friendLikes.first?.timestamp == selectedVisit.activityDate)
        #expect(data.story?.galleryItems.count == 1)
        #expect(data.story?.galleryItems.first?.content == .photo(url(102)))
        // The same selection helper is used by the original safety menu.
        #expect(detail.poiStoryCheckIns(for: place).map(\.id) == [selectedVisit.id])
        #expect(detail.poiStoryCheckIns(for: place).flatMap(\.media) == [selectedMedia])
        #expect(place.checkIns.count == 3)
        #expect(place.media.count == 4)
    }

    @Test
    func authoritativeSelectedVisitDoesNotRequireAnOlderPlaceProjectionToContainIt() throws {
        let place = rated([visit(201, author: bob, media: [photo(101)], secondsAgo: 30)])
        let currentMedia = photo(102)
        let freshVisit = visit(202, author: alice, media: [currentMedia, photo(103)], secondsAgo: 1)
        let detail = ExperienceDetailView(mode: .poi(place),
            poiStorySelection: .init(checkIn: freshVisit, media: currentMedia), userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(data.recentSharers.map(\.userId) == [alice])
        #expect(data.recentSharers.flatMap(\.items).map(\.id) == [currentMedia.id])
        #expect(data.engagement.friendLikes.map(\.userId) == [alice])
        #expect(detail.poiStoryCheckIns(for: place).first?.id == freshVisit.id)
        #expect(data.poiStats?.checkIns == place.checkInPersonCount)
        #expect(place.checkIns.map(\.id) == [uuid(201)])
    }

    @Test
    func defaultCardKeepsAllContributorsAndOriginalGallery() {
        let visits = [visit(201, author: alice, media: [photo(101), photo(102)], secondsAgo: 30),
                      visit(202, author: bob, media: [photo(103)], secondsAgo: 10)]
        let place = rated(visits)
        let detail = ExperienceDetailView(mode: .poi(place), userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(detail.poiStorySelection == nil)
        #expect(Set(data.recentSharers.map(\.userId)) == Set([alice, bob]))
        #expect(Set(data.recentSharers.flatMap(\.items).map(\.id)) == Set(place.media.map(\.id)))
        #expect(Set(data.engagement.friendLikes.compactMap(\.userId)) == Set([alice, bob]))
        #expect(data.story?.galleryItems.count == place.media.count)
        #expect(detail.poiStoryCheckIns(for: place) == visits)
        #expect(ExperienceDetailView(ratedPOI: place, isExpanded: false).poiStorySelection == nil)
    }

    @Test
    func featuredStoryMediaKeepsOriginalPlaceHistory() {
        let selectedMedia = photo(101)
        let visits = [visit(201, author: alice, media: [selectedMedia], secondsAgo: 30),
                      visit(202, author: bob, media: [photo(102)], secondsAgo: 10)]
        let place = rated(visits)
        let detail = ExperienceDetailView(mode: .poi(place), isExpanded: true,
            expandedPOIMedia: selectedMedia, userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(detail.expandedPOIMedia == selectedMedia)
        #expect(data.poiInfo?.directionsDestination == MapDirectionsDestination(
            name: place.poi.name, coordinate: place.poi.coordinate))
        #expect(detail.poiStorySelection == nil)
        #expect(detail.poiStoryCheckIns(for: place) == visits)
        #expect(Set(data.engagement.storyContributors.map(\.userId)) == Set([alice, bob]))
        #expect(data.poiStats?.commentTarget == .place(place.id))
        #expect(data.engagement.friendComments.map(\.id) == place.comments.map(\.id))
        #expect(ExperienceDetailView(ratedPOI: place, isExpanded: true).expandedPOIMedia == nil)
    }

    @Test
    func directMapCardKeepsHistoricalPlaybackAfterFeedExpiry() throws {
        let oldPhoto = photo(101)
        let oldVisit = visit(201, author: alice, media: [oldPhoto], secondsAgo: 30 * 86_400)
        let recentVisit = visit(202, author: bob, media: [photo(102)], secondsAgo: 30)
        let place = rated([oldVisit, recentVisit])
        let detail = ExperienceDetailView(ratedPOI: place, isExpanded: true, userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(detail.poiStorySelection == nil)
        #expect(data.recentSharers.map(\.userId) == [bob])
        let historicalPerson = try #require(data.engagement.storyContributors.first { $0.userId == alice })
        #expect(historicalPerson.items.map(\.id) == [oldPhoto.id])
        #expect(Set(data.engagement.friendLikes.compactMap(\.userId)) == Set([alice, bob]))
        #expect(detail.poiStoryCheckIns(for: place).map(\.id) == [oldVisit.id, recentVisit.id])
    }

    @Test
    func unavailableSelectedMediaNeverFallsBackToAnotherSliceOrPerson() {
        let selectedVisit = visit(201, author: alice, media: [photo(101), photo(102)], secondsAgo: 30)
        let place = rated([selectedVisit, visit(202, author: bob, media: [photo(103)], secondsAgo: 10)])
        let detail = ExperienceDetailView(mode: .poi(place),
            poiStorySelection: .init(checkIn: selectedVisit, media: nil), userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(data.story == nil)
        #expect(data.recentSharers.isEmpty)
        #expect(data.engagement.storyContributors.isEmpty)
        #expect(data.engagement.friendLikes.map(\.userId) == [alice])
        #expect(detail.poiStoryCheckIns(for: place).first?.media.isEmpty == true)
        #expect(data.poiStats?.checkIns == 2)
        #expect(data.poiStats?.comments == place.comments.count)
    }

    @Test
    func locationOnlyVisitDoesNotBorrowTheAuthorsPreviousPhotos() {
        let oldVisit = visit(201, author: alice, media: [photo(101)], secondsAgo: 30)
        let locationOnly = visit(202, author: alice, media: [], secondsAgo: 1)
        let place = rated([oldVisit, locationOnly, visit(203, author: bob, media: [photo(102)], secondsAgo: 10)])
        let detail = ExperienceDetailView(mode: .poi(place),
            poiStorySelection: .init(checkIn: locationOnly, media: nil), userProvider: user)
        let data = detail.contentData(for: .poi(place))

        #expect(data.story == nil)
        #expect(data.recentSharers.isEmpty)
        #expect(data.engagement.storyContributors.isEmpty)
        #expect(data.engagement.friendLikes.map(\.userId) == [alice])
        #expect(data.engagement.friendLikes.first?.timestamp == locationOnly.activityDate)
        #expect(detail.poiStoryCheckIns(for: place).map(\.id) == [locationOnly.id])
        #expect(data.poiStats?.checkIns == 2)
    }

    @Test
    func personalBrowsingSelectsOwnersLatestVisitEvenAfterFeedExpiry() {
        let latest = visit(202, author: alice, media: [photo(102), photo(103)], secondsAgo: 30 * 86_400)
        let place = rated([
            visit(201, author: alice, media: [photo(101)], secondsAgo: 60 * 86_400),
            latest,
            visit(203, author: bob, media: [photo(104)], secondsAgo: 1)
        ])
        let pager = ExperienceDetailView.SequencePager(items: [.init(id: place.id, mode: .poi(place))])
        let detail = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: false, poiBrowsingUserID: alice, userProvider: user)

        #expect(detail.browsingPOISelection(for: place)?.checkIn.id == latest.id)
        #expect(detail.browsingPOISelection(for: place)?.media == latest.media.first)
        #expect(detail.poiStoryCheckIns(for: place).map(\.userId) == [alice])
        #expect(detail.galleryItems(for: place).map(\.content) == [.photo(url(102))])

        let expanded = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: true, poiBrowsingUserID: alice, userProvider: user)
        #expect(expanded.browsingPOISelection(for: place)?.media == latest.media.first)
        #expect(expanded.poiStoryCheckIns(for: place) == place.checkIns)
    }

    @Test
    func personalBrowsingDoesNotBorrowMediaForAnEmptyOrMissingVisit() {
        let latest = visit(202, author: alice, media: [], secondsAgo: 10)
        let place = rated([
            visit(201, author: alice, media: [photo(101)], secondsAgo: 30),
            latest,
            visit(203, author: bob, media: [photo(102)], secondsAgo: 1)
        ])
        let pager = ExperienceDetailView.SequencePager(items: [.init(id: place.id, mode: .poi(place))])
        let detail = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: false, poiBrowsingUserID: alice, userProvider: user)
        #expect(detail.browsingPOISelection(for: place)?.checkIn.id == latest.id)
        #expect(detail.browsingPOISelection(for: place)?.media == nil)
        #expect(detail.galleryItems(for: place).isEmpty)
        #expect(detail.poiStoryCheckIns(for: place) == [latest])

        let missingOwner = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: false, poiBrowsingUserID: uuid(999), userProvider: user)
        #expect(missingOwner.browsingPOISelection(for: place) == nil)
    }

    @Test
    func explicitMapPinKeepsPlaceOverviewWithoutChangingOtherPages() {
        let place = rated([visit(201, author: alice, media: [photo(101)], secondsAgo: 30),
                           visit(202, author: bob, media: [photo(102)], secondsAgo: 10)])
        let pager = ExperienceDetailView.SequencePager(items: [.init(id: place.id, mode: .poi(place))])
        let detail = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: false, poiBrowsingUserID: alice, poiOverviewID: place.id, userProvider: user)
        #expect(detail.browsingPOISelection(for: place) == nil)
        #expect(detail.poiStoryCheckIns(for: place) == place.checkIns)
        #expect(detail.galleryItems(for: place).count == place.media.count)

        let differentPin = ExperienceDetailView(sequencePager: pager, selection: .constant(place.id),
            isExpanded: false, poiBrowsingUserID: alice, poiOverviewID: uuid(999), userProvider: user)
        #expect(differentPin.browsingPOISelection(for: place)?.checkIn.userId == alice)
    }

    private func user(_ id: UUID) -> User? {
        User(id: id, handle: id == alice ? "alice" : "bob", avatarURL: nil)
    }

    private func visit(_ id: Int, author: UUID, media: [RatedPOI.Media], secondsAgo: TimeInterval) -> RatedPOI.CheckIn {
        .init(id: uuid(id), userId: author, createdAt: .now.addingTimeInterval(-secondsAgo),
            endorsement: .hype, media: media, tag: .explore)
    }

    private func rated(_ visits: [RatedPOI.CheckIn]) -> RatedPOI {
        .init(poi: .init(id: uuid(500), name: "Original place", coordinate: .init(latitude: 47.6, longitude: -122.3),
                        category: .viewpoint), highlight: "Original highlight", secondary: "Original secondary",
              media: visits.flatMap(\.media), checkIns: visits,
              comments: [.init(id: uuid(600), userId: bob, content: .text("Shared place discussion"), createdAt: .now)],
              endorsements: .init(hype: 3, solid: 2, meh: 1, questionable: 0),
              tags: [.init(tag: .explore, count: 6)], isFavoritedByCurrentUser: true, favoritesCount: 8)
    }

    private func photo(_ id: Int) -> RatedPOI.Media {
        .init(id: uuid(id), kind: .photo(url(id)))
    }

    private func url(_ id: Int) -> URL { URL(fileURLWithPath: "/tmp/poi-story-selection-\(id).jpg") }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

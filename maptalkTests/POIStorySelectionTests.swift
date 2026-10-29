import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct POIStorySelectionTests {
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

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

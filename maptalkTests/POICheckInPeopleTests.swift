import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct POICheckInPeopleTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func repeatVisitsHaveOneStableAvatarWithAllMediaAndUnreadKeys() throws {
        let person = UUID()
        let friend = UUID()
        let first = checkIn(user: person, secondsAgo: 1_000)
        let second = checkIn(user: person, secondsAgo: 100)
        let other = checkIn(user: friend, secondsAgo: 500)
        let place = rated([first, other, second])
        let group = try #require(MapStoryFeed.poiGroup(for: place, onlyRecentStories: true,
            userProvider: { User(id: $0, handle: "person", avatarURL: nil) }, now: now))

        #expect(group.sharers.map(\.id) == [person, friend])
        #expect(group.sharers.first?.timestamp == second.activityDate)
        #expect(group.sharers.first?.readKeys.count == 2)
        #expect(group.sharers.first?.hasStory == true)
        #expect(group.ratedPOI.checkIns == place.checkIns)
        #expect(group.ratedPOI.media.count == 3)
        let before = try #require(MapStoryFeed.poiGroup(for: rated([first, other]), onlyRecentStories: true,
            userProvider: { _ in nil }, now: now))
        let beforeKeys = Set(before.sharers.flatMap(\.readKeys))
        let newKeys = group.sharers.flatMap(\.readKeys).filter { !beforeKeys.contains($0) }
        #expect(newKeys.count == 1)
        #expect(newKeys.first == readKey(placeID: place.id, checkIn: second))
        #expect(before.sharers.first { $0.id == person }?.id == group.sharers.first?.id)
    }

    @Test
    func freshVisitsAreFilteredBeforeGroupingWithoutErasingOldVisits() throws {
        let person = UUID()
        let old = checkIn(user: person, secondsAgo: StoryReadKeys.freshWindow + 100)
        let fresh = checkIn(user: person, secondsAgo: 100, media: false)
        let place = rated([old, fresh])
        let recent = try #require(MapStoryFeed.poiGroup(for: place, onlyRecentStories: true,
            userProvider: { _ in nil }, now: now))
        #expect(recent.sharers.count == 1)
        #expect(recent.sharers.first?.hasStory == false)
        #expect(recent.sharers.first?.readKeys.isEmpty == true)
        #expect(recent.ratedPOI.checkIns.count == 2)
        let all = try #require(MapStoryFeed.poiGroup(for: place, onlyRecentStories: false,
            userProvider: { _ in nil }, now: now))
        #expect(all.sharers.count == 1)
        #expect(all.sharers.first?.readKeys.count == 1)
    }

    @Test
    func footprintsAndMarkerCountRepresentUniquePeopleUsingTheirLatestVisit() throws {
        let person = UUID()
        let friend = UUID()
        let old = checkIn(user: person, secondsAgo: 300)
        var latest = checkIn(user: person, secondsAgo: 10)
        latest.endorsement = .hype
        let place = rated([old, checkIn(user: friend, secondsAgo: 100), latest])
        let detail = ExperienceDetailView(mode: .poi(place))
        let footprints = detail.checkInEngagements(for: place)
        #expect(place.checkInPersonCount == 2)
        #expect(footprints.map(\.userId) == [person, friend])
        #expect(footprints.map(\.id) == [person, friend])
        #expect(footprints.first?.timestamp == latest.activityDate)
        #expect(footprints.first?.endorsement == .hype)
        #expect(detail.contentData(for: .poi(place)).poiStats?.checkIns == 2)
        #expect(place.checkIns.count == 3)
    }

    @Test
    func storyViewerAndFeedUseIdenticalKeysForDelayedPublishedVisits() throws {
        var visit = checkIn(user: UUID(), secondsAgo: 100_000)
        visit.publishedAt = now.addingTimeInterval(-10)
        let place = rated([visit])
        let group = try #require(MapStoryFeed.poiGroup(for: place, onlyRecentStories: true,
            userProvider: { _ in nil }, now: now))
        let contributors = ExperienceDetailView(mode: .poi(place)).poiStoryContributors(for: place)
        #expect(contributors.first?.mostRecent == visit.activityDate)
        #expect(contributors.flatMap(\.items).map(\.readKey) == group.sharers.flatMap(\.readKeys))
    }

    @Test
    func missingUserProfilesDoNotMergeDifferentPeopleAndPlaceBoundariesStaySeparate() throws {
        let first = checkIn(user: UUID(), secondsAgo: 10)
        let second = checkIn(user: UUID(), secondsAgo: 10)
        let place = rated([first, second])
        let group = try #require(MapStoryFeed.poiGroup(for: place, onlyRecentStories: true,
            userProvider: { _ in nil }, now: now))
        #expect(group.sharers.count == 2)
        #expect(Set(group.sharers.map(\.id)) == Set([first.userId, second.userId]))
        #expect(rated([first]).checkInPersonCount == 1)
        #expect(rated([second]).checkInPersonCount == 1)
        #expect(rated([]).checkInPersonCount == 0)
    }

    private func checkIn(user: UUID, secondsAgo: Double, media: Bool = true) -> RatedPOI.CheckIn {
        .init(userId: user, createdAt: now.addingTimeInterval(-secondsAgo),
            media: media ? [.init(kind: .photo(URL(fileURLWithPath: "/tmp/photo.jpg")))] : [])
    }

    private func rated(_ checkIns: [RatedPOI.CheckIn]) -> RatedPOI {
        .init(poi: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!, name: "One place",
                        coordinate: .init(latitude: 47.6, longitude: -122.3), category: .viewpoint),
            highlight: nil, secondary: nil, media: checkIns.flatMap(\.media), checkIns: checkIns, comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private func readKey(placeID: UUID, checkIn: RatedPOI.CheckIn) -> String {
        StoryReadKeys.poiStoryPage(poiId: placeID, checkInId: checkIn.id,
            mediaId: checkIn.media[0].id, timestamp: checkIn.activityDate)
    }
}

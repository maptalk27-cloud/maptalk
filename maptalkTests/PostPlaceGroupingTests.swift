import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct PostPlaceGroupingTests {
    @Test
    func homeGroupsOnlyConsecutivePostsFromTheSameAuthorAndPlace() {
        let author = UUID()
        let otherAuthor = UUID()
        let place = UUID()
        let first = makePost(authorID: author, locationID: place)
        let second = makePost(authorID: author, locationID: place)
        let authorBreak = makePost(authorID: otherAuthor, locationID: place)
        let third = makePost(authorID: author, locationID: place)
        let placeBreak = makePost(authorID: author, locationID: UUID())
        let fourth = makePost(authorID: author, locationID: place)

        let groups = PostPlaceGrouping.groups(
            [first, second, authorBreak, third, placeBreak, fourth], mode: .consecutive
        )

        #expect(groups.map { $0.posts.map(\.id) } == [
            [first.id, second.id], [authorBreak.id], [third.id], [placeBreak.id], [fourth.id]
        ])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test
    func profileMapAggregatesAcrossTimeWithoutCombiningAuthors() {
        let author = UUID()
        let place = UUID()
        let first = makePost(authorID: author, locationID: place)
        let otherPlace = makePost(authorID: author, locationID: UUID())
        let otherAuthor = makePost(authorID: UUID(), locationID: place)
        let earlier = makePost(authorID: author, locationID: place,
            date: Date(timeIntervalSince1970: 10))

        let groups = PostPlaceGrouping.groups([first, otherPlace, otherAuthor, earlier], mode: .aggregate)

        #expect(groups.map { $0.posts.map(\.id) } == [[first.id, earlier.id], [otherPlace.id], [otherAuthor.id]])
        #expect(groups[0].count == 2)
        #expect(groups[0].latestPost.id == first.id)
    }

    @Test
    func profileListKeepsEveryPostSeparateEvenWhenTheMapGroupsItsPlace() throws {
        let profile = UserProfileViewModel(environment: .bootstrap(), context: .me)
        let rows = profile.postActivities
        let orderedPosts = profile.reels.sorted {
            if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        #expect(rows.map(\.id) == orderedPosts.map(\.id))
        let mapGroup = try #require(PostPlaceGrouping.groups(orderedPosts, mode: .aggregate)
            .first(where: { $0.count > 1 }))
        for post in mapGroup.posts {
            let matches = rows.filter { $0.id == post.id }
            #expect(matches.count == 1, "Each same-place publication keeps its own list row")
            let row = try #require(matches.first)
            #expect(row.timestamp == post.activityDate)
            if case let .reel(original) = row.kind {
                #expect(original.id == post.id)
                #expect(original.message == post.message)
                #expect(original.attachments == post.attachments)
            } else {
                Issue.record("The profile Post list must not include POI rows")
            }
        }
    }

    @Test
    func stableLocationIdentityTakesPrecedenceOverChangedNamesOrCoordinates() {
        let author = UUID()
        let place = UUID()
        let first = makePost(authorID: author, locationID: place, name: "Old name")
        let second = makePost(authorID: author, locationID: place,
            coordinate: .init(latitude: 47.7, longitude: -122.4), name: "New name")
        let differentIdentity = makePost(authorID: author, locationID: UUID(), name: "Old name")

        let groups = PostPlaceGrouping.groups([first, second, differentIdentity], mode: .aggregate)

        #expect(groups.map(\.count) == [2, 1])
        #expect(PostPlaceGrouping.placeKey(for: first) == PostPlaceGrouping.placeKey(for: second))
    }

    @Test
    func legacyFallbackUsesExactCoordinatesAndConservativeNameNormalization() {
        let author = UUID()
        let first = makePost(authorID: author, name: "  Central\n PARK  ")
        let same = makePost(authorID: author, name: "central park")
        let nearby = makePost(authorID: author,
            coordinate: .init(latitude: 47.606200001, longitude: -122.3321), name: "Central Park")
        let otherName = makePost(authorID: author, name: "Central Park Cafe")

        let groups = PostPlaceGrouping.groups([first, same, nearby, otherName], mode: .aggregate)

        #expect(groups.map(\.count) == [2, 1, 1])
        #expect(PostPlaceGrouping.placeKey(for: nearby) != PostPlaceGrouping.placeKey(for: first))
    }

    @Test
    func legacyPostsWithoutNamesCanMatchOnlyAtExactlyTheSameCoordinates() {
        let author = UUID()
        let first = makePost(authorID: author, name: nil)
        let blank = makePost(authorID: author, name: " \n ")
        let nearby = makePost(authorID: author,
            coordinate: .init(latitude: 47.606200001, longitude: -122.3321), name: nil)
        let named = makePost(authorID: author, name: "Central Park")

        let groups = PostPlaceGrouping.groups([first, blank, nearby, named], mode: .aggregate)

        #expect(groups.map(\.count) == [2, 1, 1])
    }

    @Test
    func invalidCoordinatesNeverMergeEvenWithTheSameLocationIdentity() {
        let author = UUID()
        let place = UUID()
        let invalidCoordinates: [CLLocationCoordinate2D] = [
            .init(latitude: .nan, longitude: 0),
            .init(latitude: 0, longitude: .infinity),
            .init(latitude: 91, longitude: 0),
            .init(latitude: 0, longitude: 181)
        ]
        let posts = invalidCoordinates.flatMap { coordinate in
            [makePost(authorID: author, locationID: place, coordinate: coordinate),
             makePost(authorID: author, locationID: place, coordinate: coordinate)]
        }

        for mode: PostPlaceGrouping.Mode in [.consecutive, .aggregate] {
            let groups = PostPlaceGrouping.groups(posts, mode: mode)
            #expect(groups.count == posts.count)
            #expect(groups.allSatisfy { $0.count == 1 })
        }
        #expect(posts.allSatisfy { PostPlaceGrouping.placeKey(for: $0) == nil })
    }

    @Test
    func signedZeroCoordinatesHaveTheSameLegacyKey() {
        let author = UUID()
        let first = makePost(authorID: author, coordinate: .init(latitude: -0.0, longitude: 0.0))
        let second = makePost(authorID: author, coordinate: .init(latitude: 0.0, longitude: -0.0))

        #expect(PostPlaceGrouping.placeKey(for: first) == PostPlaceGrouping.placeKey(for: second))
    }

    @Test
    func duplicatePostIDsAreRemovedWithoutReorderingOrReplacingTheFirstCopy() {
        let author = UUID()
        let first = makePost(authorID: author)
        let second = makePost(authorID: author)
        var duplicate = first
        duplicate.message = "Do not replace the first fetched copy"

        for mode: PostPlaceGrouping.Mode in [.consecutive, .aggregate] {
            let groups = PostPlaceGrouping.groups([first, duplicate, second, first], mode: mode)
            #expect(groups.count == 1)
            #expect(groups[0].posts.map(\.id) == [first.id, second.id])
            #expect(groups[0].posts[0].message == first.message)
        }
    }

    @Test
    func latestPostUsesPublicationDateWithoutReorderingTheMembers() {
        let author = UUID()
        var first = makePost(authorID: author, date: Date(timeIntervalSince1970: 100))
        first.publishedAt = Date(timeIntervalSince1970: 110)
        var second = makePost(authorID: author, date: Date(timeIntervalSince1970: 10))
        second.publishedAt = Date(timeIntervalSince1970: 200)

        let group = PostPlaceGrouping.groups([first, second], mode: .aggregate)[0]

        #expect(group.posts.map(\.id) == [first.id, second.id])
        #expect(group.latestPost.id == second.id)
    }

    @Test
    func groupingPreservesIndividualPostMetadataAndTotalCount() {
        let author = UUID()
        var first = makePost(authorID: author)
        first.visibility = .privateOnly
        first.publishedAt = Date(timeIntervalSince1970: 120)
        first.comments = [.init(userId: UUID(), text: "Original comment")]
        first.likes = [UUID()]
        first.attachments = [.init(kind: .emoji("🌲"))]
        let second = makePost(authorID: author)

        let groups = PostPlaceGrouping.groups([first, second], mode: .aggregate)
        let preserved = groups[0].posts[0]

        #expect(groups.reduce(0) { $0 + $1.count } == 2)
        #expect(preserved.id == first.id)
        #expect(preserved.createdAt == first.createdAt)
        #expect(preserved.publishedAt == first.publishedAt)
        #expect(preserved.expiresAt == first.expiresAt)
        #expect(preserved.visibility == .privateOnly)
        #expect(preserved.comments == first.comments)
        #expect(preserved.likes == first.likes)
        #expect(preserved.attachments == first.attachments)
    }

    @Test
    func groupIdentityIsStableWhenAppendingMembersAndEmptyInputIsEmpty() {
        let author = UUID()
        let first = makePost(authorID: author)
        let second = makePost(authorID: author)

        for mode: PostPlaceGrouping.Mode in [.consecutive, .aggregate] {
            #expect(PostPlaceGrouping.groups([], mode: mode).isEmpty)
            #expect(PostPlaceGrouping.groups([first], mode: mode)[0].id
                == PostPlaceGrouping.groups([first, second], mode: mode)[0].id)
        }
        #expect(PostPlaceGrouping.groups([first], mode: .aggregate)[0].id
            == PostPlaceGrouping.groups([second, first], mode: .aggregate)[0].id)
    }

    @Test
    func stableAndLegacyPlaceIdentitiesAreNotGuessedToBeTheSame() {
        let author = UUID()
        let stable = makePost(authorID: author, locationID: UUID())
        let legacy = makePost(authorID: author)

        #expect(PostPlaceGrouping.groups([stable, legacy], mode: .aggregate).map(\.count) == [1, 1])
    }

    @Test
    func myMapGroupsPostsAcrossDatesButKeepsPOIRowsAndOriginalRecords() {
        let author = UUID()
        let first = makePost(authorID: author)
        let otherPlace = makePost(authorID: author, locationID: UUID())
        let earlier = makePost(authorID: author, date: Date(timeIntervalSince1970: 10))
        let poi = PreviewData.sampleRatedPOIs[0]
        let originalRecords = [
            record(first),
            UserMapRecord(id: poi.id, timestamp: Date(timeIntervalSince1970: 80), kind: .poi(poi)),
            record(otherPlace),
            record(earlier)
        ]

        let rows = UserMapRecordPlaceGroup.make(originalRecords)

        #expect(rows.map { $0.records.map(\.id) } == [[first.id, earlier.id], [poi.id], [otherPlace.id]])
        #expect(rows.reduce(0) { $0 + $1.records.count } == originalRecords.count)
        #expect(rows[0].representative.id == first.id)
        #expect(rows[0].records[1].timestamp == earlier.activityDate)
        #expect(rows.first(where: { $0.records.contains(where: { $0.id == earlier.id }) })?.id == rows[0].id,
                "Returning from an older Post must find its existing place row")
    }

    @Test
    func myMapGroupsOnlyTheFilteredInputAndKeepsSelectionModeIndividual() {
        let author = UUID()
        let newer = makePost(authorID: author, date: Date(timeIntervalSince1970: 200))
        let older = makePost(authorID: author, date: Date(timeIntervalSince1970: 100))
        let originals = [record(newer), record(older)]
        let dateMatches = originals.filter { $0.timestamp < Date(timeIntervalSince1970: 150) }

        let filteredRows = UserMapRecordPlaceGroup.make(dateMatches)
        let selectionRows = UserMapRecordPlaceGroup.make(originals, aggregatePosts: false)

        #expect(filteredRows.count == 1)
        #expect(filteredRows[0].records.map(\.id) == [older.id])
        #expect(selectionRows.map { $0.records.map(\.id) } == [[newer.id], [older.id]])
    }

    private func record(_ post: RealPost) -> UserMapRecord {
        UserMapRecord(id: post.id, timestamp: post.activityDate, kind: .reel(post))
    }

    private func makePost(
        authorID: UUID,
        locationID: UUID? = nil,
        coordinate: CLLocationCoordinate2D = .init(latitude: 47.6062, longitude: -122.3321),
        name: String? = "Park",
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> RealPost {
        var post = RealPost(id: UUID(), userId: authorID, center: coordinate, radiusMeters: 100,
            message: "Original caption", attachments: [], likes: [], comments: [], visibility: .publicAll,
            createdAt: date, expiresAt: date.addingTimeInterval(86_400), locationName: name)
        post.locationID = locationID
        return post
    }
}

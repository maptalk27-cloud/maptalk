import Foundation
import Testing
@testable import maptalk

@MainActor
struct PostPresentationDateTests {
    @Test
    func publicAndArchivedCardsUseTheSamePublicationDate() {
        var post = PreviewData.sampleReals[0]
        post.createdAt = Date(timeIntervalSince1970: 1_792_670_400)
        post.publishedAt = post.createdAt.addingTimeInterval(4 * 86_400)
        post.visibility = .publicAll
        #expect(post.cardDisplayDate == post.publishedAt)
        post.visibility = .privateOnly
        #expect(post.cardDisplayDate == post.publishedAt)
        post.visibility = .publicAll
        post.publishedAt = nil
        #expect(post.cardDisplayDate == post.createdAt)
    }

    @Test
    func neverPublishedPrivateMemoryKeepsItsOriginalSavedDate() {
        var post = PreviewData.sampleReals[0]
        post.createdAt = Date(timeIntervalSince1970: 1_792_670_400)
        post.publishedAt = nil
        post.visibility = .privateOnly

        #expect(post.cardDisplayDate == post.createdAt)
        #expect(UserMapRecord.make(reels: [post], footprints: []).first?.timestamp == post.createdAt)
    }

    @Test
    func myMapAndMapFeedUsePublicationOrderInsteadOfCaptureOrder() {
        let now = Date(timeIntervalSince1970: 1_792_670_400)
        var reel = PreviewData.sampleReals[0]
        reel.createdAt = now.addingTimeInterval(-5 * 86_400)
        reel.publishedAt = now.addingTimeInterval(-60)
        var place = PreviewData.sampleRatedPOIs[0]
        let latestPublication = RatedPOI.CheckIn(userId: reel.userId,
            createdAt: now.addingTimeInterval(-7 * 86_400),
            publishedAt: now.addingTimeInterval(-120))
        let newerCapture = RatedPOI.CheckIn(userId: reel.userId,
            createdAt: now.addingTimeInterval(-86_400),
            publishedAt: now.addingTimeInterval(-180))
        place.checkIns = [newerCapture, latestPublication]
        let footprint = UserMapViewModel.Footprint(ratedPOI: place, visits: place.checkIns)

        let records = UserMapRecord.make(reels: [reel], footprints: [footprint])
        let feed = MapStoryFeed.items(reals: [reel], ratedPOIs: [place],
            onlyRecentPOIStories: true, userProvider: { _ in nil }, now: now)

        #expect(footprint.latestVisit == latestPublication.publishedAt)
        #expect(records.map(\.id) == [reel.id, place.id])
        #expect(records.map(\.timestamp) == feed.map(\.timestamp))
        #expect(records.map(\.id) == feed.map(\.id))
        #expect(place.checkIns[0].createdAt == newerCapture.createdAt,
                "Presentation must not rewrite original capture metadata")
    }

    @Test
    func recentLocalUpdateDoesNotExtendTheOriginalFeedWindow() {
        let now = Date(timeIntervalSince1970: 1_792_670_400)
        var post = PreviewData.sampleReals[0]
        post.createdAt = now
        post.publishedAt = now.addingTimeInterval(-StoryReadKeys.freshWindow)
        post.expiresAt = now.addingTimeInterval(StoryReadKeys.freshWindow)

        #expect(!StoryReadKeys.isActive(post, asOf: now))
        #expect(post.cardDisplayDate == post.publishedAt)
        #expect(UserMapRecord.make(reels: [post], footprints: []).first?.timestamp == post.publishedAt)
    }
}

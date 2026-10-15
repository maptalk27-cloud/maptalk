import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct MapTalkActivityRevisitTests {
    @Test
    func resolvesTheExactReelAndPlaceSnapshotsAndPreservesCommentFocus() throws {
        var reel = makeReel(message: "Requested Reel")
        let commentID = UUID()
        reel.comments = [.init(id: commentID, userId: UUID(), text: "Requested comment")]
        let reelRoute = try #require(MapTalkActivityRoute.resolve(
            event(.reel(reel.id), commentID: commentID),
            reals: [makeReel(message: "First feed item"), reel],
            places: [], journeyProvider: { _ in nil }
        ))
        reel.message = "Changed after navigation"
        reel.comments.removeAll()

        guard case let .reel(reelSnapshot) = reelRoute.content else {
            Issue.record("A Reel notification must resolve to its Reel")
            return
        }
        #expect(reelSnapshot.id == reel.id)
        #expect(reelSnapshot.message == "Requested Reel")
        #expect(reelSnapshot.comments.map(\.id) == [commentID])
        #expect(reelRoute.commentID == commentID)

        var place = makePlace(name: "Requested Place")
        place.comments = [.init(id: commentID, userId: UUID(), content: .text("Place note"))]
        let placeRoute = try #require(MapTalkActivityRoute.resolve(
            event(.place(place.id), commentID: commentID),
            reals: [reel], places: [makePlace(name: "First Place"), place],
            journeyProvider: { _ in nil }
        ))
        place.highlight = "Changed after navigation"
        place.comments.removeAll()

        guard case let .place(placeSnapshot) = placeRoute.content else {
            Issue.record("A Place notification must resolve to its Place")
            return
        }
        #expect(placeSnapshot.id == place.id)
        #expect(placeSnapshot.poi.name == "Requested Place")
        #expect(placeSnapshot.highlight == "Original highlight")
        #expect(placeSnapshot.comments.map(\.id) == [commentID])
        #expect(placeRoute.commentID == commentID)
    }

    @Test
    func bubbleNotificationsOpenTheBubbleItselfEvenWhenItHasNoMembers() throws {
        let commentID = UUID()
        let member = makeReel(message: "Bubble member, not the notification target")
        for members in [[], [member]] {
            let bubble = makeBubble(reels: members, commentID: commentID)
            var parentReel = makeReel(message: "Parent Reel, not the notification target")
            parentReel.capsuleId = bubble.id
            var requestedBubbleIDs: [UUID] = []
            let route = try #require(MapTalkActivityRoute.resolve(
                event(.bubble(bubble.id), commentID: commentID),
                reals: [parentReel, member], places: [],
                journeyProvider: { id in
                    requestedBubbleIDs.append(id)
                    return id == bubble.id ? bubble : nil
                }
            ))

            guard case let .bubble(snapshot) = route.content else {
                Issue.record("A Bubble notification must not substitute its parent or first member")
                return
            }
            #expect(requestedBubbleIDs == [bubble.id])
            #expect(snapshot.id == bubble.id)
            #expect(snapshot.title == bubble.title)
            #expect(snapshot.reels.map(\.id) == members.map(\.id))
            #expect(snapshot.comments.map(\.id) == [commentID])
            #expect(route.commentID == commentID)
            #expect(route.id == route.identifier)
        }
    }

    @Test
    func missingTargetsDoNotFallBackToAnUnrelatedFeedItem() {
        let missingID = UUID()
        let destinations: [MapTalkActivityEvent.Target.Destination] = [
            .reel(missingID), .place(missingID), .bubble(missingID)
        ]
        for destination in destinations {
            let route = MapTalkActivityRoute.resolve(
                event(destination, commentID: UUID()),
                reals: [makeReel(message: "Unrelated Reel")],
                places: [makePlace(name: "Unrelated Place")],
                journeyProvider: { _ in nil }
            )
            #expect(route == nil)
        }
    }

    @Test
    func standaloneDetailStartsExpandedWithoutAFeedPager() {
        let commentID = UUID()
        let reel = makeReel(message: "Standalone Reel")
        let place = makePlace(name: "Standalone Place")
        let bubble = makeBubble(reels: [], commentID: commentID)
        let modes: [ExperienceDetailView.Mode] = [
            .real(reel, nil), .poi(place), .journey(bubble)
        ]

        for mode in modes {
            let detail = ExperienceDetailView(mode: mode)
            #expect(detail.isExpanded)
            // This is the explicit no-feed-pager contract of the standalone
            // initializer, not an assertion about SwiftUI's view hierarchy.
            #expect(detail.sequenceContext == nil)
            switch (mode, detail.currentMode) {
            case let (.real(expected, _), .real(actual, _)):
                #expect(actual.id == expected.id)
            case let (.poi(expected), .poi(actual)):
                #expect(actual.id == expected.id)
            case let (.journey(expected), .journey(actual)):
                #expect(actual.id == expected.id)
            default:
                Issue.record("Standalone detail must retain its supplied content kind")
            }
        }
    }

    private func event(
        _ destination: MapTalkActivityEvent.Target.Destination,
        commentID: UUID
    ) -> MapTalkActivityEvent {
        MapTalkActivityEvent(
            id: "comment-\(commentID)", actor: User(id: UUID(), handle: "friend", avatarURL: nil),
            kind: .comment, action: "Comment", detail: "A comment", timestamp: nil,
            target: .init(title: "Target", kindLabel: "Post", thumbnail: .symbol("text.bubble"), destination: destination),
            commentID: commentID
        )
    }

    private func makeReel(message: String) -> RealPost {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return RealPost(
            id: UUID(), userId: UUID(), center: .init(latitude: 47.6, longitude: -122.3),
            radiusMeters: 100, message: message, attachments: [], likes: [], comments: [],
            visibility: .publicAll, createdAt: now, expiresAt: now.addingTimeInterval(86_400)
        )
    }

    private func makePlace(name: String) -> RatedPOI {
        RatedPOI(
            poi: .init(id: UUID(), name: name, coordinate: .init(latitude: 47.6, longitude: -122.3), category: .viewpoint),
            highlight: "Original highlight", secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0
        )
    }

    private func makeBubble(reels: [RealPost], commentID: UUID) -> JourneyPost {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return JourneyPost(
            id: UUID(), userId: UUID(), title: "Requested Bubble", content: "Snapshot",
            coordinate: .init(latitude: 47.6, longitude: -122.3), createdAt: now,
            reels: reels, pois: [], likes: [],
            comments: [.init(id: commentID, userId: UUID(), text: "Bubble comment", createdAt: now)]
        )
    }
}

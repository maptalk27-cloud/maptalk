import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct MapTalkActivityFeedTests {
    @Test
    func eachLikeHasItsOwnRowWithoutHidingCommentsOrTruncatingTheList() {
        let ownerID = UUID()
        let users = (0..<8).map { User(id: UUID(), handle: "friend\($0)", avatarURL: nil) }
        var reel = makeReel(ownerID: ownerID, likes: users.map(\.id))
        let comment = RealPost.Comment(userId: users[0].id, text: "See you there")
        reel.comments = [comment]

        let events = MapTalkActivityFeed.events(
            reals: [reel], ratedPOIs: [], bubbles: [], currentUserID: ownerID,
            userProvider: { id in users.first { $0.id == id } }
        )
        let likes = events.filter { $0.kind == .like }

        #expect(events.count == 9)
        #expect(likes.map(\.actor.id) == users.map(\.id))
        #expect(Set(events.map(\.id)).count == events.count)
        #expect(events.contains { $0.kind == .comment && $0.detail == comment.text })
        for event in likes {
            #expect(event.timestamp == nil)
            guard case let .reel(identifier) = event.target.destination else {
                Issue.record("A Reel like must open its Reel")
                continue
            }
            #expect(identifier == reel.id)
        }
    }

    @Test
    func addingALikerOnlyAddsOneUnreadEventAndPreservesExistingIdentities() {
        let ownerID = UUID()
        let users = (0..<3).map { User(id: UUID(), handle: "friend\($0)", avatarURL: nil) }
        var reel = makeReel(ownerID: ownerID, likes: [UUID(), ownerID, users[0].id, users[0].id, users[1].id])
        func events(for reel: RealPost) -> [MapTalkActivityEvent] {
            MapTalkActivityFeed.events(
                reals: [reel], ratedPOIs: [], bubbles: [], currentUserID: ownerID,
                userProvider: { id in users.first { $0.id == id } }
            )
        }

        let initial = events(for: reel)
        #expect(initial.map(\.actor.id) == [users[0].id, users[1].id])
        let viewedIDs = Set(initial.map(\.id))

        reel.likes = [users[2].id, users[1].id, users[0].id]
        let updated = events(for: reel)
        #expect(updated.filter { !viewedIDs.contains($0.id) }.map(\.actor.id) == [users[2].id])
        #expect(viewedIDs.isSubset(of: Set(updated.map(\.id))))

        reel.likes = [users[1].id]
        #expect(events(for: reel).map(\.id) == initial.filter { $0.actor.id == users[1].id }.map(\.id))
    }

    @Test
    func bubbleLikesStayIndividualAndRouteSeparatelyFromReelLikes() {
        let ownerID = UUID()
        let users = (0..<2).map { User(id: UUID(), handle: "friend\($0)", avatarURL: nil) }
        var reel = makeReel(ownerID: ownerID, likes: users.map(\.id))
        let bubble = JourneyPost(
            id: UUID(), userId: ownerID, title: "Weekend", content: "",
            coordinate: reel.center, createdAt: reel.createdAt,
            reels: [], pois: [], likes: users.map(\.id) + [users[0].id, ownerID], comments: []
        )
        reel.capsuleId = bubble.id
        let events = MapTalkActivityFeed.events(
            reals: [reel], ratedPOIs: [], bubbles: [bubble, bubble], currentUserID: ownerID,
            userProvider: { id in users.first { $0.id == id } }
        )

        #expect(events.count == 4)
        #expect(Set(events.map(\.id)).count == 4)
        let bubbleEvents = events.filter {
            if case .bubble = $0.target.destination { return true }
            return false
        }
        #expect(bubbleEvents.map(\.actor.id) == users.map(\.id))
        for event in bubbleEvents {
            guard case let .bubble(identifier) = event.target.destination else { continue }
            #expect(identifier == bubble.id)
        }
    }

    private func makeReel(ownerID: UUID, likes: [UUID]) -> RealPost {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return RealPost(
            id: UUID(), userId: ownerID,
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radiusMeters: 100, message: "Weekend walk", attachments: [], likes: likes,
            comments: [], visibility: .publicAll, createdAt: now,
            expiresAt: now.addingTimeInterval(86_400)
        )
    }
}

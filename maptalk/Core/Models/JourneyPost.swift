import CoreLocation
import Foundation

struct JourneyPost: Identifiable {
    struct Comment: Identifiable {
        let id: UUID
        let userId: UUID
        let text: String
        let createdAt: Date
    }

    let id: UUID
    let userId: UUID
    let title: String
    let content: String
    let coordinate: CLLocationCoordinate2D
    let createdAt: Date
    /// Published Bubbles preserve the author's exact interleaved Place/Reel
    /// order. Legacy Journeys leave this empty and retain chronological order.
    let orderedMemberReferences: [JourneyFolder.MemberReference]
    let reels: [RealPost]
    let pois: [RatedPOI]
    let likes: [UUID]
    let comments: [Comment]

    init(
        id: UUID,
        userId: UUID,
        title: String,
        content: String,
        coordinate: CLLocationCoordinate2D,
        createdAt: Date,
        orderedMemberReferences: [JourneyFolder.MemberReference] = [],
        reels: [RealPost],
        pois: [RatedPOI],
        likes: [UUID],
        comments: [Comment]
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.content = content
        self.coordinate = coordinate
        self.createdAt = createdAt
        self.orderedMemberReferences = orderedMemberReferences
        self.reels = reels
        self.pois = pois
        self.likes = likes
        self.comments = comments
    }

    var displayLabel: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "journey"
        guard trimmed.isEmpty == false else { return fallback }
        return String(trimmed.prefix(12))
    }
}

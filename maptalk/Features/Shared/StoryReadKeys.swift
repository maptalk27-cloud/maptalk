import Foundation

enum StoryReadKeys {
    static let freshWindow: TimeInterval = 60 * 60 * 72

    static func real(_ real: RealPost) -> String {
        "real:\(real.id.uuidString):\(timestampToken(real.activityDate))"
    }

    static func journey(_ journey: JourneyPost) -> String {
        "journey:\(journey.id.uuidString):\(timestampToken(journey.createdAt))"
    }

    static func poiStoryPage(poiId: UUID, checkInId: UUID, mediaId: UUID, timestamp: Date) -> String {
        "poi-page:\(poiId.uuidString):\(checkInId.uuidString):\(mediaId.uuidString):\(timestampToken(timestamp))"
    }

    static func expiresAt(forActivityAt date: Date) -> Date {
        date.addingTimeInterval(freshWindow)
    }

    /// A stale disk snapshot or pending upload can carry an unbounded expiry.
    /// It must not keep a public marker alive beyond the publication window.
    /// An explicitly shorter lifetime is still respected.
    static func expiresAt(for real: RealPost) -> Date {
        min(real.expiresAt, expiresAt(forActivityAt: real.activityDate))
    }

    static func isFresh(_ date: Date, asOf now: Date = .now) -> Bool {
        expiresAt(forActivityAt: date) > now
    }

    static func isActive(_ real: RealPost, asOf now: Date = .now) -> Bool {
        expiresAt(for: real) > now
    }

    private static func timestampToken(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate)
    }
}

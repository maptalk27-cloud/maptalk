import Foundation

enum StoryReadKeys {
    static let freshWindow: TimeInterval = 60 * 60 * 24

    static func real(_ real: RealPost) -> String {
        "real:\(real.id.uuidString):\(timestampToken(real.activityDate))"
    }

    static func journey(_ journey: JourneyPost) -> String {
        "journey:\(journey.id.uuidString):\(timestampToken(journey.createdAt))"
    }

    static func poiStoryPage(poiId: UUID, checkInId: UUID, mediaId: UUID, timestamp: Date) -> String {
        "poi-page:\(poiId.uuidString):\(checkInId.uuidString):\(mediaId.uuidString):\(timestampToken(timestamp))"
    }

    static func isFresh(_ date: Date) -> Bool {
        date >= Date().addingTimeInterval(-freshWindow)
    }

    private static func timestampToken(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate)
    }
}

import Combine
import Foundation

/// Produces the map's horizontally browsable story items without depending on a view.
@MainActor
enum MapStoryFeed {
    static func items(
        reals: [RealPost],
        ratedPOIs: [RatedPOI],
        onlyRecentPOIStories: Bool,
        userProvider: (UUID) -> User?,
        now: Date = .init()
    ) -> [RealStoriesRow.StoryItem] {
        let poiItems = ratedPOIs.compactMap {
            poiGroup(
                for: $0,
                onlyRecentStories: onlyRecentPOIStories,
                userProvider: userProvider,
                now: now
            )
            .map(RealStoriesRow.StoryItem.init(poiGroup:))
        }

        return (
            reals.map(RealStoriesRow.StoryItem.init(real:)) +
            poiItems
        )
        .sorted { $0.timestamp > $1.timestamp }
    }

    static func items(
        for journey: JourneyPost,
        userProvider: (UUID) -> User?,
        now: Date = .init()
    ) -> [RealStoriesRow.StoryItem] {
        items(
            reals: journey.reels,
            ratedPOIs: journey.pois,
            onlyRecentPOIStories: false,
            userProvider: userProvider,
            now: now
        )
    }

    static func poiGroup(
        for rated: RatedPOI,
        onlyRecentStories: Bool,
        userProvider: (UUID) -> User?,
        now: Date = .init()
    ) -> RealStoriesRow.POIStoryGroup? {
        let sharers = rated.checkIns.compactMap { checkIn -> RealStoriesRow.POISharer? in
            let storyMedia = checkIn.media.filter { media in
                switch media.kind {
                case .photo, .video:
                    return true
                }
            }
            let hasStory = storyMedia.isEmpty == false

            if onlyRecentStories {
                guard hasStory,
                      checkIn.createdAt >= now.addingTimeInterval(-StoryReadKeys.freshWindow) else {
                    return nil
                }
            }

            return RealStoriesRow.POISharer(
                id: checkIn.id,
                user: userProvider(checkIn.userId),
                timestamp: checkIn.createdAt,
                hasStory: hasStory,
                readKeys: storyMedia.map { media in
                    StoryReadKeys.poiStoryPage(
                        poiId: rated.id,
                        checkInId: checkIn.id,
                        mediaId: media.id,
                        timestamp: checkIn.createdAt
                    )
                }
            )
        }
        .sorted { $0.timestamp > $1.timestamp }

        guard sharers.isEmpty == false else { return nil }
        return RealStoriesRow.POIStoryGroup(
            ratedPOI: rated,
            sharers: sharers,
            latestTimestamp: sharers.first?.timestamp ?? (rated.checkIns.map(\.createdAt).max() ?? now)
        )
    }
}

@MainActor
final class StoryReadStore: ObservableObject {
    @Published private(set) var viewedKeys: Set<String>

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "MapTalk.viewedStoryKeys"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        viewedKeys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func isViewed(_ key: String) -> Bool {
        viewedKeys.contains(key)
    }

    func markViewed(_ key: String) {
        markViewed([key])
    }

    func markViewed(_ keys: [String]) {
        let newKeys = keys.filter { viewedKeys.contains($0) == false }
        guard newKeys.isEmpty == false else { return }
        viewedKeys.formUnion(newKeys)
        defaults.set(Array(viewedKeys), forKey: storageKey)
    }
}

extension RealStoriesRow.StoryItem {
    var readKey: String {
        switch source {
        case let .real(real):
            return StoryReadKeys.real(real)
        case let .poi(group):
            return "poi:\(group.id.uuidString):\(Self.timestampToken(group.latestTimestamp))"
        case let .journey(journey):
            return StoryReadKeys.journey(journey)
        }
    }

    var isFresh: Bool {
        StoryReadKeys.isFresh(timestamp)
    }

    private static func timestampToken(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate)
    }
}

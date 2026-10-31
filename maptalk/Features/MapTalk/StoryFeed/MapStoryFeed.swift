import Combine
import CryptoKit
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
        let cutoff = onlyRecentStories ? now.addingTimeInterval(-StoryReadKeys.freshWindow) : nil
        let sharers = rated.checkInPeople(since: cutoff).map { person in
            // One avatar per person, but every eligible visit contributes read
            // keys. A new photo must still create an unread ring for that person.
            let readKeys = person.checkIns.flatMap { checkIn in
                checkIn.media.map { media in
                    StoryReadKeys.poiStoryPage(
                        poiId: rated.id,
                        checkInId: checkIn.id,
                        mediaId: media.id,
                        timestamp: checkIn.activityDate
                    )
                }
            }
            return RealStoriesRow.POISharer(
                id: person.userID,
                user: userProvider(person.userID),
                timestamp: person.latest.activityDate,
                hasStory: !readKeys.isEmpty,
                readKeys: readKeys
            )
        }

        guard sharers.isEmpty == false else { return nil }
        return RealStoriesRow.POIStoryGroup(
            ratedPOI: rated,
            sharers: sharers,
            latestTimestamp: sharers.first?.timestamp ?? (rated.checkIns.map(\.activityDate).max() ?? now)
        )
    }
}

@MainActor
final class StoryReadStore: ObservableObject {
    @Published private(set) var viewedKeys: Set<String> = []

    private let defaults: UserDefaults
    private let storageKey: String
    private var scopedStorageKey: String?
    private var viewedAt: [String: Date] = [:]
    /// The small grace period retains reads across offline refreshes. It does
    /// not extend the publication's eligibility in the 72-hour feed.
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumEntryCount = 4_096

    private struct PersistedReads: Codable {
        let version: Int
        let viewedAt: [String: Date]
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "MapTalk.viewedStoryKeys"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        // The legacy global string array has no owner. Never assume it belongs
        // to this account; callers configure the authenticated scope first.
    }

    func configure(accountID: UUID, server: String, now: Date = .now) {
        let namespace = Self.namespace(accountID: accountID, server: server)
        let key = "\(storageKey).v2.\(namespace)"
        guard scopedStorageKey != key else {
            prune(asOf: now)
            return
        }
        scopedStorageKey = key
        if let data = defaults.data(forKey: key),
           let saved = try? PropertyListDecoder().decode(PersistedReads.self, from: data), saved.version == 2 {
            viewedAt = saved.viewedAt
        } else {
            viewedAt = [:]
        }
        prune(asOf: now)
    }

    /// Discards the active identity, without erasing another account's bounded
    /// cache. Reads before the next configure are intentionally memory-only.
    func clearScope() {
        scopedStorageKey = nil
        viewedAt = [:]
        viewedKeys = []
    }

    func isViewed(_ key: String) -> Bool {
        viewedKeys.contains(key)
    }

    func markViewed(_ key: String, now: Date = .now) {
        markViewed([key], now: now)
    }

    func markViewed(_ keys: [String], now: Date = .now) {
        for key in keys where !key.isEmpty { viewedAt[key] = now }
        prune(asOf: now)
    }

    func prune(asOf now: Date = .now, retaining retainedKeys: Set<String> = []) {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        viewedAt = viewedAt.filter { key, date in
            date <= now.addingTimeInterval(60) && (date > cutoff || retainedKeys.contains(key))
        }
        if viewedAt.count > Self.maximumEntryCount {
            let ordered = viewedAt.sorted { left, right in
                let leftRetained = retainedKeys.contains(left.key)
                let rightRetained = retainedKeys.contains(right.key)
                if leftRetained != rightRetained { return leftRetained }
                if left.value != right.value { return left.value > right.value }
                return left.key < right.key
            }
            viewedAt = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maximumEntryCount).map { ($0.key, $0.value) })
        }
        let keys = Set(viewedAt.keys)
        if viewedKeys != keys { viewedKeys = keys }
        guard let scopedStorageKey,
              let data = try? PropertyListEncoder().encode(PersistedReads(version: 2, viewedAt: viewedAt)) else { return }
        defaults.set(data, forKey: scopedStorageKey)
    }

    private static func namespace(accountID: UUID, server: String) -> String {
        // Normalize only URL components that are case-insensitive. Distinct
        // deployment paths stay distinct, and equivalent trailing slashes do
        // not unexpectedly reset the user's reading history.
        var components = URLComponents(string: server)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if var path = components?.path {
            while path.hasSuffix("/") { path.removeLast() }
            components?.path = path
        }
        let serverIdentity = components?.string ?? server
        let identity = "\(accountID.uuidString.lowercased())\n\(serverIdentity)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
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

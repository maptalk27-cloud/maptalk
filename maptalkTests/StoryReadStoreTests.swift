import Foundation
import Testing
@testable import maptalk

@MainActor
struct StoryReadStoreTests {
    private let now = Date(timeIntervalSince1970: 1_792_670_400)

    @Test
    func readingHistoryIsScopedToAccountAndServerAndSurvivesRecreation() throws {
        let name = "MapTalk.story-reads.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let firstAccount = UUID(), secondAccount = UUID()
        let store = StoryReadStore(defaults: defaults)
        store.configure(accountID: firstAccount, server: "https://beta.example.com", now: now)
        store.markViewed("original-post", now: now)
        store.configure(accountID: secondAccount, server: "https://beta.example.com", now: now)
        #expect(!store.isViewed("original-post"))
        store.markViewed("second-account-post", now: now)
        store.configure(accountID: firstAccount, server: "https://staging.example.com", now: now)
        #expect(store.viewedKeys.isEmpty)
        store.configure(accountID: firstAccount, server: "https://BETA.example.com/", now: now)
        #expect(store.viewedKeys == ["original-post"])

        let recreated = StoryReadStore(defaults: defaults)
        #expect(recreated.viewedKeys.isEmpty, "No owner has been selected yet")
        recreated.configure(accountID: secondAccount, server: "https://beta.example.com", now: now)
        #expect(recreated.viewedKeys == ["second-account-post"])
    }

    @Test
    func legacyUnownedReadsAreNotAdoptedAndLogoutClearsActiveScope() throws {
        let name = "MapTalk.story-legacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["legacy"], forKey: "MapTalk.viewedStoryKeys")
        let store = StoryReadStore(defaults: defaults)
        let account = UUID()
        store.configure(accountID: account, server: "https://beta.example.com", now: now)
        #expect(!store.isViewed("legacy"))
        store.markViewed("known", now: now)
        store.clearScope()
        #expect(store.viewedKeys.isEmpty)
        store.markViewed("unowned", now: now)
        store.configure(accountID: account, server: "https://beta.example.com", now: now)
        #expect(store.viewedKeys == ["known"], "An unconfigured cache must not contaminate an account")
    }

    @Test
    func pruningRetainsOnlyRecentReadsOrExplicitlyRetainedSessionKeys() throws {
        let name = "MapTalk.story-pruning.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StoryReadStore(defaults: defaults)
        store.configure(accountID: UUID(), server: "https://beta.example.com", now: now)
        store.markViewed(["old", "current-session"], now: now)
        let later = now.addingTimeInterval(StoryReadStore.retentionInterval + 1)
        store.prune(asOf: later, retaining: ["current-session"])
        #expect(store.viewedKeys == ["current-session"])
        store.prune(asOf: later)
        #expect(store.viewedKeys.isEmpty)
    }

    @Test
    func readCacheHasADeterministicHardBound() throws {
        let name = "MapTalk.story-bound.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StoryReadStore(defaults: defaults)
        let account = UUID()
        store.configure(accountID: account, server: "https://beta.example.com", now: now)
        let count = StoryReadStore.maximumEntryCount
        store.markViewed((0..<(count + 100)).map { String(format: "page-%05d", $0) }, now: now)
        #expect(store.viewedKeys.count == count)
        store.markViewed("newest", now: now.addingTimeInterval(1))
        #expect(store.viewedKeys.count == count)
        #expect(store.isViewed("newest"))
        let recreated = StoryReadStore(defaults: defaults)
        recreated.configure(accountID: account, server: "https://beta.example.com", now: now.addingTimeInterval(1))
        #expect(recreated.viewedKeys == store.viewedKeys)
    }

    @Test
    func differentDeploymentPathsDoNotShareReads() throws {
        let name = "MapTalk.story-paths.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StoryReadStore(defaults: defaults)
        let account = UUID()
        store.configure(accountID: account, server: "https://beta.example.com/live/", now: now)
        store.markViewed("post", now: now)
        store.configure(accountID: account, server: "https://beta.example.com/preview", now: now)
        #expect(store.viewedKeys.isEmpty)
        store.configure(accountID: account, server: "https://beta.example.com/live", now: now)
        #expect(store.isViewed("post"))
    }
}

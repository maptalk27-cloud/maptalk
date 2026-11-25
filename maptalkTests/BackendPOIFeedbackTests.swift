import Combine
import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
@Suite(.serialized)
struct BackendPOIFeedbackTests {
    @Test
    func oldCachesDecodeAndCommentOnlyFeedbackEncodesExplicitNull() throws {
        let user = BackendUser(id: UUID(), handle: "feedback_test")
        let old = BackendLocalState(ownerID: user.id, server: "https://api.maptalkapp.com", user: user)
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(BackendLocalState.self, from: data)
        #expect(decoded.poiFeedbackQueue == nil)
        #expect(decoded.supportsPOIFeedback == nil)
        #expect(decoded.supportsPOICustomFeelings == nil)
        let feedback = BackendPOIFeedback(endorsement: nil, comment: "Just a comment")
        let encoded = try JSONEncoder().encode(feedback)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["endorsement"] is NSNull)
        #expect(json["customEmoji"] is NSNull)
        #expect(try JSONDecoder().decode(BackendPOIFeedback.self, from: encoded) == feedback)
        let legacy = try JSONDecoder().decode(BackendPOIFeedback.self,
            from: Data("{\"endorsement\":null,\"comment\":\"Old note\"}".utf8))
        #expect(legacy.customEmoji == nil)
        #expect(legacy.comment == "Old note")
    }

    @Test
    func skippingAndEmptyFeedbackDoNotCreateVotesOrWork() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: true)
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.endorsement == nil)
        #expect(fixture.store.archive.privatePOIs.first?.endorsements.hype == 0)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil, comment: " \n ")
        #expect((try await fixture.savedState()).poiFeedbackQueue == nil)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test
    func customFeelingSurvivesOfflineRestartWithoutBecomingARating() async throws {
        let fixture = try POIFeedbackFixture(visibility: "private")
        defer { fixture.finish() }
        try await fixture.seed(queued: true)
        let before = try await fixture.savedState()
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil,
            customEmoji: "🫠", comment: "  A long day  ")
        let queued = try await fixture.savedState()
        #expect(try fixture.sortedJSON(queued.queued[0].input) == fixture.sortedJSON(before.queued[0].input))
        #expect(queued.queued[0].record.feedback == nil)
        #expect(queued.poiFeedbackQueue?.first?.feedback.customEmoji == "🫠")
        let restored = fixture.makeStore()
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        let place = try #require(restored.archive.privatePOIs.first)
        let visit = try #require(place.checkIns.first)
        #expect(visit.customEmoji == "🫠")
        #expect(visit.endorsement == nil)
        #expect(visit.comment == "A long day")
        #expect(visit.createdAt == fixture.record.createdAt)
        #expect(place.endorsements == .init(hype: 0, solid: 0, meh: 0, questionable: 0))
        #expect(restored.feedPOIs.value.isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test
    func customStandardAndClearReplaceTheSameFeedbackWithoutRepublishing() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        fixture.store.resumeVerifiedConnection()
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil,
            customEmoji: "🥹", comment: "Keep this note")
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.customEmoji == "🥹")
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .solid,
            comment: "Keep this note")
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.customEmoji == nil)
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.endorsement == "solid")
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil,
            customEmoji: "☕️", comment: "")
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.customEmoji == "☕️")
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil, comment: "")
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback == nil)
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.server.requests.count == 4)
        #expect(fixture.server.requests.allSatisfy { $0.hasPrefix("PUT ") })
        #expect(fixture.store.ownedMemories[fixture.record.id]?.publishedAt == fixture.record.publishedAt)
        let clearedBody = try #require(fixture.server.feedbackBodies.last)
        let clearedObject = try JSONSerialization.jsonObject(with: Data(clearedBody.utf8))
        let cleared = try #require(clearedObject as? [String: Any])
        #expect(cleared["customEmoji"] is NSNull)
    }

    @Test
    func oldFeedbackServerHoldsCustomLocallyAndSyncsAfterCapabilityUpgrade() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        fixture.server.supportsCustomFeelings = false
        try await fixture.seed(queued: false, customCapability: nil)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil,
            customEmoji: "🌧️", comment: "Rainy")
        fixture.store.resumeVerifiedConnection()
        await fixture.store.syncPendingPublications()
        await fixture.store.syncPendingPublications()
        #expect(fixture.server.requests == ["GET /health"])
        #expect(fixture.store.pendingPOIFeedbackIDs == [fixture.record.id])
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.customEmoji == "🌧️")
        fixture.server.supportsCustomFeelings = true
        try await fixture.store.refresh()
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.customEmoji == "🌧️")
    }

    @Test
    func standardFeedbackStillSyncsToServerWithoutCustomCapability() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        fixture.server.supportsCustomFeelings = false
        try await fixture.seed(queued: false, customCapability: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype, comment: "")
        fixture.store.resumeVerifiedConnection()
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        let body = try #require(fixture.server.feedbackBodies.first)
        #expect(!body.contains("customEmoji"))
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.endorsement == "hype")
    }

    @Test(arguments: ["not-an-emoji", "😍", "🫠🫠", "🫠\0"])
    func invalidCustomFeelingsCannotEnterQueue(emoji: String) async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        await #expect(throws: (any Error).self) {
            try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil,
                customEmoji: emoji, comment: "A note")
        }
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test
    func standardAndCustomCannotBeSubmittedTogether() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        await #expect(throws: (any Error).self) {
            try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype,
                customEmoji: "🫠", comment: "A note")
        }
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
    }

    @Test
    func localArchiveCustomFeelingKeepsVisibilityAndCanBeReplaced() throws {
        let ownerID = UUID()
        let archive = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        let visit = RatedPOI.CheckIn(userId: ownerID)
        var place = PreviewData.sampleRatedPOIs[0]
        place.checkIns = [visit]
        place.refreshEndorsementSummary()
        archive.savePOI(place, publicVersion: nil, audience: .privateMyMap)
        #expect(archive.updatePOIFeedback(checkInID: visit.id, endorsement: nil,
            customEmoji: "🥹", comment: "  A memory  "))
        let saved = try #require(archive.privatePOIs.first?.checkIns.first)
        #expect(saved.customEmoji == "🥹")
        #expect(saved.comment == "A memory")
        #expect(saved.activityDate == visit.activityDate)
        #expect(archive.publicPOIOverlays.isEmpty)
        #expect(archive.updatePOIFeedback(checkInID: visit.id, endorsement: .solid, comment: "A memory"))
        #expect(archive.privatePOIs.first?.checkIns.first?.customEmoji == nil)
        #expect(archive.privatePOIs.first?.endorsements.solid == 1)
        #expect(!archive.updatePOIFeedback(checkInID: visit.id, endorsement: .solid,
            customEmoji: "🥹", comment: "Invalid"))
        #expect(archive.privatePOIs.first?.checkIns.first?.comment == "A memory")
    }

    @Test
    func queuedFeedbackSurvivesRestartWithoutChangingPublicationIntentOrPreview() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: true)
        let original = try await fixture.savedState()
        let inputBefore = try fixture.sortedJSON(original.queued[0].input)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .solid, comment: "  A calm stop  ")
        let state = try await fixture.savedState()
        #expect(try fixture.sortedJSON(state.queued[0].input) == inputBefore)
        #expect(state.queued[0].record.feedback == nil)
        #expect(state.queued[0].record.createdAt == fixture.record.createdAt)
        #expect(state.poiFeedbackQueue?.count == 1)
        #expect(state.poiFeedbackQueue?.first?.feedback.comment == "A calm stop")
        #expect(fixture.store.pendingPublications[fixture.record.id] == .waiting)
        #expect(fixture.store.feedRecords.value.isEmpty)
        #expect(fixture.server.requests.isEmpty)
        let restored = fixture.makeStore()
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        let visit = try #require(restored.archive.privatePOIs.first?.checkIns.first)
        #expect(visit.id == fixture.record.id)
        #expect(visit.endorsement == .solid)
        #expect(visit.comment == "A calm stop")
        #expect(visit.createdAt == fixture.record.createdAt)
        #expect(restored.pendingPOIFeedbackIDs == [fixture.record.id])
    }

    @Test
    func feedbackWaitsForSuccessfulParentAndNeverRepublishesItsMedia() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: true)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype, comment: "Worth it")
        fixture.store.resumeVerifiedConnection()
        fixture.server.failPublication = true
        await fixture.store.syncPendingPublications()
        #expect(fixture.server.requests == ["POST /v1/memories"])
        #expect(fixture.store.pendingPOIFeedbackIDs == [fixture.record.id])
        #expect(fixture.store.hasPendingPublicationSyncWork)
        fixture.server.failPublication = false
        await fixture.store.syncPendingPublications()
        #expect(fixture.server.requests == ["POST /v1/memories", "POST /v1/memories",
            "PUT /v1/memories/\(fixture.record.id.uuidString)/feedback"])
        #expect(fixture.server.publicationBodies.count == 2)
        #expect(fixture.server.publicationBodies[0] == fixture.server.publicationBodies[1])
        #expect(!fixture.server.publicationBodies[0].contains("feedback"))
        #expect(!fixture.store.hasPendingSyncWork)
        let current = try #require(fixture.store.ownedMemories[fixture.record.id])
        #expect(current.feedback?.endorsement == "hype")
        #expect(current.createdAt == fixture.record.createdAt)
        #expect(current.publishedAt == fixture.record.publishedAt)
        #expect(current.media.isEmpty)
    }

    @Test
    func privateFeedbackStaysPrivateAndKeepsOriginalClocks() async throws {
        let fixture = try POIFeedbackFixture(visibility: "private")
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .meh, comment: "My note")
        #expect(fixture.store.ownPublicPOIs.isEmpty)
        #expect(fixture.store.feedPOIs.value.isEmpty)
        fixture.store.resumeVerifiedConnection()
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.comment == "My note")
        #expect(fixture.store.feedRecords.value.isEmpty)
        #expect(fixture.store.ownPublicPOIs.isEmpty)
        let saved = try #require((try await fixture.savedState()).mine.first)
        #expect(saved.visibility == "private")
        #expect(saved.createdAt == fixture.record.createdAt)
        #expect(saved.publishedAt == fixture.record.publishedAt)
    }

    @Test(arguments: ["bad\0comment", String(repeating: "🌿", count: 501)])
    func invalidCommentsNeverEnterDurableQueue(comment: String) async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        do {
            try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype, comment: comment)
            Issue.record("Invalid feedback should not enter the durable queue")
        } catch {}
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect((try await fixture.savedState()).poiFeedbackQueue == nil)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test
    func clearingFeedbackRemovesOnlyFeedbackAndNeverCreatesAnotherPublication() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        fixture.store.resumeVerifiedConnection()
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .solid, comment: "A note")
        await fixture.store.syncPendingPublications()
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil, comment: "")
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.endorsement == nil)
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.comment == nil)
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback == nil)
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.server.requests.count == 2)
        #expect(fixture.server.requests.allSatisfy { $0.hasPrefix("PUT ") })
        #expect(fixture.store.ownedMemories[fixture.record.id]?.publishedAt == fixture.record.publishedAt)
    }

    @Test
    func oldServerKeepsFeedbackLocalWithoutCallingUnsupportedEndpoint() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        fixture.server.supportsFeedback = false
        try await fixture.seed(queued: false, capability: nil)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: nil, comment: "Saved locally")
        fixture.store.resumeVerifiedConnection()
        await fixture.store.syncPendingPublications()
        await fixture.store.syncPendingPublications()
        await fixture.store.syncPendingPublications()
        #expect(fixture.server.requests == ["GET /health"])
        #expect(fixture.store.pendingPOIFeedbackIDs == [fixture.record.id])
        #expect(fixture.store.hasPendingSyncWork)
        #expect(!fixture.store.hasPendingPublicationSyncWork)
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.comment == "Saved locally")
        fixture.server.supportsFeedback = true
        try await fixture.store.refresh()
        await fixture.store.syncPendingPublications()
        #expect(fixture.server.requests.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func sessionExpiryAndSignOutPreserveFeedbackButOtherAccountsAndServersCannotRestoreIt(explicitSignOut: Bool) async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .questionable, comment: "Hmm")
        fixture.store.clearLocalMedia(preservePendingPublications: !explicitSignOut,
            preservePendingPOIFeedback: explicitSignOut)
        let restored = fixture.makeStore()
        defer { restored.clearLocalMedia() }
        #expect(await restored.restoreCachedState())
        #expect(restored.pendingPOIFeedbackIDs == [fixture.record.id])
        #expect(restored.archive.privatePOIs.first?.checkIns.first?.comment == "Hmm")
        let otherUser = BackendStore(user: BackendUser(id: UUID(), handle: "other").user, api: fixture.api,
            storageDirectory: fixture.directory, automaticallySync: false, observesConnectivity: false)
        #expect(await otherUser.restoreCachedState() == false)
        let otherAPI = BackendAPI(baseURL: URL(string: "https://other.example")!, session: fixture.session)
        let otherServer = BackendStore(user: fixture.record.owner.user, api: otherAPI,
            storageDirectory: fixture.directory, automaticallySync: false, observesConnectivity: false)
        #expect(await otherServer.restoreCachedState() == false)
    }

    @Test
    func deletingPendingParentAlsoRemovesItsFeedbackIntent() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: true)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .solid, comment: "Gone")
        try await fixture.store.deletePost(memoryID: fixture.record.id)
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect((try await fixture.savedState()).poiFeedbackQueue?.isEmpty == true)
        #expect(fixture.store.archive.privatePOIs.isEmpty)
        fixture.store.resumeVerifiedConnection()
        await fixture.store.syncPendingPublications()
        #expect(!fixture.server.requests.contains { $0.contains("/feedback") })
    }

    @Test
    func perUserSummaryUsesLatestActualRatingAndAllowsCommentOnlyVisits() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        var newestUnrated = fixture.memory(id: UUID(), createdAt: Date(timeIntervalSince1970: 300))
        newestUnrated.feedback = .init(endorsement: nil, comment: "No rating", customEmoji: "🌅")
        var latestRated = fixture.memory(id: UUID(), createdAt: Date(timeIntervalSince1970: 200))
        latestRated.feedback = .init(endorsement: "solid", comment: "")
        var oldestRated = fixture.memory(id: UUID(), createdAt: Date(timeIntervalSince1970: 100))
        oldestRated.feedback = .init(endorsement: "hype", comment: "")
        var other = fixture.memory(id: UUID(), createdAt: Date(timeIntervalSince1970: 100),
            owner: .init(id: UUID(), handle: "other"))
        other.feedback = .init(endorsement: "meh", comment: "")
        let records = [newestUnrated, latestRated, oldestRated, other]
        let state = BackendLocalState(ownerID: fixture.record.ownerId, server: fixture.api.baseURL.absoluteString,
            user: fixture.record.owner, mine: Array(records.prefix(3)), profile: Array(records.prefix(3)), feed: records)
        try await BackendLocalStateDisk(directory: fixture.directory).save(state, revision: 1)
        #expect(await fixture.store.restoreCachedState())
        let place = try #require(fixture.store.feedPOIs.value.first)
        #expect(place.endorsements.hype == 0)
        #expect(place.endorsements.solid == 1)
        #expect(place.endorsements.meh == 1)
        #expect(place.endorsements.questionable == 0)
        #expect(place.checkIns.first?.comment == "No rating")
        #expect(place.checkIns.first?.endorsement == nil)
        #expect(place.checkIns.first?.customEmoji == "🌅")
    }

    @Test(.timeLimit(.minutes(1)))
    func newerLocalFeedbackWinsWhileOlderRequestIsInFlight() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype, comment: "First")
        fixture.store.resumeVerifiedConnection()
        let (requests, continuation) = AsyncStream<POIFeedbackProtocol>.makeStream()
        defer { continuation.finish() }
        POIFeedbackProtocol.install { continuation.yield($0) }
        let firstSync = Task { await fixture.store.syncPendingPublications() }
        defer { firstSync.cancel() }
        var iterator = requests.makeAsyncIterator()
        let held = try #require(await iterator.next())
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .meh, comment: "Second")
        var oldResponse = fixture.record
        oldResponse.feedback = .init(endorsement: "hype", comment: "First")
        held.respond(try fixture.wireJSON(oldResponse))
        await firstSync.value
        #expect(fixture.store.pendingPOIFeedbackIDs == [fixture.record.id])
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.comment == "Second")
        fixture.installServer()
        await fixture.store.syncPendingPublications()
        #expect(fixture.store.pendingPOIFeedbackIDs.isEmpty)
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.endorsement == "meh")
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedPrivacyReplyCannotEraseNewerConfirmedFeedback() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .solid, comment: "Keep this")
        fixture.store.resumeVerifiedConnection()
        let (requests, continuation) = AsyncStream<POIFeedbackProtocol>.makeStream()
        defer { continuation.finish() }
        POIFeedbackProtocol.install { continuation.yield($0) }
        var iterator = requests.makeAsyncIterator()
        let syncing = Task { await fixture.store.syncPendingPublications() }
        defer { syncing.cancel() }
        let put = try #require(await iterator.next())
        #expect(put.request.httpMethod == "PUT")
        let makingPrivate = Task { try await fixture.store.makePrivate(memoryID: fixture.record.id) }
        defer { makingPrivate.cancel() }
        let patch = try #require(await iterator.next())
        #expect(patch.request.httpMethod == "PATCH")
        var confirmed = fixture.record
        confirmed.feedback = .init(endorsement: "solid", comment: "Keep this")
        put.respond(try fixture.wireJSON(confirmed))
        await syncing.value
        var stalePrivate = try #require(JSONSerialization.jsonObject(with: fixture.wireJSON(fixture.record)) as? [String: Any])
        stalePrivate["visibility"] = "private"
        POIFeedbackProtocol.install { $0.respond(Data("{}".utf8), status: 503) }
        patch.respond(try JSONSerialization.data(withJSONObject: stalePrivate))
        try await makingPrivate.value
        #expect(fixture.store.ownedMemories[fixture.record.id]?.feedback?.comment == "Keep this")
        #expect(fixture.store.ownPublicPOIs.isEmpty)
        #expect(fixture.store.feedPOIs.value.isEmpty)
        let state = try await fixture.savedState()
        #expect(state.privateOverrides.first?.feedback?.comment == "Keep this")
        #expect(state.privateOverrides.first?.visibility == "private")
    }

    @Test
    func bubblePreviewDoesNotFreezeUnconfirmedOptionalFeedback() async throws {
        let fixture = try POIFeedbackFixture()
        defer { fixture.finish() }
        try await fixture.seed(queued: false)
        try await fixture.store.savePOIFeedback(memoryID: fixture.record.id, endorsement: .hype, comment: "Local only")
        let place = try #require(fixture.record.place)
        let bubbleID = UUID()
        _ = try await fixture.store.enqueuePublish(.reel(.init(text: "Bubble", attachments: [],
            bubbleSource: .memories([.poi(place.id)]))), audience: .livePublic,
            location: CLLocation(latitude: 37.36, longitude: -122.03), requestID: bubbleID)
        let state = try await fixture.savedState()
        let bubble = try #require(state.queued.first { $0.id == bubbleID })
        #expect(bubble.record.cluster?.members.first?.feedback == nil)
        #expect(fixture.store.archive.privatePOIs.first?.checkIns.first?.comment == "Local only")
        #expect(state.poiFeedbackQueue?.count == 1)
        #expect(fixture.server.requests.isEmpty)
    }
}

@MainActor
private final class POIFeedbackFixture {
    let directory: URL
    let session: URLSession
    let api: BackendAPI
    let record: BackendMemory
    let server: POIFeedbackServer
    let store: BackendStore

    init(visibility: String = "public") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("poi-feedback-\(UUID())")
        let user = BackendUser(id: UUID(), handle: "feedback_test")
        let point = BackendCoordinate(latitude: 37.36, longitude: -122.03)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        record = BackendMemory(id: UUID(), ownerId: user.id, owner: user, kind: "poi", visibility: visibility,
            location: point, caption: "", place: .init(id: UUID(), sourceId: nil, name: "Test place",
                category: "coffee", coordinate: point), media: [], createdAt: date,
            publishedAt: visibility == "public" ? date : nil, expiresAt: date.addingTimeInterval(259_200))
        server = POIFeedbackServer(record: record)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [POIFeedbackProtocol.self]
        session = URLSession(configuration: configuration)
        api = BackendAPI(baseURL: URL(string: "https://api.maptalkapp.com")!, session: session)
        api.token = "feedback-test-token"
        store = BackendStore(user: user.user, api: api, storageDirectory: directory,
            automaticallySync: false, observesConnectivity: false)
        installServer()
    }

    func installServer() {
        let server = server
        POIFeedbackProtocol.install { server.handle($0) }
    }

    func makeStore() -> BackendStore {
        BackendStore(user: record.owner.user, api: api, storageDirectory: directory,
            automaticallySync: false, observesConnectivity: false)
    }

    func seed(queued: Bool, capability: Bool? = true, customCapability: Bool? = true) async throws {
        var state = BackendLocalState(ownerID: record.ownerId, server: api.baseURL.absoluteString,
            user: record.owner, mine: queued ? [] : [record], profile: queued ? [] : [record],
            feed: queued ? [] : [record])
        state.supportsPOIFeedback = capability
        state.supportsPOICustomFeelings = customCapability
        if queued {
            let input = BackendMemoryInput(id: record.id, kind: "poi", visibility: record.visibility,
                location: record.location, caption: "", placeId: record.place?.id,
                capturedAt: record.createdAt.ISO8601Format())
            var preview = record
            preview.moderationStatus = "local_pending"
            state.queued = [.init(input: input, record: preview, photos: [])]
        }
        try await BackendLocalStateDisk(directory: directory).save(state, revision: 1)
        #expect(await store.restoreCachedState())
    }

    func savedState() async throws -> BackendLocalState {
        try #require(await BackendLocalStateDisk(directory: directory).load())
    }

    func memory(id: UUID, createdAt: Date, owner: BackendUser? = nil) -> BackendMemory {
        let user = owner ?? record.owner
        return .init(id: id, ownerId: user.id, owner: user, kind: "poi", visibility: "public",
            location: record.location, caption: "", place: record.place, media: [], createdAt: createdAt,
            publishedAt: createdAt, expiresAt: createdAt.addingTimeInterval(259_200))
    }

    func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func wireJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    func finish() {
        store.clearLocalMedia()
        session.invalidateAndCancel()
        POIFeedbackProtocol.install(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class POIFeedbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: BackendMemory
    private var requestLog: [String] = []
    private var bodyLog: [String] = []
    private var failing = false
    private var supported = true
    private var customSupported = true
    private var feedbackBodyLog: [String] = []
    init(record: BackendMemory) { memory = record }
    var failPublication: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var supportsFeedback: Bool {
        get { lock.withLock { supported } }
        set { lock.withLock { supported = newValue } }
    }
    var supportsCustomFeelings: Bool {
        get { lock.withLock { customSupported } }
        set { lock.withLock { customSupported = newValue } }
    }
    var requests: [String] { lock.withLock { requestLog } }
    var publicationBodies: [String] { lock.withLock { bodyLog } }
    var feedbackBodies: [String] { lock.withLock { feedbackBodyLog } }

    func handle(_ operation: POIFeedbackProtocol) {
        let method = operation.request.httpMethod ?? "GET"
        let path = operation.request.url!.path
        lock.withLock { requestLog.append("\(method) \(path)") }
        if path == "/health" {
            operation.respond(Data((supportsFeedback
                ? "{\"features\":{\"poiFeedback\":true,\"poiCustomFeelings\":\(supportsCustomFeelings)}}" : "{}").utf8))
        } else if method == "PUT", path.hasSuffix("/feedback") {
            do {
                let body = try operation.body()
                lock.withLock { feedbackBodyLog.append(String(decoding: body, as: UTF8.self)) }
                let feedback = try JSONDecoder().decode(BackendPOIFeedback.self, from: body)
                let response = lock.withLock {
                    memory.feedback = feedback.isEmpty ? nil : feedback
                    return memory
                }
                operation.respond(try wireJSON(response))
            } catch { operation.fail(error) }
        } else if method == "POST", path == "/v1/memories" {
            do {
                let body = try operation.body()
                let object = try JSONSerialization.jsonObject(with: body)
                let sorted = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                lock.withLock { bodyLog.append(String(decoding: sorted, as: UTF8.self)) }
                if failPublication { operation.fail(URLError(.networkConnectionLost)) }
                else { operation.respond(try wireJSON(lock.withLock { memory })) }
            } catch { operation.fail(error) }
        } else if method == "DELETE" {
            operation.respond(Data("{}".utf8), status: 204)
        } else if path == "/v1/me" {
            let identity = lock.withLock { memory.owner }
            operation.respond(try! JSONSerialization.data(withJSONObject:
                ["user": ["id": identity.id.uuidString, "handle": identity.handle]]))
        } else {
            let response = lock.withLock { memory }
            let records = path == "/v1/posts" ? [] : [response]
            do {
                let items = try JSONSerialization.jsonObject(with: wireJSON(records))
                operation.respond(try JSONSerialization.data(withJSONObject: ["items": items, "nextCursor": NSNull()]))
            } catch { operation.fail(error) }
        }
    }

    private func wireJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class POIFeedbackProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (POIFeedbackProtocol) -> Void)?
    static func install(_ value: (@Sendable (POIFeedbackProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
    func respond(_ data: Data, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func body() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

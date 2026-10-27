import AVFoundation
import Combine
import CoreLocation
import Foundation
import Testing
import UIKit
@testable import maptalk

@MainActor
@Suite(.serialized)
struct UserMapPendingPreviewTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func pendingAndFailedVideosRemainPlayableInOrdinaryMyMapRecords(isPOI: Bool, failed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-preview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = User(id: UUID(), handle: "local_preview", avatarURL: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewForbiddenNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = BackendAPI(baseURL: URL(string: "https://preview-test.invalid")!, session: session)
        let store = BackendStore(user: user, api: api, storageDirectory: directory,
                                 automaticallySync: false, observesConnectivity: false)
        let restored = BackendStore(user: user, api: api, storageDirectory: directory,
                                    automaticallySync: false, observesConnectivity: false)
        defer {
            store.clearLocalMedia()
            restored.clearLocalMedia()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }

        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let poster = directory.appendingPathComponent("composer-poster.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        try #require(image.jpegData(compressionQuality: 0.8)).write(to: poster)
        let id = UUID()
        let draft: MapTalkPublishDraft = isPOI
            ? .place(.init(target: .new(name: "Local coffee", category: .coffee),
                           media: .init(kind: .video(url: source, poster: poster))))
            : .reel(.init(text: "My video", attachments: [.init(kind: .video(url: source, poster: poster))],
                          bubbleSource: nil))
        _ = try await store.enqueuePublish(draft, audience: .livePublic,
                                          location: CLLocation(latitude: 37.3688, longitude: -122.0363),
                                          requestID: id)
        if failed {
            let disk = BackendLocalStateDisk(directory: directory)
            var saved = try #require(try await disk.load())
            saved.queued[0].failure = "This video is damaged or incomplete. Please choose another."
            try await disk.save(saved, revision: 100)
        }
        // The composer source can disappear after the app quits. Preview must
        // still use the durable local media, never wait for a server download.
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: poster)
        #expect(await restored.restoreCachedState())
        let records = UserMapRecord.make(
            reels: restored.archive.privateReels,
            footprints: restored.archive.privatePOIs.map { .init(ratedPOI: $0, visits: $0.checkIns) }
        )
        let record = try #require(records.first)
        #expect(record.isMapExperienceItem)
        #expect(record.pendingPublication(in: restored.pendingPublications)?.id == id)
        if failed {
            guard case .failed = record.publicationStatus(in: restored.pendingPublications) else {
                Issue.record("The test must exercise a failed publication, not a successful upload")
                return
            }
        } else {
            #expect(record.publicationStatus(in: restored.pendingPublications) == .waiting)
        }
        let video: URL
        let cover: URL?
        switch record.kind {
        case let .reel(reel):
            guard case let .video(url, poster) = reel.attachments.first?.kind else {
                Issue.record("The normal Reel preview lost its video")
                return
            }
            video = url
            cover = poster
        case let .poi(poi):
            guard case let .video(url, poster) = poi.checkIns.first?.media.first?.kind else {
                Issue.record("The normal POI preview lost its video")
                return
            }
            video = url
            cover = poster
        case .journey:
            Issue.record("A pending video must remain its original record type")
            return
        }
        #expect(video.isFileURL)
        #expect(video != source)
        #expect(try await AVURLAsset(url: video).load(.isPlayable))
        let coverURL = try #require(cover)
        #expect(coverURL.isFileURL)
        #expect(UIImage(contentsOfFile: coverURL.path) != nil)
        #expect(restored.feedPOIs.value.isEmpty)
        #expect(restored.feedReels.value.isEmpty, "Local preview must not pretend the post is already public")
    }

    @Test
    func groupedPOIRetryTargetsFailedVisitWithoutChangingPreviewContent() throws {
        let userID = UUID()
        let firstID = UUID()
        let failedID = UUID()
        let photo = URL(fileURLWithPath: "/private/tmp/local-memory.jpg")
        let visits: [RatedPOI.CheckIn] = [
            .init(id: firstID, userId: userID, media: [.init(kind: .photo(photo))]),
            .init(id: failedID, userId: userID, media: [.init(kind: .photo(photo))])
        ]
        let poi = RatedPOI(poi: .init(id: UUID(), name: "Coffee", coordinate: .init(latitude: 0, longitude: 0),
                                     category: .coffee), highlight: nil, secondary: nil, media: [], checkIns: visits,
                           comments: [], endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
                           tags: [], isFavoritedByCurrentUser: false, favoritesCount: 0)
        let record = UserMapRecord(id: poi.id, timestamp: .now, kind: .poi(poi))
        let pending: [UUID: PendingPublicationStatus] = [firstID: .uploading, failedID: .failed("Internal reason")]
        #expect(record.pendingPublication(in: pending)?.id == failedID)
        #expect(record.pendingPublication(in: pending)?.id != poi.id)
        guard case let .poi(preview) = record.kind else { return }
        #expect(preview.checkIns.map(\.id) == [firstID, failedID])
        #expect(preview.checkIns.flatMap(\.media).count == 2)
    }
}

private final class PreviewForbiddenNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("Restoring and previewing local memories must not require a network request")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() { }
}

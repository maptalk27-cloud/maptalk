import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct VideoPlacePublishTests {
    @Test func aVideoIsContentNotPermissionToCheckInElsewhere() async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: 500)
        defer { fixture.finish() }
        do {
            _ = try await fixture.store.enqueuePublish(.place(.init(
                target: .existing(CurrentPlacePublishFixture.rated(5_000)),
                media: .init(kind: .video(url: fixture.media, poster: nil)))), audience: .livePublic,
                location: CurrentPlacePublishFixture.origin, requestID: UUID())
            Issue.record("An attached video must not expand the current-GPS radius")
        } catch {
            #expect(error.localizedDescription.contains("500 m"))
        }
        #expect(fixture.store.pendingPublications.isEmpty)
        _ = try await fixture.store.enqueuePublish(.place(.init(
            target: .existing(CurrentPlacePublishFixture.rated(450)),
            media: .init(kind: .video(url: fixture.media, poster: nil)))), audience: .livePublic,
            location: CurrentPlacePublishFixture.origin, requestID: UUID())
        let entry = try #require(try await fixture.state().queued.first)
        #expect(entry.photos.first?.contentType == "video/mp4")
        #expect(entry.input.videoVisit == nil && entry.input.photoVisit == nil && entry.input.placeVisit == nil)
    }

    @Test func createNewAlwaysUsesCurrentGPSWithAVideo() async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: nil)
        defer { fixture.finish() }
        _ = try await fixture.store.enqueuePublish(.place(.init(target: .new(name: "Here", category: .other),
            media: .init(kind: .video(url: fixture.media, poster: nil)))), audience: .privateMyMap,
            location: CurrentPlacePublishFixture.origin, requestID: UUID())
        let entry = try #require(try await fixture.state().queued.first)
        #expect(entry.input.place?.coordinate == nil)
        #expect(entry.record.place?.coordinate.latitude == CurrentPlacePublishFixture.origin.coordinate.latitude)
        #expect(entry.record.place?.coordinate.longitude == CurrentPlacePublishFixture.origin.coordinate.longitude)
        #expect(entry.input.videoVisit == nil)
    }
}

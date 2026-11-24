import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct PhotoPlacePublishTests {
    @Test func aPhotoIsContentNotPermissionToCheckInElsewhere() async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: 500)
        defer { fixture.finish() }
        do {
            _ = try await fixture.store.enqueuePublish(.place(.init(
                target: .existing(CurrentPlacePublishFixture.rated(5_000)),
                media: .init(kind: .photo(fixture.media)))), audience: .livePublic,
                location: CurrentPlacePublishFixture.origin, requestID: UUID())
            Issue.record("An attached photo must not expand the current-GPS radius")
        } catch {
            #expect(error.localizedDescription.contains("500 m"))
        }
        #expect(fixture.store.pendingPublications.isEmpty)
        _ = try await fixture.store.enqueuePublish(.place(.init(
            target: .existing(CurrentPlacePublishFixture.rated(450)),
            media: .init(kind: .photo(fixture.media)))), audience: .livePublic,
            location: CurrentPlacePublishFixture.origin, requestID: UUID())
        let entry = try #require(try await fixture.state().queued.first)
        #expect(entry.photos.first?.contentType == "image/jpeg")
        #expect(entry.input.photoVisit == nil && entry.input.videoVisit == nil && entry.input.placeVisit == nil)
    }

    @Test func createNewAlwaysUsesCurrentGPSWithAPhoto() async throws {
        let fixture = try await CurrentPlacePublishFixture.make(radius: nil)
        defer { fixture.finish() }
        _ = try await fixture.store.enqueuePublish(.place(.init(target: .new(name: "Here", category: .coffee),
            media: .init(kind: .photo(fixture.media)))), audience: .privateMyMap,
            location: CurrentPlacePublishFixture.origin, requestID: UUID())
        let entry = try #require(try await fixture.state().queued.first)
        #expect(entry.input.place?.coordinate == nil)
        #expect(entry.input.location.latitude == CurrentPlacePublishFixture.origin.coordinate.latitude)
        #expect(entry.record.place?.coordinate.latitude == entry.input.location.latitude)
        #expect(entry.record.place?.coordinate.longitude == entry.input.location.longitude)
        #expect(entry.input.photoVisit == nil)
    }
}

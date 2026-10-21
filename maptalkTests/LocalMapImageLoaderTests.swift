import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import maptalk

@MainActor
struct LocalMapImageLoaderTests {
    @Test
    func largePhotosAreDecodedAtScreenQualityAndReusedAcrossViews() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.png")
        try writeImage(width: 4_096, height: 1_024, to: url)
        let loader = LocalMapImageLoader()
        let first = try await loader.image(at: url)
        #expect(first.image.width == 2_048)
        #expect(first.image.height == 512)
        let second = try await loader.image(at: url)
        #expect(first === second, "Map, list and story should reuse the same decoded pixels")
    }

    @Test
    func changedOrDeletedFilesCannotReturnStaleCachedPhotos() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("changing.png")
        try writeImage(width: 40, height: 20, to: url)
        let loader = LocalMapImageLoader()
        let first = try await loader.image(at: url)
        try writeImage(width: 20, height: 40, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                                              ofItemAtPath: url.path)
        let replacement = try await loader.image(at: url)
        #expect(first !== replacement)
        #expect(replacement.image.width == 20)
        #expect(replacement.image.height == 40)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await loader.image(at: url)
            Issue.record("Deleting a signed-out account's photo must invalidate its cache lookup")
        } catch {
            #expect(error is CocoaError)
        }
    }

    @Test
    func cancelledImageRequestsNeverPublishAResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancelled.png")
        try writeImage(width: 32, height: 32, to: url)
        let loader = LocalMapImageLoader()
        let request = Task { try await loader.image(at: url) }
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled image load must not return pixels to an obsolete view")
        } catch is CancellationError {
            // Expected: cancellation is checked before I/O and before caching a decoded image.
        }
    }

    @Test
    func connectedArchiveStartsEmptyWithItsOwnIdentity() {
        let ownerID = UUID()
        let archive = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        #expect(archive.currentUserID == ownerID)
        #expect(archive.privatePOIs.isEmpty)
        #expect(archive.privateReels.isEmpty)
        #expect(archive.privateBubbleCatalog.isEmpty)
        #expect(archive.publicPOIOverlays.isEmpty)
        #expect(archive.publicReelOverlays.isEmpty)
        #expect(archive.journeyFolders.isEmpty)
        #expect(archive.legacyJourneyCatalog.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maptalk-image-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeImage(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

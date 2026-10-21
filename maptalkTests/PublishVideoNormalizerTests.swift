import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import maptalk

@Suite(.serialized)
struct PublishVideoNormalizerTests {
    @Test(.timeLimit(.minutes(1)))
    func normalizesToPlayableBoundedMP4WithoutSourceMetadata() async throws {
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(output != source)
        #expect(output.pathExtension == "mp4")
        #expect(try Data(contentsOf: source) == before)
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        let metadata = try await asset.load(.metadata)
        #expect(!metadata.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
        let poster = try await PublishVideoNormalizer.posterJPEG(at: output)
        let image = try #require(CGImageSourceCreateWithData(poster as CFData, nil))
        #expect(CGImageSourceGetCount(image) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesLongVideoWithoutTruncatingTheUsersClip() async throws {
        let source = try await VideoTestFixture.makeVideo(duration: 61)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
            try? FileManager.default.removeItem(at: output)
            Issue.record("A video over 60 seconds must be rejected, not silently cut")
        } catch PublishVideoNormalizer.ImportError.tooLong {}
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesInvalidVideoAndNeverTreatsItAsAPhoto() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data("not a movie".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let output = try await PublishVideoNormalizer.prepare(sourceURL: file)
            try? FileManager.default.removeItem(at: output)
            Issue.record("Invalid video should fail the import")
        } catch { #expect(!error.localizedDescription.isEmpty) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func portraitCameraOrientationIsPreservedWhenPreparingH264AndHEVC(useHEVC: Bool) async throws {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let source = try await VideoTestFixture.makeVideo(transform: rotation, useHEVC: useHEVC)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        if ProcessInfo.processInfo.environment["MAPTALK_VIDEO_TEST_ARTIFACTS"] == "1" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MapTalkVideoTestArtifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("native-video-export-portrait-\(useHEVC ? "hevc-source" : "h264-source").mp4")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: output, to: target)
        }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let visible = CGRect(origin: .zero, size: size).applying(transform).standardized
        #expect(visible.height > visible.width, "A portrait camera clip must not become sideways")
        let poster = try await PublishVideoNormalizer.posterJPEG(at: output)
        let image = try #require(CGImageSourceCreateWithData(poster as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(height > width)
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheStoresPlayableExtensionAndCoverAndPurgesBoth() async throws {
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = BackendMediaDisk(directory: directory)
        defer { disk.invalidate() }
        let id = UUID()
        let url = try await disk.write(Data(contentsOf: source), for: id, mimeType: "video/mp4")
        #expect(url.pathExtension == "mp4")
        #expect(try await disk.cachedURL(for: id, mimeType: "video/mp4") == url)
        let poster = try #require(try await disk.cachedPosterURL(for: id))
        #expect(FileManager.default.fileExists(atPath: poster.path))
        disk.remove([id])
        #expect(try await disk.cachedURL(for: id, mimeType: "video/mp4") == nil)
        #expect(try await disk.cachedPosterURL(for: id) == nil)
    }
}

/// Tiny real H.264 fixtures exercise AVFoundation without Photos permission,
/// network access, external video files, or a physical camera.
nonisolated enum VideoTestFixture {
    @concurrent
    static func makeVideo(duration: Double = 1, transform: CGAffineTransform = .identity,
                          useHEVC: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .quickTimeMetadataLocationISO6709
        metadata.value = "+37.3688-122.0363/" as NSString
        writer.metadata = [metadata]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 100, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for timestamp in [0.0, max(0.1, duration - 0.05)] {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: timestamp, preferredTimescale: 600)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}

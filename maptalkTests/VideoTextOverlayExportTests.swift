import AVFoundation
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import maptalk

@Suite(.serialized)
struct VideoTextOverlayExportTests {
    @Test(.timeLimit(.minutes(1)))
    func exportedFramesContainThePhotoEditorsGlyphsWithoutChangingTheSource() async throws {
        let source = try await VideoTestFixture.makeVideo(frameRate: 30, size: CGSize(width: 320, height: 240))
        defer { remove(source) }
        let original = try Data(contentsOf: source)
        let text = PhotoTextOverlay(text: "Aloha 海边", center: CGPoint(x: 0.7, y: 0.23))
        let plain = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { remove(plain) }
        let edited = try await PublishVideoNormalizer.prepare(sourceURL: source, textOverlay: text)
        defer { remove(edited) }
        try await PublishVideoNormalizer.validatePreparedFile(at: edited)
        #expect(try Data(contentsOf: source) == original)
        // Check the beginning, middle and end: the edit must be in encoded
        // video frames, not merely a poster or an in-app preview overlay.
        for time in [0.0, 0.5, 0.9] {
            let baseline = try await decodedFrame(plain, at: time)
            let frame = try await decodedFrame(edited, at: time)
            try expectPhotoGlyphs(text, in: frame, comparedWith: baseline)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func portraitSelectedClipKeepsUprightTextAndAudibleAAC() async throws {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let source = try await VideoTestFixture.makeVideoWithAudio(transform: rotation,
            size: CGSize(width: 320, height: 240))
        defer { remove(source) }
        let original = try Data(contentsOf: source)
        let range = CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600),
                                duration: CMTime(seconds: 0.6, preferredTimescale: 600))
        let text = PhotoTextOverlay(text: "Beach\n今天", center: CGPoint(x: 0.72, y: 0.2))
        let plain = try await PublishVideoNormalizer.prepare(sourceURL: source, timeRange: range)
        defer { remove(plain) }
        let edited = try await PublishVideoNormalizer.prepare(sourceURL: source, timeRange: range, textOverlay: text)
        defer { remove(edited) }
        try await PublishVideoNormalizer.validatePreparedFile(at: edited)
        let asset = AVURLAsset(url: edited)
        defer { withExtendedLifetime(asset) {} }
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 240, height: 320))
        #expect(try await video.load(.preferredTransform) == .identity)
        #expect(abs(try await video.load(.timeRange).duration.seconds - 0.6) < 0.05)
        let frame = try await decodedFrame(edited, at: 0.3)
        let baseline = try await decodedFrame(plain, at: 0.3)
        try expectPhotoGlyphs(text, in: frame, comparedWith: baseline)
        try await expectAudibleAAC(asset, minimumDuration: 0.5)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(.timeLimit(.minutes(1)))
    func hdrTextIsCompositedAfterTheExistingSDRConversion() async throws {
        let source = try await VideoTestFixture.makeVideo(useHEVC: true, frameRate: 30, hdr: true,
                                                         size: CGSize(width: 320, height: 240))
        defer { remove(source) }
        let text = PhotoTextOverlay(text: "Sunset", center: CGPoint(x: 0.3, y: 0.7))
        let plain = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { remove(plain) }
        let edited = try await PublishVideoNormalizer.prepare(sourceURL: source, textOverlay: text)
        defer { remove(edited) }
        try await PublishVideoNormalizer.validatePreparedFile(at: edited)
        let asset = AVURLAsset(url: edited)
        defer { withExtendedLifetime(asset) {} }
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        #expect(transfer == AVVideoTransferFunction_ITU_R_709_2)
        let frame = try await decodedFrame(edited, at: 0.5)
        let baseline = try await decodedFrame(plain, at: 0.5)
        try expectPhotoGlyphs(text, in: frame, comparedWith: baseline)
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyOverlayFollowsTheUnchangedVideoPath() async throws {
        let source = try await VideoTestFixture.makeVideo(frameRate: 30)
        defer { remove(source) }
        let plain = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { remove(plain) }
        let empty = try await PublishVideoNormalizer.prepare(sourceURL: source,
            textOverlay: PhotoTextOverlay(text: " \n\t ", center: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)))
        defer { remove(empty) }
        let baseline = try await decodedFrame(plain, at: 0.5)
        let frame = try await decodedFrame(empty, at: 0.5)
        #expect(frame.bytes == baseline.bytes)
    }

    private func expectPhotoGlyphs(_ overlay: PhotoTextOverlay, in frame: Pixels, comparedWith baseline: Pixels) throws {
        try #require(frame.width == baseline.width && frame.height == baseline.height)
        let size = CGSize(width: frame.width, height: frame.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let clear = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
        let reference = try PhotoTextOverlayRenderer.render(image: clear, overlay: overlay)
        let mask = try Pixels(try #require(reference.cgImage))
        var glyphPixels = 0
        var matchingGlyphPixels = 0
        var outsideDifference = 0
        var outsidePixels = 0
        for index in stride(from: 0, to: mask.bytes.count, by: 4) {
            if mask.bytes[index + 3] > 220,
               mask.bytes[index] > 220, mask.bytes[index + 1] > 220, mask.bytes[index + 2] > 220 {
                glyphPixels += 1
                let brightness = frame.brightness(at: index)
                if brightness > 185 && brightness > baseline.brightness(at: index) + 30 {
                    matchingGlyphPixels += 1
                }
            } else if mask.bytes[index + 3] == 0 {
                outsidePixels += 1
                outsideDifference += abs(frame.brightness(at: index) - baseline.brightness(at: index))
            }
        }
        #expect(glyphPixels > 20, "The reference must contain actual opaque glyph pixels")
        #expect(Double(matchingGlyphPixels) / Double(max(1, glyphPixels)) > 0.65,
                "Encoded white glyphs must match the photo renderer, including their upright position")
        #expect(Double(outsideDifference) / Double(max(1, outsidePixels)) < 6,
                "A transparent text overlay must not darken or replace the rest of the video")
    }

    private func decodedFrame(_ url: URL, at seconds: Double) async throws -> Pixels {
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try Pixels(result.image)
    }

    private func expectAudibleAAC(_ asset: AVAsset, minimumDuration: Double) async throws {
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        #expect(try await audio.load(.timeRange).duration.seconds > minimumDuration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try #require(reader.startReading())
        var peak = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { data in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: data.baseAddress!)
            }
            #expect(status == noErr)
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                peak = max(peak, abs(Int(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))))
            }
        }
        #expect(reader.status == .completed)
        #expect(peak > 500, "The real 440 Hz source must still be audible after text and trimming")
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let succeeded = bytes.withUnsafeMutableBytes { data in
                guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try #require(succeeded)
            self.bytes = bytes
        }

        func brightness(at index: Int) -> Int {
            (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
        }
    }
}

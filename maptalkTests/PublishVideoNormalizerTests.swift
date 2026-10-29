import AVFoundation
import Foundation
import ImageIO
import Testing
import VideoToolbox
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

    @Test
    func encodingBudgetCoversWholeMinuteAndFallbacksRemainWithinServerLimits() {
        let attempts = PublishVideoNormalizer.encodingAttempts(duration: 60, visibleSize: CGSize(width: 2160, height: 3840))
        #expect(attempts.count == 3)
        #expect(attempts[0].size == CGSize(width: 720, height: 1280))
        #expect(attempts[1].size == CGSize(width: 540, height: 960))
        #expect(attempts[2].size == CGSize(width: 360, height: 640))
        for attempt in attempts {
            #expect(Double(attempt.bitRate + 128_000) * 60 / 8 < Double(PublishVideoNormalizer.maximumFileBytes) * 0.85)
        }
        #expect(attempts[1].bitRate < attempts[0].bitRate)
        #expect(attempts[2].bitRate < attempts[1].bitRate)
        #expect(PublishVideoNormalizer.maximumFileBytes == 20 * 1_024 * 1_024)
        #expect(PublishVideoNormalizer.maximumDuration == 60)
    }

    @Test
    func trimmingRequiresAnExplicitValidRangeAndNeverSilentlyClamps() throws {
        let source = CMTimeRange(start: .zero, duration: CMTime(seconds: 90, preferredTimescale: 600))
        #expect(throws: PublishVideoNormalizer.ImportError.self) {
            try PublishVideoNormalizer.selectedRange(source: source, requested: nil)
        }
        let requested = CMTimeRange(start: CMTime(seconds: 20, preferredTimescale: 600),
                                    duration: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(try PublishVideoNormalizer.selectedRange(source: source, requested: requested) == requested)
        let beyondEnd = CMTimeRange(start: CMTime(seconds: 40, preferredTimescale: 600), duration: requested.duration)
        #expect(throws: PublishVideoNormalizer.ImportError.self) {
            try PublishVideoNormalizer.selectedRange(source: source, requested: beyondEnd)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func highFrameRateInputIsResampledRatherThanRejected() async throws {
        let source = try await VideoTestFixture.makeVideo(duration: 1, frameRate: 120)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.nominalFrameRate) <= 30.01)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 1) < 0.05)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitTrimKeepsSelectedDurationAndOriginalFile() async throws {
        let source = try await VideoTestFixture.makeVideo(duration: 3, frameRate: 30)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                duration: CMTime(seconds: 1.5, preferredTimescale: 600))
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source, timeRange: range)
        defer { try? FileManager.default.removeItem(at: output) }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 1.5) < 0.05)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(.timeLimit(.minutes(1)))
    func main10HLGInputIsConvertedToSDRH264() async throws {
        let source = try await VideoTestFixture.makeVideo(useHEVC: true, frameRate: 30, hdr: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        #expect(transfer == AVVideoTransferFunction_ITU_R_709_2)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    }

    @Test(.timeLimit(.minutes(1)))
    func normalizingVideoPreservesItsAudioTrack() async throws {
        let source = try await VideoTestFixture.makeVideoWithAudio()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        #expect(try await track.load(.timeRange).duration.seconds > 0.9)
        let reader = try AVAssetReader(asset: AVURLAsset(url: output))
        let audio = try #require(try await reader.asset.loadTracks(withMediaType: .audio).first)
        let decoded = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(decoded)
        #expect(reader.startReading())
        var peak = 0
        while let sample = decoded.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { data in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: data.baseAddress!)
            }
            #expect(status == noErr)
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                peak = max(peak, abs(Int(value)))
            }
        }
        #expect(reader.status == .completed)
        #expect(peak > 500, "The 440 Hz fixture must remain audible, not merely retain an empty audio track")
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceAboveOld512MiBBoundCanNormalizeWithoutLoadingItIntoMemory() async throws {
        let source = try await VideoTestFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        // A valid MP4 free box makes a sparse large-input fixture. It exercises
        // the source byte policy without spending 600 MiB of disk or memory.
        let freeBoxBytes: UInt32 = 600 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: source)
        do {
            let start = try handle.seekToEnd()
            var size = freeBoxBytes.bigEndian
            var header = withUnsafeBytes(of: &size) { Data($0) }
            header.append(contentsOf: [0x66, 0x72, 0x65, 0x65])
            try handle.write(contentsOf: header)
            try handle.truncate(atOffset: start + UInt64(freeBoxBytes))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let output = try await PublishVideoNormalizer.prepare(sourceURL: source)
        defer { try? FileManager.default.removeItem(at: output) }
        try await PublishVideoNormalizer.validatePreparedFile(at: output)
        #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) < PublishVideoNormalizer.maximumFileBytes)
    }
}

/// Tiny real H.264 fixtures exercise AVFoundation without Photos permission,
/// network access, external video files, or a physical camera.
nonisolated enum VideoTestFixture {
    @concurrent
    static func makeVideoWithAudio() async throws -> URL {
        let videoURL = try await makeVideo(frameRate: 30)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = 44_100
        for index in 0..<44_100 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.1) }
        do {
            // Use a real AAC source like an iPhone recording.
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            try audioFile.write(from: buffer)
            audioFile.close()
        }
        let composition = AVMutableComposition()
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        // AVAssetTrack.asset is weak. Keep source assets alive while their
        // tracks are inserted and the composition is exported.
        let sources = [AVURLAsset(url: videoURL), AVURLAsset(url: audioURL)]
        defer { withExtendedLifetime(sources) {} }
        for (asset, mediaType) in zip(sources, [AVMediaType.video, .audio]) {
            let source = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
            let destination = try #require(composition.addMutableTrack(withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: output, as: .mov)
        return output
    }

    @concurrent
    static func makeVideo(duration: Double = 1, transform: CGAffineTransform = .identity,
                          useHEVC: Bool = false, frameRate: Int? = nil, hdr: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .quickTimeMetadataLocationISO6709
        metadata.value = "+37.3688-122.0363/" as NSString
        writer.metadata = [metadata]
        var settings: [String: Any] = [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48
        ]
        if hdr {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32ARGB
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, pixelFormat, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if hdr {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let words = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
                address.assumingMemoryBound(to: UInt16.self).initialize(repeating: 512 << 6, count: words)
            }
        } else if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 100, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let timestamps = frameRate.map { rate in
            (0..<Int((duration * Double(rate)).rounded(.up))).map { Double($0) / Double(rate) }
        } ?? [0.0, max(0.1, duration - 0.05)]
        for timestamp in timestamps {
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

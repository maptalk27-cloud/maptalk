import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Import once, before publishing: a bounded interoperable file is shared by
/// previews and the durable outbox. The original library/camera file is untouched.
nonisolated enum PublishVideoNormalizer {
    static let maximumDuration: Double = 60
    static let maximumFileBytes = 20 * 1_024 * 1_024
    // This is an input safety bound, not the upload or account-storage limit.
    // A short 4K/ProRes source can exceed 512 MiB and still share as a small MP4.
    static let maximumSourceBytes = 2 * 1_024 * 1_024 * 1_024
    static let outputFrameRate: Int32 = 30
    private static let audioBitRate = 128_000

    enum ImportError: LocalizedError {
        case unreadable
        case tooLong
        case tooLarge
        case unsupported
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .unreadable: "This video couldn't be opened. Please choose another video."
            case .tooLong: "Choose a video up to 60 seconds long."
            case .tooLarge: "This video is too large. Please choose a shorter video."
            case .unsupported: "This video couldn't be prepared for sharing. Please choose another video."
            case .insufficientSpace: "There isn't enough free space to prepare this video. Free up some space and try again."
            }
        }
    }

    /// The caller owns the returned file, and must delete it on discard. No
    /// source GPS, captions or timed metadata tracks are copied into the export.
    @concurrent
    static func prepare(sourceURL: URL, timeRange: CMTimeRange? = nil) async throws -> URL {
        do { return try await prepareFile(sourceURL: sourceURL, timeRange: timeRange) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let issue = error as? ImportError { throw issue }
            throw ImportError.unreadable
        }
    }

    @concurrent
    private static func prepareFile(sourceURL: URL, timeRange: CMTimeRange?) async throws -> URL {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw ImportError.unreadable }
        let bytes = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw ImportError.unreadable }
        guard bytes <= maximumSourceBytes else { throw ImportError.tooLarge }
        let source = AVURLAsset(url: sourceURL)
        defer { withExtendedLifetime(source) {} }
        guard let video = try await source.loadTracks(withMediaType: .video).first else {
            throw ImportError.unreadable
        }
        // AAC encoder padding may make a 60-second camera movie's container
        // slightly longer. The picture timeline, not that padding, is the clip.
        let sourceRange = try await video.load(.timeRange)
        let range = try selectedRange(source: sourceRange, requested: timeRange)
        let duration = range.duration
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw ImportError.unreadable }
        guard duration.seconds <= maximumDuration + 0.001 else { throw ImportError.tooLong }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ImportError.unsupported }
        try picture.insertTimeRange(range, of: video, at: .zero)
        let sourceTransform = try await video.load(.preferredTransform)
        let naturalSize = try await video.load(.naturalSize)
        let visibleBounds = CGRect(origin: .zero, size: naturalSize).applying(sourceTransform).standardized
        guard visibleBounds.width.isFinite, visibleBounds.height.isFinite,
              visibleBounds.width > 0, visibleBounds.height > 0 else { throw ImportError.unreadable }
        var soundTrack: AVMutableCompositionTrack?
        if let audio = try await source.loadTracks(withMediaType: .audio).first,
           let sound = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange).intersection(range)
            if audioRange.duration.seconds > 0 {
                try sound.insertTimeRange(audioRange, of: audio, at: CMTimeSubtract(audioRange.start, range.start))
                soundTrack = sound
            }
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTalkMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < Int64(maximumFileBytes * 3) { throw ImportError.insufficientSpace }

        var lastIssue: ImportError = .unsupported
        for attempt in encodingAttempts(duration: duration.seconds, visibleSize: visibleBounds.size) {
            try Task.checkCancellation()
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            do {
                try await transcode(composition: composition, picture: picture, sound: soundTrack,
                    transform: sourceTransform, bounds: visibleBounds, duration: duration,
                    attempt: attempt, output: output)
                try await validatePreparedFile(at: output)
                let exportedAsset = AVURLAsset(url: output)
                defer { withExtendedLifetime(exportedAsset) {} }
                let exportedTrack = try await exportedAsset.loadTracks(withMediaType: .video).first
                guard let exportedTrack else { throw ImportError.unsupported }
                let exportedDuration = try await exportedTrack.load(.timeRange).duration
                // Never fit a byte budget by silently truncating somebody's clip.
                guard abs(exportedDuration.seconds - duration.seconds) <= 0.15 else { throw ImportError.unsupported }
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let known = error as? ImportError { lastIssue = known }
            }
        }
        throw lastIssue
    }

    /// A user-selected range is explicit; an overlong original is never cut here.
    static func selectedRange(source: CMTimeRange, requested: CMTimeRange?) throws -> CMTimeRange {
        let range = requested ?? source
        guard range.isValid, !range.isEmpty, range.start.seconds.isFinite,
              range.duration.seconds.isFinite, range.duration.seconds > 0,
              range.start.seconds >= source.start.seconds - 0.001,
              range.end.seconds <= source.end.seconds + 0.001 else { throw ImportError.unreadable }
        guard range.duration.seconds <= maximumDuration + 0.001 else { throw ImportError.tooLong }
        return range
    }

    struct EncodingAttempt {
        let size: CGSize
        let bitRate: Int
    }

    /// Reserve room for audio and MP4 overhead. Encoding uses this full-timeline
    /// budget rather than AVAssetExportSession.fileLengthLimit, which can stop early.
    static func encodingAttempts(duration: Double, visibleSize: CGSize) -> [EncodingAttempt] {
        let budget = max(256_000, Int(Double(maximumFileBytes) * 0.82 * 8 / max(1, duration)) - audioBitRate)
        return [(1280.0, 720.0, 1.0), (960.0, 540.0, 0.70), (640.0, 360.0, 0.45)].map { long, short, factor in
            let scale = min(1, long / max(visibleSize.width, visibleSize.height),
                            short / min(visibleSize.width, visibleSize.height))
            let size = CGSize(width: max(2, floor(visibleSize.width * scale / 2) * 2),
                              height: max(2, floor(visibleSize.height * scale / 2) * 2))
            return EncodingAttempt(size: size, bitRate: max(128_000, Int(Double(min(4_000_000, budget)) * factor)))
        }
    }

    private static var sdrColorProperties: [String: String] {
        [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    @concurrent
    private static func transcode(composition: AVComposition, picture: AVCompositionTrack,
                                  sound: AVCompositionTrack?, transform: CGAffineTransform,
                                  bounds: CGRect, duration: CMTime, attempt: EncodingAttempt, output: URL) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = []

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: picture)
        let scaled = transform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: attempt.size.width / bounds.width,
                                           y: attempt.size.height / bounds.height))
        layer.setTransform(scaled, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        // Apple's HDR-to-SDR conversion: specify Rec.709 in the compositor
        // before reducing to 8-bit pixels, not just on the final container.
        let videoComposition = AVVideoComposition(configuration: .init(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            frameDuration: CMTime(value: 1, timescale: outputFrameRate),
            instructions: [instruction], renderSize: attempt.size))
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [picture], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoColorPropertiesKey: sdrColorProperties
        ])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(attempt.size.width), AVVideoHeightKey: Int(attempt.size.height),
            AVVideoColorPropertiesKey: sdrColorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: attempt.bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(outputFrameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(outputFrameRate) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw ImportError.unsupported }
        reader.add(videoOutput)
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let sound {
            let read = AVAssetReaderTrackOutput(track: sound, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            read.alwaysCopiesSampleData = false
            let write = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitRate
            ])
            guard reader.canAdd(read), writer.canAdd(write) else { throw ImportError.unsupported }
            reader.add(read)
            writer.add(write)
            audioOutput = read
            audioInput = write
        }

        guard writer.startWriting() else { throw writer.error ?? ImportError.unsupported }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? ImportError.unreadable
        }
        do {
            var videoDone = false
            var audioDone = audioInput == nil
            var lastProgress = ContinuousClock.now
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                if reader.status == .failed { throw reader.error ?? ImportError.unreadable }
                if writer.status == .failed { throw writer.error ?? ImportError.unsupported }
                var progressed = false
                if !videoDone, videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw writer.error ?? ImportError.unsupported }
                    } else {
                        videoInput.markAsFinished()
                        videoDone = true
                    }
                    progressed = true
                }
                if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else { throw writer.error ?? ImportError.unsupported }
                    } else {
                        audioInput.markAsFinished()
                        audioDone = true
                    }
                    progressed = true
                }
                if progressed { lastProgress = .now }
                else {
                    guard lastProgress.duration(to: .now) < .seconds(30) else { throw ImportError.unsupported }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            guard reader.status != .failed else { throw reader.error ?? ImportError.unreadable }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ImportError.unsupported }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    @concurrent
    static func validatePreparedFile(at url: URL) async throws {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumFileBytes else { throw ImportError.tooLarge }
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0,
              duration.seconds <= maximumDuration + 0.1 else { throw ImportError.tooLong }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw ImportError.unsupported }
        let videoDuration = try await track.load(.timeRange).duration.seconds
        guard videoDuration.isFinite, videoDuration > 0, videoDuration <= maximumDuration + 0.001 else {
            throw ImportError.tooLong
        }
        let size = try await track.load(.naturalSize)
        guard max(size.width, size.height) <= 1280, min(size.width, size.height) <= 720 else {
            throw ImportError.unsupported
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw ImportError.unsupported
        }
        let frameRate = try await track.load(.nominalFrameRate)
        guard frameRate.isFinite, frameRate <= 60.01 else { throw ImportError.unsupported }
    }

    /// Small, metadata-free covers are generated locally after an authenticated
    /// download; the player uses the protected local MP4, never a token in a URL.
    @concurrent
    static func posterJPEG(at url: URL) async throws -> Data {
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let frame = try await generator.image(at: .zero)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable
        }
        CGImageDestinationAddImage(destination, frame.image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return data as Data
    }
}

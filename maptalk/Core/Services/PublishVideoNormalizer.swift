import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Import once, before publishing: a bounded interoperable file is shared by
/// previews and the durable outbox. The original library/camera file is untouched.
nonisolated enum PublishVideoNormalizer {
    static let maximumDuration: Double = 60
    static let maximumFileBytes = 20 * 1_024 * 1_024
    private static let maximumSourceBytes = 512 * 1_024 * 1_024

    enum ImportError: LocalizedError {
        case unreadable
        case tooLong
        case tooLarge
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unreadable: "This video couldn't be opened. Please choose another video."
            case .tooLong: "Choose a video up to 60 seconds long."
            case .tooLarge: "This video is too large. Please choose a shorter video."
            case .unsupported: "This video couldn't be prepared for sharing. Please choose another video."
            }
        }
    }

    /// The caller owns the returned file, and must delete it on discard. No
    /// source GPS, captions or timed metadata tracks are copied into the export.
    @concurrent
    static func prepare(sourceURL: URL) async throws -> URL {
        do { return try await prepareFile(sourceURL: sourceURL) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let issue = error as? ImportError { throw issue }
            throw ImportError.unreadable
        }
    }

    @concurrent
    private static func prepareFile(sourceURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw ImportError.unreadable }
        let bytes = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw ImportError.unreadable }
        guard bytes <= maximumSourceBytes else { throw ImportError.tooLarge }
        let source = AVURLAsset(url: sourceURL)
        guard let video = try await source.loadTracks(withMediaType: .video).first else {
            throw ImportError.unreadable
        }
        // AAC encoder padding may make a 60-second camera movie's container
        // slightly longer. The picture timeline, not that padding, is the clip.
        let range = try await video.load(.timeRange)
        let duration = range.duration
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw ImportError.unreadable }
        guard duration.seconds <= maximumDuration + 0.001 else { throw ImportError.tooLong }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ImportError.unsupported }
        try picture.insertTimeRange(range, of: video, at: .zero)
        picture.preferredTransform = try await video.load(.preferredTransform)
        if let audio = try await source.loadTracks(withMediaType: .audio).first,
           let sound = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange).intersection(range)
            if audioRange.duration.seconds > 0 {
                try sound.insertTimeRange(audioRange, of: audio, at: CMTimeSubtract(audioRange.start, range.start))
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else {
            throw ImportError.unsupported
        }
        exporter.metadata = []
        exporter.metadataItemFilter = AVMetadataItemFilter.forSharing()
        exporter.shouldOptimizeForNetworkUse = true
        exporter.fileLengthLimit = Int64(maximumFileBytes)
        exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTalkMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        do {
            try await exporter.export(to: output, as: .mp4)
            try Task.checkCancellation()
            try await validatePreparedFile(at: output)
            let exportedTrack = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first
            guard let exportedTrack else { throw ImportError.unsupported }
            let exportedDuration = try await exportedTrack.load(.timeRange).duration
            // A size-constrained exporter must never silently publish only the
            // beginning of a clip. Ask for a shorter source instead.
            guard abs(exportedDuration.seconds - duration.seconds) <= 0.15 else { throw ImportError.tooLarge }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let known = error as? ImportError { throw known }
            throw ImportError.unsupported
        }
    }

    @concurrent
    static func validatePreparedFile(at url: URL) async throws {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumFileBytes else { throw ImportError.tooLarge }
        let asset = AVURLAsset(url: url)
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

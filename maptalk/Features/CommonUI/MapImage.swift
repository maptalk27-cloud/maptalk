import SwiftUI
import UIKit
import ImageIO

/// Same presentation API as AsyncImage, with support for private on-device
/// media downloaded through the authenticated client. No card layout changes.
struct MapImage<Content: View>: View {
    let url: URL?
    /// The rendered size in points for an aspect-fill thumbnail. Omit for detail media.
    private let thumbnailSize: CGSize?
    private let content: (AsyncImagePhase) -> Content
    @Environment(\.displayScale) private var displayScale
    @State private var localPhase: AsyncImagePhase = .empty
    @State private var localPhaseRequest: LocalMapImageRequest?

    init(url: URL?, thumbnailSize: CGSize? = nil,
         @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.thumbnailSize = thumbnailSize
        self.content = content
    }

    init<I: View, P: View>(url: URL?, thumbnailSize: CGSize? = nil,
                          @ViewBuilder content: @escaping (Image) -> I,
                          @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P> {
        self.init(url: url, thumbnailSize: thumbnailSize) { phase in
            if let image = phase.image { content(image) }
            else { placeholder() }
        }
    }

    var body: some View {
        if let url, url.isFileURL {
            let request = LocalMapImageRequest(url: url,
                target: thumbnailSize.flatMap { LocalMapImageTarget(size: $0, displayScale: displayScale) })
            // Keep the same photo visible during a resolution upgrade. A URL change still
            // hides the previous photo immediately, before the next task starts.
            content(localPhaseRequest?.url == url ? localPhase : .empty)
                .task(id: request) {
                    if localPhaseRequest?.url != url { localPhase = .empty }
                    localPhaseRequest = request
                    do {
                        let decoded = try await LocalMapImageLoader.shared.image(at: url,
                            thumbnailSize: thumbnailSize, displayScale: displayScale)
                        try Task.checkCancellation()
                        guard localPhaseRequest == request else { return }
                        localPhase = .success(Image(uiImage: UIImage(cgImage: decoded.image)))
                    } catch is CancellationError { }
                    catch {
                        guard Task.isCancelled == false, localPhaseRequest == request else { return }
                        localPhase = .failure(error)
                    }
                }
        } else {
            AsyncImage(url: url, content: content)
        }
    }
}

/// Include resolution in task identity so opening the same URL at detail size cannot keep
/// a thumbnail's pixels, and an old URL/size request cannot replace the current phase.
private nonisolated struct LocalMapImageRequest: Hashable {
    let url: URL
    let target: LocalMapImageTarget?
}

private nonisolated struct LocalMapImageTarget: Hashable {
    let width: Int
    let height: Int

    init?(size: CGSize, displayScale: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, displayScale.isFinite,
              size.width > 0, size.height > 0, displayScale > 0 else { return nil }
        width = Int(min(2_048, max(1, ceil(size.width * displayScale))))
        height = Int(min(2_048, max(1, ceil(size.height * displayScale))))
    }
}

/// Immutable, already-decoded pixels can safely cross from the loader actor to SwiftUI.
nonisolated final class LocalMapDecodedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private nonisolated final class LocalMapImageMetadata {
    let width: Double
    let height: Double

    init(source: CGImageSource) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }
        self.width = width
        self.height = height
    }
}

/// File access and ImageIO decompression run on this actor, never the main actor. Keeping one
/// small cache reuses matching resolution tiers without letting a marker downgrade a story.
actor LocalMapImageLoader {
    static let shared = LocalMapImageLoader()
    private let cache = NSCache<NSString, LocalMapDecodedImage>()
    private let metadataCache = NSCache<NSString, LocalMapImageMetadata>()
    private let maximumPixelSize = 2_048
    #if DEBUG
    private(set) var sourceOpenCount = 0
    #endif

    init() {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 256
        metadataCache.countLimit = 256
    }

    func image(at url: URL, thumbnailSize: CGSize? = nil,
               displayScale: CGFloat = 1) throws -> LocalMapDecodedImage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Inspect the file even on a cache hit: deletion on sign-out must not serve a stale
        // cached photo, and replacing bytes at the same path must invalidate the old pixels.
        let fingerprint = try fileFingerprint(at: url)
        let fileKey = "\(url.absoluteString)|\(fingerprint)"
        let target = thumbnailSize.flatMap { LocalMapImageTarget(size: $0, displayScale: displayScale) }
        let cachedMetadata = metadataCache.object(forKey: fileKey as NSString)
        // A warm scroll lookup only stats the file and checks memory. Reading ImageIO's
        // source/header again would serialize every visible thumbnail through disk work.
        if target == nil || cachedMetadata != nil {
            let outputSize = maximumPixelSize(for: cachedMetadata, target: target)
            if let cached = cache.object(forKey: "\(fileKey)|\(outputSize)" as NSString) {
                try Task.checkCancellation()
                return cached
            }
        }
        let source = try imageSource(at: url)
        let metadata = cachedMetadata ?? LocalMapImageMetadata(source: source)
        let outputSize = maximumPixelSize(for: metadata, target: target)
        let key = "\(fileKey)|\(outputSize)" as NSString
        if let cached = cache.object(forKey: key) {
            try Task.checkCancellation()
            guard try fileFingerprint(at: url) == fingerprint else { throw CocoaError(.fileReadUnknown) }
            metadataCache.setObject(metadata, forKey: fileKey as NSString)
            return cached
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: outputSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        // Do not publish a decode if sign-out or file replacement happened during ImageIO work.
        guard try fileFingerprint(at: url) == fingerprint else { throw CocoaError(.fileReadUnknown) }
        let result = LocalMapDecodedImage(image)
        metadataCache.setObject(metadata, forKey: fileKey as NSString)
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }

    private func imageSource(at url: URL) throws -> CGImageSource {
        #if DEBUG
        sourceOpenCount += 1
        #endif
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return source
    }

    private func maximumPixelSize(for metadata: LocalMapImageMetadata?, target: LocalMapImageTarget?) -> Int {
        guard let target, let metadata,
              metadata.width > 0, metadata.height > 0 else { return maximumPixelSize }
        let width = metadata.width
        let height = metadata.height
        // A square marker cropping a landscape photo needs enough pixels on its short edge.
        // ImageIO still returns the full, orientation-corrected image; existing SwiftUI crop
        // and frame behavior is unchanged. Detail requests retain the original 2048px limit.
        let fillScale = max(Double(target.width) / width, Double(target.height) / height)
        let required = min(Double(maximumPixelSize), ceil(max(width, height) * min(1, fillScale)))
        return [64, 128, 256, 512, 1_024, maximumPixelSize].first { Double($0) >= required }
            ?? maximumPixelSize
    }

    private func fileFingerprint(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(modified)|\(created)|\(bytes)|\(fileNumber)"
    }
}

import SwiftUI
import UIKit
import ImageIO

/// Same presentation API as AsyncImage, with support for private on-device
/// media downloaded through the authenticated client. No card layout changes.
struct MapImage<Content: View>: View {
    let url: URL?
    private let content: (AsyncImagePhase) -> Content
    @State private var localPhase: AsyncImagePhase = .empty
    @State private var localPhaseURL: URL?

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    init<I: View, P: View>(url: URL?, @ViewBuilder content: @escaping (Image) -> I,
                          @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if let image = phase.image { content(image) }
            else { placeholder() }
        }
    }

    var body: some View {
        if let url, url.isFileURL {
            content(localPhaseURL == url ? localPhase : .empty)
                .task(id: url) {
                    localPhaseURL = url
                    localPhase = .empty
                    do {
                        let decoded = try await LocalMapImageLoader.shared.image(at: url)
                        try Task.checkCancellation()
                        guard localPhaseURL == url else { return }
                        localPhase = .success(Image(uiImage: UIImage(cgImage: decoded.image)))
                    } catch is CancellationError { }
                    catch {
                        guard Task.isCancelled == false, localPhaseURL == url else { return }
                        localPhase = .failure(error)
                    }
                }
        } else {
            AsyncImage(url: url, content: content)
        }
    }
}

/// Immutable, already-decoded pixels can safely cross from the loader actor to SwiftUI.
nonisolated final class LocalMapDecodedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// File access and ImageIO decompression run on this actor, never the main actor. Keeping one
/// small cache also avoids decoding the same photo separately for its map, list and story card.
actor LocalMapImageLoader {
    static let shared = LocalMapImageLoader()
    private let cache = NSCache<NSString, LocalMapDecodedImage>()
    private let maximumPixelSize = 2_048

    init() {
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 32
    }

    func image(at url: URL) throws -> LocalMapDecodedImage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Inspect the file even on a cache hit: deletion on sign-out must not serve a stale
        // cached photo, and replacing bytes at the same path must invalidate the old pixels.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let key = "\(url.absoluteString)|\(modified)|\(bytes)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        let result = LocalMapDecodedImage(image)
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}

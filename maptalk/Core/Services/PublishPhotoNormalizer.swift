import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A bounded, metadata-free photo is used for both the composer preview and upload.
/// The user's original photo is never modified, cropped, or retained by this helper.
nonisolated enum PublishPhotoNormalizer {
    static let maximumPixelSize = 2_048
    private static let maximumSourcePixels = 256_000_000.0
    private static let maximumSourceFileBytes = 256 * 1_024 * 1_024

    struct Photo: Sendable {
        let jpegData: Data
        let preview: LocalMapDecodedImage
    }

    enum ImportError: LocalizedError {
        case unreadable
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "This photo couldn't be opened. Please choose another photo."
            case .tooLarge: "This photo is too large to process safely. Please choose another photo."
            }
        }
    }

    /// ImageIO downsamples directly from the picker-owned file; it does not first
    /// allocate a full-resolution UIImage (a 48 MP image can otherwise use 192 MB).
    static func prepare(at url: URL) throws -> Photo {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values.fileSize, bytes > 0, bytes <= maximumSourceFileBytes else {
            throw ImportError.tooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            throw ImportError.unreadable
        }
        try validate(width: width, height: height)
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary) else { throw ImportError.unreadable }
        try Task.checkCancellation()
        return try encode(thumbnail)
    }

    /// Camera capture already arrives as a UIImage. Render directly to a bounded
    /// canvas instead of encoding and re-decoding the entire original first.
    static func prepare(cameraImage image: UIImage) throws -> Photo {
        try Task.checkCancellation()
        let sizeInPixels: CGSize
        if let pixels = image.cgImage {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                sizeInPixels = CGSize(width: pixels.height, height: pixels.width)
            default:
                sizeInPixels = CGSize(width: pixels.width, height: pixels.height)
            }
        } else {
            sizeInPixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        let width = sizeInPixels.width
        let height = sizeInPixels.height
        try validate(width: width, height: height)
        let ratio = min(1, CGFloat(maximumPixelSize) / max(width, height))
        let size = CGSize(width: max(1, (width * ratio).rounded()),
                          height: max(1, (height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pixels = rendered.cgImage else { throw ImportError.unreadable }
        try Task.checkCancellation()
        return try encode(pixels)
    }

    private static func validate(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw ImportError.unreadable
        }
        guard width <= 131_072, height <= 131_072, width * height <= maximumSourcePixels else {
            throw ImportError.tooLarge
        }
    }

    private static func encode(_ source: CGImage) throws -> Photo {
        // Use a small standard-range canvas for consistent JPEG and preview
        // colors, including HEIC/HDR sources and images with transparency.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImportError.unreadable }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        canvas.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let pixels = canvas.makeImage() else { throw ImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
            UTType.jpeg.identifier as CFString, 1, nil) else { throw ImportError.unreadable }
        // Add pixels, not the source image: no EXIF, GPS, camera serial number,
        // or source orientation metadata survives. Orientation is already applied.
        CGImageDestinationAddImage(destination, pixels,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        guard output.length <= 10 * 1_024 * 1_024 else { throw ImportError.tooLarge }
        try Task.checkCancellation()
        return Photo(jpegData: output as Data, preview: LocalMapDecodedImage(pixels))
    }
}

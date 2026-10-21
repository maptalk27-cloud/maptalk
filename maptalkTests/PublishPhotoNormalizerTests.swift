import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import maptalk

@MainActor
struct PublishPhotoNormalizerTests {
    @Test
    func normalPhone48MPPhotoIsDownsampledBeforeUploadWithoutCroppingOrChangingOriginal() throws {
        let original = try photoFile(width: 8_000, height: 6_000)
        defer { try? FileManager.default.removeItem(at: original) }
        let originalBytes = try Data(contentsOf: original)

        let photo = try PublishPhotoNormalizer.prepare(at: original)
        #expect(photo.preview.image.width == 2_048)
        #expect(photo.preview.image.height == 1_536)
        #expect(photo.jpegData.count < 10 * 1_024 * 1_024)
        #expect(try Data(contentsOf: original) == originalBytes)
        let encoded = try properties(of: photo.jpegData)
        #expect((encoded[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2_048)
        #expect((encoded[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 1_536)
    }

    @Test
    func albumOrientationIsAppliedAndPrivateSourceMetadataIsNotUploaded() throws {
        let original = try photoFile(width: 3_000, height: 1_500, orientation: 6)
        defer { try? FileManager.default.removeItem(at: original) }

        let photo = try PublishPhotoNormalizer.prepare(at: original)
        #expect(photo.preview.image.width == 1_024)
        #expect(photo.preview.image.height == 2_048)
        let encoded = try properties(of: photo.jpegData)
        #expect(encoded[kCGImagePropertyGPSDictionary] == nil)
        let originalProperties = try properties(of: Data(contentsOf: original))
        let originalExif = try #require(originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(originalExif[kCGImagePropertyExifBodySerialNumber] as? String == "Private camera serial")
        // ImageIO writes fresh codec metadata (color space and output pixel
        // dimensions). That is not private source metadata and is safe to keep.
        let exif = encoded[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment] == nil)
        #expect(exif[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(exif[kCGImagePropertyExifLensSerialNumber] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeDigitized] == nil)
        #expect(encoded[kCGImagePropertyTIFFDictionary] == nil)
        let orientation = (encoded[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        #expect(orientation == nil || orientation == 1)
    }

    @Test
    func smallPhotoIsNotUpscaledAndPanoramaKeepsItsShape() throws {
        for (width, height, expectedWidth, expectedHeight) in [
            (600, 400, 600, 400), (8_192, 1_024, 2_048, 256), (400, 600, 400, 600)
        ] {
            let original = try photoFile(width: width, height: height)
            defer { try? FileManager.default.removeItem(at: original) }
            let photo = try PublishPhotoNormalizer.prepare(at: original)
            #expect(photo.preview.image.width == expectedWidth)
            #expect(photo.preview.image.height == expectedHeight)
        }
    }

    @Test
    func cameraCaptureUsesTheSameBoundedAspectRatioAndJPEGContract() throws {
        let pixels = try image(width: 4_032, height: 3_024)
        let cameraImage = UIImage(cgImage: pixels)
        let photo = try PublishPhotoNormalizer.prepare(cameraImage: cameraImage)
        #expect(photo.preview.image.width == 2_048)
        #expect(photo.preview.image.height == 1_536)
        let encoded = try properties(of: photo.jpegData)
        #expect(encoded[kCGImagePropertyGPSDictionary] == nil)
        #expect(photo.jpegData.count < 10 * 1_024 * 1_024)
    }

    @Test
    func rotatedCameraCaptureHasUprightPortraitDimensionsRatherThanStretchingLandscapePixels() throws {
        let pixels = try image(width: 4_032, height: 3_024)
        let cameraImage = UIImage(cgImage: pixels, scale: 2, orientation: .right)
        let photo = try PublishPhotoNormalizer.prepare(cameraImage: cameraImage)
        #expect(photo.preview.image.width == 1_536)
        #expect(photo.preview.image.height == 2_048)
    }

    @Test
    func invalidInputFailsWithoutCreatingAnUpload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not an image".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: PublishPhotoNormalizer.ImportError.self) {
            try PublishPhotoNormalizer.prepare(at: file)
        }
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        // Grayscale fixture needs only one byte per source pixel, keeping the
        // 48 MP regression fixture itself inexpensive in test-runner memory.
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func photoFile(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width, height: height), [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.6,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.3,
                kCGImagePropertyGPSLongitudeRef: "W"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "Private photo description",
                kCGImagePropertyExifBodySerialNumber: "Private camera serial",
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Private camera model"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}

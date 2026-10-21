import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import maptalk

@MainActor
struct ProfileAvatarCropTests {
    @Test
    func initialCropFillsCircleForPortraitAndLandscapeWithoutStretching() {
        #expect(ProfileAvatarCropGeometry.centeredSquare(in: CGSize(width: 400, height: 200))
            == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(ProfileAvatarCropGeometry.centeredSquare(in: CGSize(width: 200, height: 400))
            == CGRect(x: 0, y: 100, width: 200, height: 200))
        let crop = ProfileAvatarCropGeometry.visibleSquare(offset: CGPoint(x: 200, y: 0),
            zoomScale: 2, viewportSide: 200, imageSize: CGSize(width: 400, height: 200))
        #expect(crop == CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    @Test
    func edgeDragsAreClampedWithoutBlankPixelsOrNonSquareOutput() {
        let size = CGSize(width: 400, height: 200)
        #expect(ProfileAvatarCropGeometry.clampedSquare(
            CGRect(x: 3_000, y: -100, width: 180, height: 180), in: size)
            == CGRect(x: 220, y: 0, width: 180, height: 180))
        #expect(ProfileAvatarCropGeometry.clampedSquare(
            CGRect(x: -400, y: -400, width: 600, height: 600), in: size)
            == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(ProfileAvatarCropGeometry.visibleSquare(offset: .zero, zoomScale: 0,
            viewportSide: 200, imageSize: size) == nil)
        #expect(ProfileAvatarCropGeometry.clampedSquare(
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), in: size) == nil)
    }

    @Test
    func confirmedFramingUsesSelectedPixelsRatherThanAutomaticCenterCrop() async throws {
        let image = try stripedImage(width: 400, height: 200)
        let source = ProfileAvatarCropSource(preview: LocalMapDecodedImage(image))
        let photo = try await ProfileAvatarProcessor.shared.crop(source,
            rect: CGRect(x: 300, y: 0, width: 100, height: 100))
        #expect(photo.preview.image.width == 100)
        #expect(photo.preview.image.height == 100)
        let sample = try centerPixel(photo.preview.image)
        #expect(sample[1] > 220, "The chosen right-hand green region must become the avatar")
        #expect(sample[0] < 20)
        #expect(sample[2] < 20)
    }

    @Test
    func largeCropIsBoundedTo1024AndSmallCropIsNotUpscaled() async throws {
        for side in [96, 1_600] {
            let source = ProfileAvatarCropSource(preview: LocalMapDecodedImage(
                try stripedImage(width: side * 2, height: side)))
            let photo = try await ProfileAvatarProcessor.shared.crop(source,
                rect: ProfileAvatarCropGeometry.centeredSquare(in: source.size))
            let expected = min(1_024, side)
            #expect(photo.preview.image.width == expected)
            #expect(photo.preview.image.height == expected)
            let properties = try properties(of: photo.jpegData)
            #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == expected)
            #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == expected)
        }
    }

    @Test
    func importKeepsFullOrientedImageAndCropDropsSourceMetadata() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try stripedImage(width: 300, height: 150), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6,
                                          kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private note"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)

        let source = try await ProfileAvatarProcessor.shared.prepareSource(at: url)
        #expect(source.size == CGSize(width: 150, height: 300),
                "Rotation must be applied without cropping away the unselected parts of the photo")
        let photo = try await ProfileAvatarProcessor.shared.crop(source,
            rect: CGRect(x: 0, y: 150, width: 150, height: 150))
        let output = try properties(of: photo.jpegData)
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
        let exif = output[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        let orientation = (output[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        #expect(orientation == nil || orientation == 1)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func cancellingReplacementKeepsPreviouslyConfirmedDraftAndInitialCancelChangesNothing() async throws {
        let source = ProfileAvatarCropSource(preview: LocalMapDecodedImage(
            try stripedImage(width: 400, height: 200)))
        var draft = ProfileAvatarDraft()
        draft.begin(source)
        draft.cancelCrop()
        #expect(draft.photo == nil)
        #expect(draft.source == nil)

        let confirmed = try await ProfileAvatarProcessor.shared.crop(source,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        draft.begin(source)
        draft.confirm(confirmed)
        draft.begin(ProfileAvatarCropSource(preview: source.preview))
        #expect(draft.photo?.jpegData == confirmed.jpegData,
                "Selecting a replacement must not commit it before Use")
        draft.cancelCrop()
        #expect(draft.photo?.jpegData == confirmed.jpegData)
        #expect(draft.source == nil)
    }

    private func stripedImage(width: Int, height: Int) throws -> CGImage {
        let canvas = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        canvas.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(canvas.makeImage())
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let canvas = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}

import Foundation
import Testing
import UIKit
@testable import maptalk

@MainActor
struct PhotoTextOverlayTests {
    @Test
    func emptyAndClearedOverlayReturnExactOriginalWithoutReencoding() throws {
        let original = try stripedImage(width: 320, height: 180)
        for text in ["", " \n\t "] {
            let result = try PhotoTextOverlayRenderer.render(image: original,
                overlay: PhotoTextOverlay(text: text))
            #expect(result === original)
            #expect(result.cgImage === original.cgImage)
        }
    }

    @Test
    func outputKeepsEveryPixelDimensionAndNeverMutatesOriginal() throws {
        for (width, height) in [(640, 360), (360, 640), (96, 96), (1_200, 160)] {
            let original = try stripedImage(width: width, height: height)
            let before = try #require(original.pngData())
            let output = try PhotoTextOverlayRenderer.render(image: original,
                overlay: PhotoTextOverlay(text: "Meet me here 🌴"))
            let pixels = try #require(output.cgImage)
            #expect(pixels.width == width)
            #expect(pixels.height == height)
            #expect(output.imageOrientation == .up)
            #expect(output.scale == 1)
            #expect(original.pngData() == before)
            #expect(output.pngData() != before, "Words must be burned into the exported pixels")
        }
    }

    @Test
    func rotatedAndMirroredSourcesAreExportedUprightAtTheirOrientedResolution() throws {
        let pixels = try #require(try stripedImage(width: 400, height: 240).cgImage)
        for orientation in [UIImage.Orientation.up, .upMirrored, .down, .downMirrored,
                            .left, .leftMirrored, .right, .rightMirrored] {
            let source = UIImage(cgImage: pixels, scale: 2, orientation: orientation)
            let swapsAxes = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
            let expectedSize = swapsAxes ? CGSize(width: 240, height: 400) : CGSize(width: 400, height: 240)
            #expect(PhotoTextOverlayRenderer.orientedPixelSize(of: source) == expectedSize)
            let rendered = try PhotoTextOverlayRenderer.render(image: source,
                overlay: PhotoTextOverlay(text: "Aloha"))
            #expect(rendered.size == expectedSize)
            #expect(rendered.imageOrientation == .up)
            #expect(source.imageOrientation == orientation)
            #expect(source.scale == 2)
            #expect(source.cgImage === pixels)
        }
    }

    @Test
    func placementIsClampedUsingTheWholeMultilineBoxInsteadOfOnlyItsCenter() throws {
        let size = CGSize(width: 360, height: 640)
        for center in [CGPoint(x: -8, y: 20), CGPoint(x: 1, y: 0),
                       CGPoint(x: CGFloat.nan, y: .infinity)] {
            let draft = PhotoTextOverlay(text: "A little note\ninside the photo", center: center)
            let layout = try #require(PhotoTextOverlayRenderer.layout(for: draft, in: size))
            #expect(layout.backgroundRect.minX >= 0)
            #expect(layout.backgroundRect.minY >= 0)
            #expect(layout.backgroundRect.maxX <= size.width)
            #expect(layout.backgroundRect.maxY <= size.height)
            #expect(layout.center.x.isFinite)
            #expect(layout.center.y.isFinite)
            let clamped = PhotoTextOverlayRenderer.clamped(draft, in: size)
            #expect(abs(clamped.center.x - layout.center.x) < 0.000_001)
            #expect(abs(clamped.center.y - layout.center.y) < 0.000_001)
            let second = try #require(PhotoTextOverlayRenderer.layout(for: clamped, in: size))
            #expect(abs(second.backgroundRect.minX - layout.backgroundRect.minX) < 0.001)
            #expect(abs(second.backgroundRect.minY - layout.backgroundRect.minY) < 0.001)
        }
    }

    @Test
    func previewAndExportLayoutScaleTogetherForSameAspectRatio() throws {
        let draft = PhotoTextOverlay(text: "夕阳很好\nSee you here 🌅", center: CGPoint(x: 0.25, y: 0.9))
        let small = try #require(PhotoTextOverlayRenderer.layout(for: draft,
            in: CGSize(width: 300, height: 400)))
        let large = try #require(PhotoTextOverlayRenderer.layout(for: draft,
            in: CGSize(width: 1_200, height: 1_600)))
        #expect(abs(small.center.x - large.center.x) < 0.003)
        #expect(abs(small.center.y - large.center.y) < 0.003)
        #expect(abs(small.backgroundRect.width * 4 - large.backgroundRect.width) < 3)
        #expect(abs(small.backgroundRect.height * 4 - large.backgroundRect.height) < 3)
        #expect(abs(small.textCanvasSize.width - large.textCanvasSize.width) < 0.000_001)
        #expect(abs(small.textCanvasSize.height - large.textCanvasSize.height) < 0.000_001)
        #expect(small.font.pointSize == large.font.pointSize,
                "Preview and export must scale the same laid-out glyphs, not reflow at a different font size")
        #expect(abs(small.textScale * 4 - large.textScale) < 0.000_001)
    }

    @Test
    func unicodeIsBoundedOnWholeCharactersAndLongMultilineTextFits() throws {
        let family = "👨‍👩‍👧‍👦"
        let combined = "e\u{301}"
        for text in [String(repeating: family, count: 250), String(repeating: combined, count: 250),
                     String(repeating: "远", count: 250), String(repeating: "A\n", count: 120),
                     "مرحبا بالعالم 🌍\nこんにちは"] {
            let draft = PhotoTextOverlayRenderer.sanitized(PhotoTextOverlay(text: text))
            #expect(draft.text.count <= PhotoTextOverlayRenderer.maximumCharacters)
            #expect(draft.text.utf16.count <= 2_048)
            #expect(text.hasPrefix(draft.text))
            for size in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320),
                         CGSize(width: 1_200, height: 120)] {
                let layout = try #require(PhotoTextOverlayRenderer.layout(for: draft, in: size))
                #expect(layout.backgroundRect.minX >= 0)
                #expect(layout.backgroundRect.minY >= 0)
                #expect(layout.backgroundRect.maxX <= size.width)
                #expect(layout.backgroundRect.maxY <= size.height)
                #expect(layout.textRect.height <= size.height * 0.7)
                #expect(layout.font.pointSize.isFinite && layout.font.pointSize > 0)
            }
        }
        let normalized = PhotoTextOverlayRenderer.sanitized(PhotoTextOverlay(text: "a\r\nb\rc\t\0d"))
        #expect(normalized.text == "a\nb\nc d")
    }

    @Test
    func invalidCanvasAndUnreadableImageFailWithoutOutput() {
        #expect(PhotoTextOverlayRenderer.layout(for: PhotoTextOverlay(text: "Hello"), in: .zero) == nil)
        #expect(PhotoTextOverlayRenderer.layout(for: PhotoTextOverlay(text: "Hello"),
            in: CGSize(width: CGFloat.nan, height: 100)) == nil)
        #expect(throws: PhotoTextOverlayRenderer.RenderError.self) {
            try PhotoTextOverlayRenderer.render(image: UIImage(), overlay: PhotoTextOverlay(text: "Hello"))
        }
    }

    @Test
    func scaledNativeEditorKeepsItsFullGlyphViewportWhileTextGrows() throws {
        let image = try stripedImage(width: 400, height: 300)
        let canvas = PhotoTextCanvasView(image: image)
        let phrases = ["A quiet morning", "夕阳很好 🌅\nSee you here", "A quiet morning changed"]
        for size in [CGSize(width: 402, height: 320), CGSize(width: 190, height: 160)] {
            canvas.frame = CGRect(origin: .zero, size: size)
            for phrase in phrases {
                for count in 1...phrase.count {
                    canvas.update(draft: PhotoTextOverlay(text: String(phrase.prefix(count))), isTyping: true)
                    canvas.layoutIfNeeded()
                    let input = try #require(nativeTextView(in: canvas))
                    let manager = input.layoutManager
                    manager.ensureLayout(for: input.textContainer)
                    let used = manager.usedRect(for: input.textContainer)
                    let tail = manager.boundingRect(forGlyphRange:
                        NSRange(location: max(0, manager.numberOfGlyphs - 1), length: 1),
                        in: input.textContainer)
                    #expect(input.transform == .identity,
                            "Scale the wrapper, not UITextView's native rendering viewport")
                    #expect(input.contentSize.width + 0.01 >= used.maxX,
                            "Every laid-out glyph must fit the native content viewport")
                    #expect(input.bounds.width + 0.01 >= tail.maxX)
                    #expect(input.contentSize.height + 0.01 >= used.maxY)
                }
            }
        }
    }

    private func nativeTextView(in view: UIView) -> UITextView? {
        if let input = view as? UITextView { return input }
        for child in view.subviews {
            if let input = nativeTextView(in: child) { return input }
        }
        return nil
    }

    private func stripedImage(width: Int, height: Int) throws -> UIImage {
        let canvas = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        canvas.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        canvas.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return UIImage(cgImage: try #require(canvas.makeImage()))
    }
}

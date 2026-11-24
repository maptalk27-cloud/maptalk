#if DEBUG
import SwiftUI
import UIKit

/// Local sample words authored on the media, independent of the visit comment.
/// Only a transparent overlay is drawn; the underlying photo/video is untouched.
struct POIPreviewMediaText: View {
    let media: RatedPOI.Media

    private var sampleText: String {
        let phrases: [String]
        switch media.kind {
        case .photo:
            phrases = ["今天只想慢一点 ☕️", "把这一束光留住。", "今天值得被记住 ☀️"]
        case .video:
            phrases = ["把这一刻留久一点", "把风和声音也留下。", "再看一遍，还是喜欢。"]
        }
        let index = media.id.uuidString.utf8.reduce(0) { $0 + Int($1) } % phrases.count
        return phrases[index]
    }

    var body: some View {
        POIPreviewMediaTextCanvas(text: sampleText)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("媒体内文字：\(sampleText)")
            .accessibilityIdentifier("poi.preview.media.authored-text.\(media.id.uuidString)")
    }
}

private struct POIPreviewMediaTextCanvas: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> POIPreviewMediaTextImageView {
        POIPreviewMediaTextImageView()
    }

    func updateUIView(_ view: POIPreviewMediaTextImageView, context: Context) {
        view.sampleText = text
    }
}

private final class POIPreviewMediaTextImageView: UIImageView {
    var sampleText = "" {
        didSet {
            if oldValue != sampleText { setNeedsLayout() }
        }
    }

    private var renderedSize = CGSize.zero
    private var renderedText = ""

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .scaleToFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        let size = CGSize(width: (bounds.width * scale).rounded(.up),
                          height: (bounds.height * scale).rounded(.up))
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 8_192, size.height <= 8_192,
              size.width * size.height <= 16_000_000 else { return }
        guard size != renderedSize || sampleText != renderedText else { return }
        renderedSize = size
        renderedText = sampleText

        // Match the real photo/video text renderer without decoding, exporting,
        // writing, or changing either media asset. Cache across ordinary redraws.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let clearImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
        image = try? PhotoTextOverlayRenderer.render(
            image: clearImage,
            overlay: PhotoTextOverlay(text: sampleText, center: CGPoint(x: 0.5, y: 0.45))
        )
    }
}
#endif

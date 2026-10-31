import SwiftUI
import UIKit

/// A non-destructive edit. The composer retains the original photo and only
/// burns these words into a new image when the edit is confirmed.
nonisolated struct PhotoTextOverlay: Equatable, Sendable {
    var text = ""
    var center = CGPoint(x: 0.5, y: 0.5)

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

nonisolated enum PhotoTextOverlayRenderer {
    static let maximumCharacters = 200
    private static let maximumUTF16Units = 2_048

    enum RenderError: LocalizedError {
        case invalidImage

        var errorDescription: String? { "This photo couldn't be edited. Please choose another photo." }
    }

    /// A Character boundary preserves composed accents and family emoji. The
    /// second limit also bounds pathological, very long combining sequences.
    static func sanitized(_ draft: PhotoTextOverlay) -> PhotoTextOverlay {
        let cleaned = draft.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        var text = ""
        var units = 0
        for character in cleaned.prefix(maximumCharacters) {
            let count = String(character).utf16.count
            guard units + count <= maximumUTF16Units else { break }
            // Preserve meaningful Unicode (including ZWJ and RTL), but never
            // pass NUL and other ASCII control codes to text layout.
            let filtered = String(String.UnicodeScalarView(character.unicodeScalars.filter {
                $0.value == 10 || $0.value >= 32 && $0.value != 127
            }))
            text += filtered
            units += count
        }
        return PhotoTextOverlay(text: text, center: CGPoint(
            x: draft.center.x.isFinite ? min(1, max(0, draft.center.x)) : 0.5,
            y: draft.center.y.isFinite ? min(1, max(0, draft.center.y)) : 0.5))
    }

    static func orientedPixelSize(of image: UIImage) -> CGSize {
        guard let pixels = image.cgImage else {
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: pixels.height, height: pixels.width)
        default:
            return CGSize(width: pixels.width, height: pixels.height)
        }
    }

    /// Local-only UIKit/TextKit objects are created per call, so export may run
    /// away from the main actor. No view, mutable shared context or source file
    /// is touched. The source is already bounded by PublishPhotoNormalizer.
    static func render(image: UIImage, overlay: PhotoTextOverlay) throws -> UIImage {
        try Task.checkCancellation()
        let size = orientedPixelSize(of: image)
        guard valid(size), size.width * size.height <= 64_000_000 else {
            throw RenderError.invalidImage
        }
        let draft = sanitized(overlay)
        // Clearing an edit is an exact no-op, not another JPEG generation.
        guard !draft.isEmpty else { return image }
        guard let layout = layout(for: draft, in: size) else { throw RenderError.invalidImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            draw(layout, in: context.cgContext)
        }
        guard rendered.cgImage != nil else { throw RenderError.invalidImage }
        try Task.checkCancellation()
        return rendered
    }

    /// Lay out at one fixed logical resolution, then scale those exact glyphs
    /// to the requested pixel size. Repeating TextKit layout with a larger font
    /// can change line breaks (especially for fallback CJK/emoji fonts), even
    /// when every input dimension is multiplied by the same factor.
    static func layout(for overlay: PhotoTextOverlay, in size: CGSize) -> Layout? {
        guard valid(size) else { return nil }
        let draft = sanitized(overlay)
        guard !draft.isEmpty else { return nil }
        let unit: CGFloat = 360
        let sourceUnit = min(size.width, size.height)
        let textScale = sourceUnit / unit
        let logicalSize = CGSize(width: size.width / sourceUnit * unit,
                                 height: size.height / sourceUnit * unit)
        let margin = unit * 0.035
        let padding = unit * 0.022
        let maximumWidth = max(unit * 0.01, logicalSize.width * 0.88 - padding * 2)
        let maximumHeight = max(unit * 0.01, logicalSize.height * 0.7 - padding * 2)
        let preferredFontSize = unit * 0.067
        var low = preferredFontSize / 512
        var high = preferredFontSize
        var fitted = TextLayout(text: draft.text, width: maximumWidth, fontSize: low)
        // Shrinking instead of clipping keeps long multiline captions and
        // unbroken CJK/emoji sequences inside the photo at every position.
        for _ in 0..<16 {
            let fontSize = (low + high) / 2
            let candidate = TextLayout(text: draft.text, width: maximumWidth, fontSize: fontSize)
            if candidate.size.height <= maximumHeight && candidate.size.width <= maximumWidth + 0.01 {
                fitted = candidate
                low = fontSize
            } else {
                high = fontSize
            }
        }
        let boxSize = CGSize(width: fitted.size.width + padding * 2, height: fitted.size.height + padding * 2)
        let x = min(logicalSize.width - margin - boxSize.width / 2,
                    max(margin + boxSize.width / 2, draft.center.x * logicalSize.width))
        let y = min(logicalSize.height - margin - boxSize.height / 2,
                    max(margin + boxSize.height / 2, draft.center.y * logicalSize.height))
        let box = CGRect(x: x - boxSize.width / 2, y: y - boxSize.height / 2,
                         width: boxSize.width, height: boxSize.height)
        let transform = CGAffineTransform(scaleX: textScale, y: textScale)
        return Layout(text: draft.text, center: CGPoint(x: x / logicalSize.width, y: y / logicalSize.height),
                      backgroundRect: box.applying(transform),
                      textRect: box.insetBy(dx: padding, dy: padding).applying(transform),
                      cornerRadius: unit * 0.023 * textScale, textScale: textScale, textLayout: fitted)
    }

    static func clamped(_ overlay: PhotoTextOverlay, in size: CGSize) -> PhotoTextOverlay {
        var draft = sanitized(overlay)
        if let layout = layout(for: draft, in: size) { draft.center = layout.center }
        return draft
    }

    fileprivate static func draw(_ layout: Layout, in context: CGContext, drawText: Bool = true,
                                 textAlpha: CGFloat = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        UIColor.black.withAlphaComponent(0.42).setFill()
        UIBezierPath(roundedRect: layout.backgroundRect, cornerRadius: layout.cornerRadius).fill()
        guard drawText else { return }
        context.clip(to: layout.textRect)
        context.setAlpha(textAlpha)
        context.translateBy(x: layout.textRect.minX, y: layout.textRect.minY)
        context.scaleBy(x: layout.textScale, y: layout.textScale)
        let range = NSRange(location: 0, length: layout.textLayout.manager.numberOfGlyphs)
        layout.textLayout.manager.drawBackground(forGlyphRange: range, at: .zero)
        layout.textLayout.manager.drawGlyphs(forGlyphRange: range, at: .zero)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
            && size.width <= 32_768 && size.height <= 32_768
    }

    struct Layout {
        let text: String
        let center: CGPoint
        let backgroundRect: CGRect
        let textRect: CGRect
        let cornerRadius: CGFloat
        let textScale: CGFloat
        fileprivate let textLayout: TextLayout

        var font: UIFont { textLayout.font }
        var textCanvasSize: CGSize { textLayout.size }
    }

    fileprivate final class TextLayout {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let font: UIFont
        let size: CGSize

        init(text: String, width: CGFloat, fontSize: CGFloat) {
            font = .systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            storage = NSTextStorage(string: text, attributes: [
                .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ])
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            // Measure once at the allowed width, then center every line within
            // the compact backing instead of filling almost the whole photo.
            // Round up in logical space so a tiny floating-point change in
            // glyph metrics cannot push the final word onto another line.
            let measuredWidth = min(width, max(fontSize,
                (manager.usedRect(for: container).width * 64).rounded(.up) / 64))
            container.size.width = measuredWidth
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            size = CGSize(width: measuredWidth, height: max(font.lineHeight, used.maxY))
        }
    }
}

struct MapTalkPhotoTextEditor: View {
    let image: UIImage
    let embedded: Bool
    let onCancel: @MainActor () -> Void
    let onDone: @MainActor (PhotoTextOverlay) -> Void
    @State private var draft: PhotoTextOverlay
    @State private var isTyping = true

    init(image: UIImage, draft: PhotoTextOverlay, embedded: Bool = false, onCancel: @escaping @MainActor () -> Void,
         onDone: @escaping @MainActor (PhotoTextOverlay) -> Void) {
        self.image = image
        self.embedded = embedded
        self.onCancel = onCancel
        self.onDone = onDone
        _draft = State(initialValue: PhotoTextOverlayRenderer.sanitized(draft))
    }

    var body: some View {
        if embedded {
            embeddedEditor
        } else {
            standaloneEditor
        }
    }

    private var canvas: some View {
        MapTalkPhotoTextCanvas(image: image, draft: $draft, isTyping: $isTyping)
    }

    private func editingFooter(color: Color) -> some View {
        MapTalkPhotoTextTools(isTyping: isTyping,
            foregroundColor: color, minimumHeight: embedded ? 44 : 0)
    }

    private func finishEditing() {
        isTyping = false
        onDone(PhotoTextOverlayRenderer.clamped(draft,
            in: PhotoTextOverlayRenderer.orientedPixelSize(of: image)))
    }

    private var embeddedEditor: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Photo text")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 15))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("maptalk.photo-text.cancel")
                    Spacer()
                    Button("Done", action: finishEditing)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("maptalk.photo-text.done")
                }
            }
            .frame(height: 46)
            .padding(.horizontal, 16)
            .padding(.top, 6)

            canvas
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 326)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .layoutPriority(1)

            editingFooter(color: .black)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .tint(.black)
        .preferredColorScheme(.light)
    }

    private var standaloneEditor: some View {
        NavigationStack {
            VStack(spacing: 14) {
                canvas
                editingFooter(color: .white)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .background(Color.black)
            .navigationTitle("Photo text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("maptalk.photo-text.cancel")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: finishEditing)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("maptalk.photo-text.done")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}

/// The composer owns the draft and commits it only on Done. This canvas edits
/// that value without rendering into, replacing, or saving the original image.
struct MapTalkPhotoTextCanvas: View {
    let image: UIImage
    @Binding var draft: PhotoTextOverlay
    @Binding var isTyping: Bool

    var body: some View {
        PhotoTextEditingCanvas(image: image, draft: $draft, isTyping: $isTyping)
            .accessibilityIdentifier("maptalk.photo-text.canvas")
    }
}

struct MapTalkPhotoTextTools: View {
    let isTyping: Bool
    var foregroundColor: Color = .primary
    var minimumHeight: CGFloat = 44
    var onDone: (() -> Void)? = nil

    var body: some View {
        HStack {
            if !isTyping {
                Text("Drag to move · tap to edit")
                    .font(.system(size: 12))
                    .foregroundStyle(foregroundColor.opacity(0.6))
            }
            Spacer()
            if let onDone {
                Button("Done", action: onDone)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: max(44, minimumHeight))
                    .background(.black, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("maptalk.photo-text.done")
            }
        }
        .frame(minHeight: minimumHeight)
    }
}

private struct PhotoTextEditingCanvas: UIViewRepresentable {
    let image: UIImage
    @Binding var draft: PhotoTextOverlay
    @Binding var isTyping: Bool

    func makeUIView(context: Context) -> PhotoTextCanvasView {
        let view = PhotoTextCanvasView(image: image)
        view.onChange = { draft = $0 }
        view.onTypingChange = { isTyping = $0 }
        view.update(draft: draft, isTyping: isTyping)
        return view
    }

    func updateUIView(_ view: PhotoTextCanvasView, context: Context) {
        view.onChange = { draft = $0 }
        view.onTypingChange = { isTyping = $0 }
        view.update(draft: draft, isTyping: isTyping)
    }
}

final class PhotoTextCanvasView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var onChange: ((PhotoTextOverlay) -> Void)?
    var onTypingChange: ((Bool) -> Void)?
    private let imageView: UIImageView
    private let drawingView = PhotoTextDrawingView()
    private let textViewport = UIView()
    private let textView: UITextView
    private let imageSize: CGSize
    private var draft = PhotoTextOverlay()
    private var wantsTyping = true
    private var imageFrame = CGRect.zero
    private var activeLayout: PhotoTextOverlayRenderer.Layout?
    private var dragStart = CGPoint.zero
    private var focusScheduled = false
    private let textDragRecognizer = UIPanGestureRecognizer()

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        imageSize = PhotoTextOverlayRenderer.orientedPixelSize(of: image)
        // Opt into TextKit 1 explicitly, matching the export layout engine.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        textView = UITextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        drawingView.isUserInteractionEnabled = false
        addSubview(drawingView)
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = .white
        textView.textAlignment = .center
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        // This canvas owns the canonical text width. UIKit must not overwrite
        // it during the intermediate bounds/transform updates below.
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.heightTracksTextView = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.isScrollEnabled = false
        textView.autocapitalizationType = .sentences
        textView.keyboardAppearance = .dark
        textView.accessibilityLabel = "Text on media"
        textView.accessibilityIdentifier = "maptalk.photo-text.input"
        addSubview(textViewport)
        textViewport.addSubview(textView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        textDragRecognizer.addTarget(self, action: #selector(dragged(_:)))
        textDragRecognizer.delegate = self
        addGestureRecognizer(textDragRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(draft: PhotoTextOverlay, isTyping: Bool) {
        self.draft = draft
        wantsTyping = isTyping
        if textView.text != draft.text && textView.markedTextRange == nil { textView.text = draft.text }
        if !isTyping && textView.isFirstResponder { textView.resignFirstResponder() }
        setNeedsLayout()
        scheduleFocusIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleFocusIfNeeded()
    }

    private func scheduleFocusIfNeeded() {
        guard wantsTyping, window != nil, !textView.isFirstResponder, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.wantsTyping, self.window != nil else { return }
            self.textView.becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageFrame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        imageView.frame = imageFrame
        drawingView.frame = imageFrame
        var displayed = draft
        if displayed.isEmpty { displayed.text = "Add text" }
        guard let layout = PhotoTextOverlayRenderer.layout(for: displayed, in: imageSize) else { return }
        activeLayout = layout
        drawingView.layout = layout
        drawingView.imageSize = imageSize
        drawingView.drawText = !textView.isFirstResponder || draft.isEmpty
        drawingView.textAlpha = draft.isEmpty ? 0.55 : 1
        drawingView.setNeedsDisplay()
        textViewport.isHidden = !wantsTyping
        textViewport.bounds = CGRect(origin: .zero, size: layout.textCanvasSize)
        // UITextView derives its native content viewport from its own frame.
        // Scaling it directly produced a 144.73pt viewport for 172.81pt of
        // correctly laid-out glyphs, clipping the tail while the caret moved
        // normally. Scale only this plain wrapper; native text stays 1:1.
        textView.frame = textViewport.bounds
        textView.font = layout.font
        textView.textContainer.size = CGSize(width: layout.textCanvasSize.width,
                                             height: .greatestFiniteMagnitude)
        let textScale = scale * layout.textScale
        textViewport.transform = CGAffineTransform(scaleX: textScale, y: textScale)
        textViewport.center = CGPoint(x: imageFrame.minX + layout.textRect.midX * scale,
                                      y: imageFrame.minY + layout.textRect.midY * scale)
        textView.layoutIfNeeded()
    }

    func textViewDidChange(_ textView: UITextView) {
        draft.text = textView.text
        // Do not truncate a partially composed Chinese/Japanese input session.
        if textView.markedTextRange == nil {
            draft = PhotoTextOverlayRenderer.sanitized(draft)
            if textView.text != draft.text { textView.text = draft.text }
        }
        onChange?(draft)
        setNeedsLayout()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        wantsTyping = true
        onTypingChange?(true)
        setNeedsLayout()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        wantsTyping = false
        draft = PhotoTextOverlayRenderer.sanitized(PhotoTextOverlay(text: textView.text, center: draft.center))
        onChange?(draft)
        onTypingChange?(false)
        setNeedsLayout()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            return !textView.isFirstResponder && textHitRect.contains(gestureRecognizer.location(in: self))
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Native caret/selection interactions own taps inside the input field.
        !(textView.isFirstResponder && touch.view?.isDescendant(of: textView) == true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only a drag beginning on the text can win. Everywhere else our
        // shouldBegin returns false, so the surrounding form scrolls normally.
        guard gestureRecognizer === textDragRecognizer,
              let scroll = otherGestureRecognizer.view as? UIScrollView,
              otherGestureRecognizer === scroll.panGestureRecognizer else { return false }
        return isDescendant(of: scroll)
    }

    private var textHitRect: CGRect {
        guard let layout = activeLayout, imageSize.width > 0 else { return .zero }
        let scale = imageFrame.width / imageSize.width
        return CGRect(x: imageFrame.minX + layout.backgroundRect.minX * scale,
                      y: imageFrame.minY + layout.backgroundRect.minY * scale,
                      width: layout.backgroundRect.width * scale, height: layout.backgroundRect.height * scale)
            .insetBy(dx: -12, dy: -12)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if textView.isFirstResponder { textView.resignFirstResponder() }
        else if textHitRect.contains(recognizer.location(in: self)) {
            wantsTyping = true
            onTypingChange?(true)
            textViewport.isHidden = false
            textView.becomeFirstResponder()
        }
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        if recognizer.state == .began { dragStart = activeLayout?.center ?? draft.center }
        let delta = recognizer.translation(in: self)
        draft.center = CGPoint(x: dragStart.x + delta.x / imageFrame.width,
                               y: dragStart.y + delta.y / imageFrame.height)
        var displayed = draft
        if displayed.isEmpty { displayed.text = "Add text" }
        draft.center = PhotoTextOverlayRenderer.clamped(displayed, in: imageSize).center
        onChange?(draft)
        setNeedsLayout()
    }
}

private final class PhotoTextDrawingView: UIView {
    var layout: PhotoTextOverlayRenderer.Layout?
    var imageSize = CGSize.zero
    var drawText = true
    var textAlpha: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let layout, imageSize.width > 0, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / imageSize.width, y: bounds.height / imageSize.height)
        PhotoTextOverlayRenderer.draw(layout, in: context, drawText: drawText, textAlpha: textAlpha)
        context.restoreGState()
    }
}

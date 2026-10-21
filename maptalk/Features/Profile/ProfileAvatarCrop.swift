import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The full, upright image is kept until the person chooses their framing.
/// Pixels are bounded on import; the original library asset is never changed.
nonisolated struct ProfileAvatarCropSource: Identifiable, Sendable {
    let id = UUID()
    let preview: LocalMapDecodedImage

    var size: CGSize { CGSize(width: preview.image.width, height: preview.image.height) }
}

nonisolated struct ProfileAvatarPhoto: Sendable {
    let jpegData: Data
    let preview: LocalMapDecodedImage
}

/// Choosing or cancelling a crop must not replace a previously confirmed
/// draft. Neither operation uploads anything; Edit Profile's Save owns that.
nonisolated struct ProfileAvatarDraft {
    private(set) var photo: ProfileAvatarPhoto?
    var source: ProfileAvatarCropSource?

    mutating func begin(_ source: ProfileAvatarCropSource) { self.source = source }
    mutating func cancelCrop() { source = nil }
    mutating func confirm(_ photo: ProfileAvatarPhoto) {
        self.photo = photo
        source = nil
    }
}

nonisolated enum ProfileAvatarCropGeometry {
    static func centeredSquare(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                      width: side, height: side)
    }

    /// UIScrollView can briefly overscroll while a gesture decelerates. Clamp
    /// the requested square so the exported pixels never contain blank edges.
    static func clampedSquare(_ rect: CGRect, in size: CGSize) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        let side = min(rect.width, rect.height, size.width, size.height).rounded(.down)
        let x = min(max(0, rect.midX - side / 2), size.width - side).rounded(.down)
        let y = min(max(0, rect.midY - side / 2), size.height - side).rounded(.down)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    static func visibleSquare(offset: CGPoint, zoomScale: CGFloat,
                              viewportSide: CGFloat, imageSize: CGSize) -> CGRect? {
        guard zoomScale.isFinite, zoomScale > 0, viewportSide.isFinite, viewportSide > 0 else {
            return nil
        }
        return clampedSquare(CGRect(x: offset.x / zoomScale, y: offset.y / zoomScale,
            width: viewportSide / zoomScale, height: viewportSide / zoomScale), in: imageSize)
    }
}

actor ProfileAvatarProcessor {
    static let shared = ProfileAvatarProcessor()

    func prepareSource(at url: URL) throws -> ProfileAvatarCropSource {
        // Reuse the bounded orientation/metadata pipeline, but deliberately do
        // not crop at import time. The person still has the whole photo to frame.
        let photo = try PublishPhotoNormalizer.prepare(at: url)
        return ProfileAvatarCropSource(preview: photo.preview)
    }

    func crop(_ source: ProfileAvatarCropSource, rect: CGRect) throws -> ProfileAvatarPhoto {
        try Task.checkCancellation()
        guard let rect = ProfileAvatarCropGeometry.clampedSquare(rect, in: source.size),
              let pixels = source.preview.image.cropping(to: rect) else {
            throw PublishPhotoNormalizer.ImportError.unreadable
        }
        let side = min(1_024, pixels.width, pixels.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PublishPhotoNormalizer.ImportError.unreadable
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .high
        canvas.draw(pixels, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let preview = canvas.makeImage() else { throw PublishPhotoNormalizer.ImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
            UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PublishPhotoNormalizer.ImportError.unreadable
        }
        CGImageDestinationAddImage(destination, preview,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PublishPhotoNormalizer.ImportError.unreadable }
        try Task.checkCancellation()
        return ProfileAvatarPhoto(jpegData: output as Data, preview: LocalMapDecodedImage(preview))
    }
}

struct ProfileAvatarCropView: View {
    let source: ProfileAvatarCropSource
    let onCancel: @MainActor () -> Void
    let onConfirm: @MainActor (ProfileAvatarPhoto) -> Void
    @State private var cropRect: CGRect?
    @State private var isPreparing = false
    @State private var issue: String?
    @State private var prepareTask: Task<Void, Never>?

    var body: some View {
        // The crop is presented over an existing profile sheet. Give this
        // fullscreen destination its own navigation container so UIKit owns
        // the status-bar/notch safe area; a freestanding header can otherwise
        // inherit the sheet's zero top inset during the Photos handoff.
        NavigationStack {
            GeometryReader { geometry in
                let side = max(1, min(geometry.size.width - 40, geometry.size.height - 80))
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    ProfileAvatarCropCanvas(source: source) { cropRect = $0 }
                        .frame(width: side, height: side)
                        .overlay {
                            AvatarCircleMask().fill(.black.opacity(0.62), style: FillStyle(eoFill: true))
                                .allowsHitTesting(false)
                        }
                        .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1).allowsHitTesting(false) }
                        .accessibilityIdentifier("profile.crop.canvas")
                    Text("Move and scale")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.white)
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .font(.subheadline)
                        .accessibilityIdentifier("profile.crop.cancel")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: confirmCrop) {
                        if isPreparing { ProgressView().tint(.black) }
                        else { Text("Use").font(.subheadline.weight(.semibold)) }
                    }
                    .disabled(cropRect == nil || isPreparing)
                    .accessibilityIdentifier("profile.crop.use")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .background(Color.white)
        .tint(.black)
        .foregroundStyle(.black)
        .disabled(isPreparing)
        .interactiveDismissDisabled(isPreparing)
        .onDisappear { prepareTask?.cancel() }
    }

    private func confirmCrop() {
        guard let cropRect, !isPreparing else { return }
        isPreparing = true
        issue = nil
        prepareTask = Task { @MainActor in
            defer { isPreparing = false }
            do {
                let photo = try await ProfileAvatarProcessor.shared.crop(source, rect: cropRect)
                try Task.checkCancellation()
                onConfirm(photo)
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
}

private struct AvatarCircleMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: rect)
        return path
    }
}

private struct ProfileAvatarCropCanvas: UIViewRepresentable {
    let source: ProfileAvatarCropSource
    let onChange: @MainActor (CGRect) -> Void

    func makeUIView(context: Context) -> AvatarCropScrollView {
        let view = AvatarCropScrollView(image: source.preview.image)
        view.onCropChange = onChange
        return view
    }

    func updateUIView(_ view: AvatarCropScrollView, context: Context) {
        view.onCropChange = onChange
    }
}

/// Native pan/pinch physics, with no competing SwiftUI drag recognizers. The
/// square viewport always remains covered; the circle is only a preview mask.
private final class AvatarCropScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView
    var onCropChange: (@MainActor (CGRect) -> Void)?
    private var lastViewport: CGSize = .zero
    private var isLayingOutCrop = false

    init(image: CGImage) {
        imageView = UIImageView(image: UIImage(cgImage: image))
        super.init(frame: .zero)
        imageView.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        addSubview(imageView)
        delegate = self
        clipsToBounds = true
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        bouncesZoom = false
        accessibilityLabel = "Move and pinch the photo to choose your avatar"
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != lastViewport, !isLayingOutCrop else { return }
        isLayingOutCrop = true
        let size = imageView.bounds.size
        let previous = lastViewport == .zero ? nil : ProfileAvatarCropGeometry.visibleSquare(
            offset: contentOffset, zoomScale: zoomScale, viewportSide: lastViewport.width, imageSize: size)
        let target = previous ?? ProfileAvatarCropGeometry.centeredSquare(in: size)
        lastViewport = bounds.size
        minimumZoomScale = bounds.width / min(size.width, size.height)
        maximumZoomScale = minimumZoomScale * 6
        zoomScale = min(maximumZoomScale, max(minimumZoomScale, bounds.width / target.width))
        contentSize = CGSize(width: size.width * zoomScale, height: size.height * zoomScale)
        contentOffset = CGPoint(
            x: min(max(0, target.midX * zoomScale - bounds.width / 2), max(0, contentSize.width - bounds.width)),
            y: min(max(0, target.midY * zoomScale - bounds.height / 2), max(0, contentSize.height - bounds.height)))
        isLayingOutCrop = false
        // Layout callbacks must not synchronously mutate SwiftUI view state.
        DispatchQueue.main.async { [weak self] in self?.reportCrop() }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportCrop() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { reportCrop() }

    private func reportCrop() {
        guard !isLayingOutCrop, let rect = ProfileAvatarCropGeometry.visibleSquare(
            offset: contentOffset, zoomScale: zoomScale, viewportSide: bounds.width,
            imageSize: imageView.bounds.size) else { return }
        onCropChange?(rect)
    }
}

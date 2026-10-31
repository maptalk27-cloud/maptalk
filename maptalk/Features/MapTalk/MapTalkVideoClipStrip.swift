import AVFoundation
import Combine
import SwiftUI

/// A fixed-length window into the source video. All public times are absolute
/// asset times; only the labels displayed to the user are relative to its start.
nonisolated struct VideoClipSelection: Equatable, Sendable {
    let sourceStart: Double
    let sourceDuration: Double
    let duration: Double

    init?(sourceRange: CMTimeRange, maximumDuration: Double = 60) {
        let start = sourceRange.start.seconds
        let length = sourceRange.duration.seconds
        guard sourceRange.isValid, start.isFinite, start >= 0,
              length.isFinite, length > 0, (start + length).isFinite,
              maximumDuration.isFinite, maximumDuration > 0 else { return nil }
        sourceStart = start
        sourceDuration = length
        duration = min(length, maximumDuration)
    }

    var latestStart: Double { sourceStart + max(0, sourceDuration - duration) }
    var canMove: Bool { latestStart > sourceStart }

    func clampedStart(_ value: Double) -> Double {
        guard !value.isNaN else { return sourceStart }
        return min(latestStart, max(sourceStart, value))
    }

    func start(afterTranslation translation: Double, from initial: Double, width: Double) -> Double {
        guard width.isFinite, width > 0, translation.isFinite else { return clampedStart(initial) }
        return clampedStart(clampedStart(initial) + translation / width * sourceDuration)
    }

    /// A tap addresses the available starting positions, not the middle frame.
    /// This keeps a 60-second window in a 65-second video easy to position.
    func start(at position: Double, width: Double) -> Double {
        guard width.isFinite, width > 0, position.isFinite else { return sourceStart }
        let fraction = min(1, max(0, position / width))
        return sourceStart + fraction * (latestStart - sourceStart)
    }

    func window(at start: Double) -> ClosedRange<Double> {
        let lower = (clampedStart(start) - sourceStart) / sourceDuration
        return lower...min(1, lower + duration / sourceDuration)
    }

    func thumbnailTimes(count: Int = 10) -> [Double] {
        let boundedCount = min(12, max(1, count))
        // Sample the middle of each cell, never the asset's exclusive end.
        return (0..<boundedCount).map {
            sourceStart + (Double($0) + 0.5) / Double(boundedCount) * sourceDuration
        }
    }

    func summary(at start: Double) -> String {
        let relativeStart = clampedStart(start) - sourceStart
        return "\(Self.timestamp(relativeStart)) – \(Self.timestamp(relativeStart + duration))"
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        // Avoid integer overflow for malformed metadata. Real source videos are
        // bounded separately by the importer; this is presentation only.
        let total = Int(min(31_536_000, max(0, seconds)).rounded(.down))
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
protocol VideoClipFrameSource: AnyObject {
    func image(at seconds: Double) async throws -> CGImage
    func cancel()
}

@MainActor
private final class AssetVideoClipFrameSource: VideoClipFrameSource {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    func image(at seconds: Double) async throws -> CGImage {
        defer { withExtendedLifetime(asset) {} }
        try Task.checkCancellation()
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return result.image
    }

    func cancel() { generator.cancelAllCGImageGeneration() }
}

/// One small, sequential decode at a time. Changing the selected start does not
/// reload the strip. A cancelled/replaced request can never overwrite a new one.
@MainActor
final class VideoClipThumbnailLoader: ObservableObject {
    nonisolated struct Request: Hashable, Sendable {
        let url: URL
        let sourceStart: Double
        let sourceDuration: Double
        let count: Int

        init(url: URL, selection: VideoClipSelection, count: Int = 10) {
            self.url = url
            sourceStart = selection.sourceStart
            sourceDuration = selection.sourceDuration
            self.count = min(12, max(1, count))
        }

        var times: [Double] {
            (0..<count).map { sourceStart + (Double($0) + 0.5) / Double(count) * sourceDuration }
        }
    }

    @Published private(set) var frames: [CGImage?] = []
    @Published private(set) var isLoading = false
    private var request: Request?
    private var generation = UUID()
    private var source: (any VideoClipFrameSource)?
    private let makeSource: @MainActor (URL) -> any VideoClipFrameSource

    init(makeSource: (@MainActor (URL) -> any VideoClipFrameSource)? = nil) {
        self.makeSource = makeSource ?? { AssetVideoClipFrameSource(url: $0) }
    }

    func load(_ next: Request) async {
        guard !Task.isCancelled else { return }
        if request == next, !frames.isEmpty, frames.allSatisfy({ $0 != nil }) { return }
        cancel()
        let token = UUID()
        generation = token
        if request != next {
            frames = Array(repeating: nil, count: next.count)
        }
        request = next
        let currentSource = makeSource(next.url)
        source = currentSource
        isLoading = true
        defer {
            if generation == token {
                source = nil
                isLoading = false
            }
        }

        await withTaskCancellationHandler {
            for (index, seconds) in next.times.enumerated() {
                guard generation == token, !Task.isCancelled else { return }
                guard frames[index] == nil else { continue }
                do {
                    let image = try await currentSource.image(at: seconds)
                    guard generation == token, !Task.isCancelled else { return }
                    frames[index] = image
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    // A missing frame keeps its quiet placeholder; it must not
                    // turn an otherwise playable video into an import failure.
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        generation = UUID()
        source?.cancel()
        source = nil
        isLoading = false
        // Keep decoded frames across disappearance/reappearance of the same
        // clip. They are bounded to twelve 160px images, with no disk cache.
    }

    func frame(at index: Int, for expectedRequest: Request?) -> CGImage? {
        guard expectedRequest == request, frames.indices.contains(index) else { return nil }
        return frames[index]
    }
}

struct MapTalkVideoClipStrip: View {
    let url: URL
    let sourceRange: CMTimeRange
    @Binding var selectionStart: Double
    var maximumDuration: Double = 60
    var onScrub: (Double, Bool) -> Void = { _, _ in }

    @StateObject private var thumbnails = VideoClipThumbnailLoader()
    @State private var dragStart: Double?
    @GestureState private var isScrubbing = false

    private var selection: VideoClipSelection? {
        VideoClipSelection(sourceRange: sourceRange, maximumDuration: maximumDuration)
    }

    private var request: VideoClipThumbnailLoader.Request? {
        selection.map { .init(url: url, selection: $0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let selection {
                GeometryReader { geometry in
                    let width = max(1, Double(geometry.size.width))
                    let window = selection.window(at: selectionStart)
                    let leading = width * window.lowerBound
                    let selectedWidth = width * (window.upperBound - window.lowerBound)

                    ZStack(alignment: .leading) {
                        filmstrip(width: width)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 0) {
                            Color.black.opacity(0.48).frame(width: leading)
                            Color.clear.frame(width: selectedWidth)
                            Color.black.opacity(0.48)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                            .frame(width: max(3, selectedWidth))
                            .offset(x: leading)
                            .allowsHitTesting(false)
                    }
                    .frame(height: 56)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(selection: selection, width: width))
                    .accessibilityRepresentation {
                        Slider(value: Binding(
                            get: { selection.clampedStart(selectionStart) },
                            set: { update($0, selection: selection, dragging: false) }
                        ), in: selection.sourceStart...max(selection.sourceStart + 0.001, selection.latestStart))
                        .disabled(!selection.canMove)
                        .accessibilityLabel("Clip start")
                        .accessibilityValue(selection.summary(at: selectionStart))
                        .accessibilityHint("Swipe up or down to move the selected clip.")
                        .accessibilityAdjustableAction { direction in
                            let step = min(1, (selection.latestStart - selection.sourceStart) / 10)
                            switch direction {
                            case .increment: update(selectionStart + step, selection: selection, dragging: false)
                            case .decrement: update(selectionStart - step, selection: selection, dragging: false)
                            @unknown default: break
                            }
                        }
                        .accessibilityIdentifier("maptalk.place.clip.start")
                    }
                }
                .frame(height: 64)

                HStack {
                    Text(selection.summary(at: selectionStart))
                        .fontWeight(.medium)
                        .accessibilityIdentifier("maptalk.place.clip.summary")
                    Spacer()
                    Text("\(VideoClipSelection.timestamp(selection.sourceDuration)) total")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12).monospacedDigit())
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 56)
                    .accessibilityLabel("Video preview unavailable")
            }
        }
        .foregroundStyle(.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.place.clip.timeline")
        .task(id: request) {
            dragStart = nil
            guard let request else { thumbnails.cancel(); return }
            await thumbnails.load(request)
        }
        .onDisappear { thumbnails.cancel() }
        .onChange(of: isScrubbing) { _, active in
            // A system interruption can cancel the gesture without onEnded.
            // The next touch must start at the current selected range.
            if !active { dragStart = nil }
        }
    }

    private func filmstrip(width: Double) -> some View {
        let count = request?.count ?? 10
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                ZStack {
                    Color(white: 0.88)
                    if let frame = thumbnails.frame(at: index, for: request) {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: width / Double(count), height: 56)
                .clipped()
            }
        }
        .accessibilityHidden(true)
    }

    private func scrubGesture(selection: VideoClipSelection, width: Double) -> some Gesture {
        let drag = DragGesture(minimumDistance: 4)
            .updating($isScrubbing) { _, active, _ in active = true }
            .onChanged { value in
                guard selection.canMove,
                      dragStart != nil || abs(value.translation.width) > abs(value.translation.height) else { return }
                if dragStart == nil { dragStart = selection.clampedStart(selectionStart) }
                let start = selection.start(afterTranslation: value.translation.width,
                                            from: dragStart ?? selectionStart, width: width)
                update(start, selection: selection, dragging: true)
            }
            .onEnded { value in
                guard let initial = dragStart else { return }
                dragStart = nil
                update(selection.start(afterTranslation: value.translation.width, from: initial, width: width),
                       selection: selection, dragging: false)
            }
        let tap = SpatialTapGesture()
            .onEnded { value in
                guard selection.canMove else { return }
                update(selection.start(at: value.location.x, width: width), selection: selection, dragging: false)
            }
        return drag.exclusively(before: tap)
    }

    private func update(_ start: Double, selection: VideoClipSelection, dragging: Bool) {
        let next = selection.clampedStart(start)
        selectionStart = next
        onScrub(next, dragging)
    }
}

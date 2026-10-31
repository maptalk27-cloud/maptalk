import AVFoundation
import CoreGraphics
import Testing
@testable import maptalk

struct VideoClipSelectionTests {
    @Test
    func nonzeroSourceStartRemainsAbsoluteAndLabelsRemainRelative() throws {
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 12, duration: 90)))
        #expect(selection.sourceStart == 12)
        #expect(selection.duration == 60)
        #expect(selection.latestStart == 42)
        #expect(selection.clampedStart(-100) == 12)
        #expect(selection.clampedStart(.infinity) == 42)
        #expect(selection.clampedStart(.nan) == 12)
        #expect(selection.window(at: 42).upperBound == 1)
        #expect(selection.summary(at: 42) == "0:30 – 1:30")
    }

    @Test
    func shortVideosSelectTheWholeSourceWithoutAnArtificialSliderRange() throws {
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 8, duration: 14)))
        #expect(selection.duration == 14)
        #expect(!selection.canMove)
        #expect(selection.latestStart == 8)
        #expect(selection.window(at: 100) == 0...1)
        #expect(selection.start(at: 160, width: 320) == 8)
        #expect(selection.start(afterTranslation: 100, from: 8, width: 320) == 8)
        #expect(selection.summary(at: -1) == "0:00 – 0:14")
    }

    @Test
    func invalidMetadataNeverProducesNaNGeometryOrUnboundedSelection() {
        #expect(VideoClipSelection(sourceRange: .invalid) == nil)
        #expect(VideoClipSelection(sourceRange: CMTimeRange(start: .zero, duration: .indefinite)) == nil)
        #expect(VideoClipSelection(sourceRange: range(start: -3, duration: 65)) == nil)
        #expect(VideoClipSelection(sourceRange: range(start: 0, duration: 0)) == nil)
        #expect(VideoClipSelection(sourceRange: range(start: 0, duration: -1)) == nil)
        for maximum in [Double.nan, .infinity, 0, -1] {
            #expect(VideoClipSelection(sourceRange: range(start: 0, duration: 65), maximumDuration: maximum) == nil)
        }
    }

    @Test
    func draggingMovesTheWholeWindowByItsVisibleDistanceAndClampsAtBothEnds() throws {
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 0, duration: 65)))
        #expect(selection.start(afterTranslation: 20, from: 0, width: 325) == 4)
        #expect(selection.start(afterTranslation: 100, from: 0, width: 325) == 5)
        #expect(selection.start(afterTranslation: -20, from: 5, width: 325) == 1)
        #expect(selection.start(afterTranslation: -100, from: 5, width: 325) == 0)
        #expect(selection.start(afterTranslation: 20, from: 2, width: 0) == 2)
        #expect(selection.start(afterTranslation: .nan, from: 2, width: 325) == 2)
        #expect(selection.start(afterTranslation: 20, from: 2, width: .infinity) == 2)
    }

    @Test
    func tappingCanSelectTheMiddleOfTheFiveSecondMovableRange() throws {
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 12, duration: 65)))
        #expect(selection.start(at: 162.5, width: 325) == 14.5)
        #expect(selection.start(at: 81.25, width: 325) == 13.25)
        #expect(selection.start(at: -20, width: 325) == 12)
        #expect(selection.start(at: 400, width: 325) == 17)
        #expect(selection.start(at: .nan, width: 325) == 12)
        #expect(selection.start(at: 10, width: 0) == 12)
    }

    @Test
    func thumbnailSamplesAreBoundedAndNeverRequestTheExclusiveSourceEnd() throws {
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 12, duration: 90)))
        let times = selection.thumbnailTimes(count: 100_000)
        #expect(times.count == 12)
        #expect(times.allSatisfy { $0.isFinite && $0 > 12 && $0 < 102 })
        #expect(times == times.sorted())
        #expect(selection.thumbnailTimes(count: 0) == [57])
        let request = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/clip.mov"), selection: selection, count: 100_000)
        #expect(request.times == times)
        #expect(request.count == 12)
    }

    @Test
    func timestampFormattingDoesNotOverflowOrShowAssetOffsets() {
        #expect(VideoClipSelection.timestamp(65) == "1:05")
        #expect(VideoClipSelection.timestamp(3_661) == "1:01:01")
        #expect(VideoClipSelection.timestamp(-1) == "0:00")
        #expect(VideoClipSelection.timestamp(.infinity) == "0:00")
        #expect(!VideoClipSelection.timestamp(Double.greatestFiniteMagnitude).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func loadedFramesAreReusedWithoutBlankingAndFrameCountIsBounded() async throws {
        let frame = try makeFrame(width: 4)
        let source = ImmediateClipFrameSource(frame: frame)
        var creations = 0
        let loader = VideoClipThumbnailLoader { _ in creations += 1; return source }
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 12, duration: 65)))
        let request = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/a.mov"), selection: selection, count: 500)
        await loader.load(request)
        #expect(loader.frames.count == 12)
        #expect(loader.frames.allSatisfy { $0?.width == 4 })
        #expect(source.times == request.times)
        #expect(!loader.isLoading)
        loader.cancel()
        await loader.load(request)
        #expect(creations == 1)
        #expect(source.times.count == 12)
        let other = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/b.mov"), selection: selection)
        #expect(loader.frame(at: 0, for: other) == nil, "A new video's first render must not flash old frames")
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func replacedRequestCancelsItsDecoderAndIgnoresALateOldFrame() async throws {
        let oldSource = ControlledClipFrameSource()
        let newSource = ControlledClipFrameSource()
        let loader = VideoClipThumbnailLoader { url in url.lastPathComponent == "a.mov" ? oldSource : newSource }
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 0, duration: 65)))
        let oldRequest = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/a.mov"), selection: selection, count: 1)
        let newRequest = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/b.mov"), selection: selection, count: 1)
        let first = Task { await loader.load(oldRequest) }
        _ = await oldSource.nextRequest()
        let second = Task { await loader.load(newRequest) }
        _ = await newSource.nextRequest()
        #expect(oldSource.wasCancelled)
        newSource.complete(with: try makeFrame(width: 8))
        await second.value
        oldSource.complete(with: try makeFrame(width: 4))
        await first.value
        #expect(loader.frames[0]?.width == 8)
        #expect(!loader.isLoading)
        #expect(loader.frame(at: 0, for: oldRequest) == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func cancellationRetainsCompletedFramesAndRetryOnlyLoadsMissingOnes() async throws {
        let firstSource = ControlledClipFrameSource()
        let retrySource = ImmediateClipFrameSource(frame: try makeFrame(width: 8))
        var creations = 0
        let loader = VideoClipThumbnailLoader { _ in
            creations += 1
            if creations == 1 { return firstSource }
            return retrySource
        }
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 0, duration: 65)))
        let request = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/a.mov"), selection: selection, count: 2)
        let pending = Task { await loader.load(request) }
        _ = await firstSource.nextRequest()
        firstSource.complete(with: try makeFrame(width: 4))
        _ = await firstSource.nextRequest()
        pending.cancel()
        await firstSource.waitForCancellation()
        #expect(firstSource.wasCancelled)
        #expect(loader.frames[0]?.width == 4)
        firstSource.complete(with: try makeFrame(width: 6))
        await pending.value
        #expect(loader.frames[1] == nil)
        await loader.load(request)
        #expect(loader.frames[0]?.width == 4)
        #expect(loader.frames[1]?.width == 8)
        #expect(retrySource.times == [request.times[1]])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func oneMissingThumbnailDoesNotDiscardTheRestOfTheStrip() async throws {
        let source = ImmediateClipFrameSource(frame: try makeFrame(width: 4), failingCall: 2)
        let loader = VideoClipThumbnailLoader { _ in source }
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 0, duration: 65)))
        let request = VideoClipThumbnailLoader.Request(url: URL(fileURLWithPath: "/a.mov"), selection: selection, count: 3)
        await loader.load(request)
        #expect(loader.frames[0] != nil)
        #expect(loader.frames[1] == nil)
        #expect(loader.frames[2] != nil)
        #expect(!loader.isLoading)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func realThumbnailDecoderRespectsOrientationAndPixelBudget() async throws {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let source = try await VideoTestFixture.makeVideo(transform: rotation)
        defer { try? FileManager.default.removeItem(at: source) }
        let loader = VideoClipThumbnailLoader()
        let selection = try #require(VideoClipSelection(sourceRange: range(start: 0, duration: 1)))
        await loader.load(.init(url: source, selection: selection, count: 3))
        #expect(loader.frames.count == 3)
        for frame in loader.frames {
            let image = try #require(frame)
            #expect(image.height > image.width)
            #expect(image.width <= 160 && image.height <= 160)
        }
    }

    private func range(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    private func makeFrame(width: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 4,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
}

@MainActor
private final class ImmediateClipFrameSource: VideoClipFrameSource {
    let frame: CGImage
    let failingCall: Int?
    var times: [Double] = []
    init(frame: CGImage, failingCall: Int? = nil) {
        self.frame = frame
        self.failingCall = failingCall
    }
    func image(at seconds: Double) async throws -> CGImage {
        times.append(seconds)
        if times.count == failingCall { throw CocoaError(.fileReadCorruptFile) }
        return frame
    }
    func cancel() {}
}

/// Deliberately completes even after cancel(), to reproduce a decoder callback
/// arriving late. The loader, rather than the test double, must suppress it.
@MainActor
private final class ControlledClipFrameSource: VideoClipFrameSource {
    private var pending: CheckedContinuation<CGImage, Error>?
    private var requests: [Double] = []
    private var waiter: CheckedContinuation<Double, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func image(at seconds: Double) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            if let waiting = waiter {
                waiter = nil
                waiting.resume(returning: seconds)
            } else {
                requests.append(seconds)
            }
        }
    }

    func nextRequest() async -> Double {
        if !requests.isEmpty { return requests.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func complete(with image: CGImage) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: image)
    }

    func waitForCancellation() async {
        if wasCancelled { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }

    func cancel() {
        wasCancelled = true
        let waiting = cancellationWaiter
        cancellationWaiter = nil
        waiting?.resume()
    }
}

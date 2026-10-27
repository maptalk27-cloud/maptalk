import AVFoundation
import Foundation
import Testing
@testable import maptalk

struct MapTalkInlineCameraTests {
    @Test
    func shortPressProducesExactlyOnePhotoAndNeverStartsVideo() {
        var press = MapTalkShutterPressState()
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.ended(inside: true) == .photo)
        #expect(press.held() == .none, "A late hold timer cannot record after finger-up")
        #expect(press.ended(inside: true) == .none)
    }

    @Test
    func holdingAndReleasingProducesVideoOnlyEvenIfPermissionWasDeclined() {
        var press = MapTalkShutterPressState()
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.held() == .startVideo)
        #expect(press.held() == .none)
        // The camera may refuse the start or show a microphone permission
        // prompt. That consumed long press must not become a photo on release.
        #expect(press.ended(inside: true) == .finishVideo)
        #expect(press.ended(inside: true) == .none)
        #expect(press.held() == .none)
    }

    @Test
    func cancelledTapAndReleaseOutsideDoNotTakePhotos() {
        var press = MapTalkShutterPressState()
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.ended(inside: true, cancelled: true) == .none)
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.ended(inside: false) == .none)
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.held() == .startVideo)
        #expect(press.ended(inside: false, cancelled: true) == .finishVideo)
    }

    @Test
    func busyStateBlocksNewPressesButCannotLoseTheCurrentRelease() {
        var press = MapTalkShutterPressState()
        #expect(press.began(acceptsNewCapture: false) == false)
        #expect(press.ended(inside: true) == .none)
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.held() == .startVideo)
        #expect(press.began(acceptsNewCapture: false) == false)
        #expect(press.ended(inside: false) == .finishVideo)
    }

    @Test
    func releaseBeforeMovieDidStartIsLatchedUntilItsCallback() {
        var press = MapTalkShutterPressState()
        var recording = MapTalkRecordingStopLatch()
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.held() == .startVideo)
        recording.begin()
        #expect(!recording.shouldStopOnStart(isActive: true, wasCancelled: false))
        #expect(press.ended(inside: true) == .finishVideo)
        recording.requestStop()
        #expect(recording.shouldStopOnStart(isActive: true, wasCancelled: false),
                "didStart must immediately stop even if isRecording was false at finger-up")
        #expect(press.held() == .none)
    }

    @Test
    func backgroundStopRemainsLatchedAfterReturningToForeground() {
        var recording = MapTalkRecordingStopLatch()
        recording.begin()
        #expect(recording.shouldStopOnStart(isActive: false, wasCancelled: false))
        recording.requestStop()
        #expect(recording.shouldStopOnStart(isActive: true, wasCancelled: false))
        recording.begin() // Only a genuinely new press clears the old stop.
        #expect(!recording.shouldStopOnStart(isActive: true, wasCancelled: false))
        #expect(recording.shouldStopOnStart(isActive: true, wasCancelled: true))
    }

    @Test
    func automaticDurationCompletionDoesNotTurnFingerUpIntoAPhoto() {
        var press = MapTalkShutterPressState()
        #expect(press.began(acceptsNewCapture: true) == true)
        #expect(press.held() == .startVideo)
        // AVCapture finishes at 60 seconds independently of the held touch.
        // Keeping the consumed gesture until release prevents a second photo.
        #expect(press.ended(inside: true) == .finishVideo)
        #expect(press.ended(inside: true) == .none)
    }

    @Test
    func recordingClockIsBoundedToOneMinute() {
        #expect(MapTalkInlineCameraPolicy.maximumDuration == 60)
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: -1) == "00:00")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: 0) == "00:00")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: 9.8) == "00:09")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: 59.9) == "00:59")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: 60) == "01:00")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: 100) == "01:00")
        #expect(MapTalkInlineCameraPolicy.elapsedLabel(seconds: .infinity) == "00:00")
    }

    @Test
    func reachingRecordingLimitCanStillProduceAUsableVideo() {
        let durationLimit = NSError(domain: AVFoundationErrorDomain,
                                    code: AVError.maximumDurationReached.rawValue,
                                    userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        #expect(MapTalkInlineCameraPolicy.recordingSucceeded(error: nil))
        #expect(MapTalkInlineCameraPolicy.recordingSucceeded(error: durationLimit))
    }

    @Test
    func failedOrIncompleteRecordingIsNotAccepted() {
        let failed = NSError(domain: AVFoundationErrorDomain,
                             code: AVError.diskFull.rawValue,
                             userInfo: [AVErrorRecordingSuccessfullyFinishedKey: false])
        let unknown = NSError(domain: AVFoundationErrorDomain, code: -1)
        #expect(!MapTalkInlineCameraPolicy.recordingSucceeded(error: failed))
        #expect(!MapTalkInlineCameraPolicy.recordingSucceeded(error: unknown))
    }

    @Test
    func cancellationOrAnEmptyOutputCannotReplaceComposerMedia() {
        #expect(MapTalkInlineCameraPolicy.shouldKeepRecording(
            finishedSuccessfully: true, fileByteCount: 1_024, wasCancelled: false))
        #expect(!MapTalkInlineCameraPolicy.shouldKeepRecording(
            finishedSuccessfully: true, fileByteCount: 1_024, wasCancelled: true))
        #expect(!MapTalkInlineCameraPolicy.shouldKeepRecording(
            finishedSuccessfully: true, fileByteCount: 0, wasCancelled: false))
        #expect(!MapTalkInlineCameraPolicy.shouldKeepRecording(
            finishedSuccessfully: false, fileByteCount: 1_024, wasCancelled: false))
    }
}

import AVFoundation
import Foundation
import Testing
import UIKit
@testable import maptalk

struct MapTalkInlineCameraTests {
    @Test
    func quickCaptureUsesStandardStabilizationOnlyWhenBothConnectionAndFormatSupportIt() {
        #expect(MapTalkInlineCameraPolicy.stabilizationMode(
            connectionSupports: true, formatSupportsStandard: true) == .standard)
        #expect(MapTalkInlineCameraPolicy.stabilizationMode(
            connectionSupports: false, formatSupportsStandard: true) == .off)
        #expect(MapTalkInlineCameraPolicy.stabilizationMode(
            connectionSupports: true, formatSupportsStandard: false) == .off)
        #expect(MapTalkInlineCameraPolicy.stabilizationMode(
            connectionSupports: false, formatSupportsStandard: false) == .off)
    }

    @Test
    func shutterHintsExplainPhotoVideoAndRetryAfterMicrophonePermission() {
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: false, isFinishing: false, microphoneJustGranted: false)
            == "Tap for photo · hold for video")
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: false, isFinishing: false, microphoneJustGranted: true)
            == "Microphone ready · hold to record")
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: true, isFinishing: false, microphoneJustGranted: true)
            == "Release to finish")
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: true, isFinishing: true, microphoneJustGranted: false)
            == "Saving…")
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: false, isFinishing: false, microphoneJustGranted: false, isStarting: true)
            == "Starting… · release to finish")
        #expect(MapTalkInlineCameraPolicy.shutterHint(
            isRecording: false, isFinishing: true, microphoneJustGranted: false, isStarting: true)
            == "Saving…")
    }

    @Test @MainActor
    func shutterRespondsOnTouchDownAndToleratesSmallFingerDriftForOnePhoto() {
        let shutter = MapTalkShutterControl(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        shutter.allowsNewCapture = true
        var photos = 0
        var starts = 0
        var finishes = 0
        shutter.onPhoto = { photos += 1 }
        shutter.onHold = { starts += 1 }
        shutter.onRelease = { finishes += 1 }

        #expect(shutter.beginPress())
        #expect(shutter.isHighlighted, "Feedback must not wait for the hold threshold or camera callback")
        let slightDrift = CGPoint(x: 80, y: 32)
        #expect(MapTalkShutterPressState.containsRelease(slightDrift, in: shutter.bounds))
        #expect(shutter.continuePress(at: slightDrift))
        shutter.endPress(at: slightDrift)
        shutter.endPress(at: slightDrift)
        shutter.recognizeHold()

        #expect(!shutter.isHighlighted)
        #expect(photos == 1)
        #expect(starts == 0)
        #expect(finishes == 0)
    }

    @Test @MainActor
    func draggingFarAwayCancelsTheTapAndALateHoldCannotCapture() {
        let shutter = MapTalkShutterControl(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        shutter.allowsNewCapture = true
        var photos = 0
        var starts = 0
        var finishes = 0
        shutter.onPhoto = { photos += 1 }
        shutter.onHold = { starts += 1 }
        shutter.onRelease = { finishes += 1 }

        #expect(shutter.beginPress())
        #expect(!shutter.continuePress(at: CGPoint(x: 100, y: 32)))
        #expect(!shutter.isHighlighted)
        shutter.recognizeHold()
        shutter.endPress(at: CGPoint(x: 32, y: 32))

        #expect(shutter.beginPress(), "Cancellation must permit the next genuine touch")
        shutter.cancelPress()
        shutter.recognizeHold()
        shutter.endPress(at: CGPoint(x: 32, y: 32))
        #expect(photos == 0)
        #expect(starts == 0)
        #expect(finishes == 0)
    }

    @Test @MainActor
    func heldShutterStillFinishesOnceWhenFingerReleasesFarOutside() {
        let shutter = MapTalkShutterControl(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        shutter.allowsNewCapture = true
        var photos = 0
        var starts = 0
        var finishes = 0
        shutter.onPhoto = { photos += 1 }
        shutter.onHold = { starts += 1 }
        shutter.onRelease = { finishes += 1 }

        #expect(shutter.beginPress())
        shutter.recognizeHold()
        shutter.recognizeHold()
        let outside = CGPoint(x: 200, y: -100)
        #expect(shutter.continuePress(at: outside), "A recording must retain its release outside the shutter")
        shutter.endPress(at: outside)
        shutter.cancelPress()
        shutter.endPress(at: outside)

        #expect(starts == 1)
        #expect(finishes == 1)
        #expect(photos == 0)
        #expect(!shutter.isHighlighted)
    }

    @Test @MainActor
    func busyAppearanceUpdatesDoNotDisableTheHeldTouchOrLoseItsRelease() {
        let shutter = MapTalkShutterControl(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        shutter.allowsNewCapture = true
        var photos = 0
        var starts = 0
        var finishes = 0
        shutter.onPhoto = { photos += 1 }
        shutter.onHold = { starts += 1 }
        shutter.onRelease = { finishes += 1 }

        #expect(shutter.beginPress())
        shutter.recognizeHold()
        shutter.allowsNewCapture = false
        shutter.isStarting = true
        shutter.updateAppearance()
        #expect(shutter.isEnabled)
        #expect(shutter.isHighlighted)
        #expect(!shutter.beginPress(), "A busy redraw must not admit a second touch")
        shutter.isStarting = false
        shutter.isFinishing = true
        shutter.updateAppearance()
        #expect(shutter.isEnabled)
        shutter.endPress(at: nil)
        shutter.cancelPress()

        #expect(starts == 1)
        #expect(finishes == 1)
        #expect(photos == 0)
        #expect(!shutter.isHighlighted)
    }

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

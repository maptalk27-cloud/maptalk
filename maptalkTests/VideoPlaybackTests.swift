import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import maptalk

struct VideoPlaybackTests {
    @Test(arguments: 0..<8)
    func playbackRequiresVisibleSelectedForegroundVideo(state: Int) {
        let visible = state & 1 != 0
        let selected = state & 2 != 0
        let active = state & 4 != 0
        #expect(VideoPlaybackPolicy.shouldPlay(isVisible: visible, isSelected: selected,
                                              isSceneActive: active) == (visible && selected && active))
    }

    @Test @MainActor
    func compactAndOpenedVideosDefaultToSoundUnlessExplicitlyMuted() {
        let url = URL(fileURLWithPath: "/tmp/playback-test.mp4")
        let compact = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue, mode: .card)
        let opened = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue, mode: .lightbox)
        let muted = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue,
                                                          mode: .lightbox, isMuted: true)
        let mutedCompact = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue,
                                                                 mode: .card, isMuted: true)
        #expect(!compact.isMuted)
        #expect(!opened.isMuted)
        #expect(muted.isMuted)
        #expect(mutedCompact.isMuted)
    }

    @Test @MainActor
    func playerLayerUsesParentBoundsAndRemainsMutedUntilPlaybackIsRequested() throws {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let view = ExperienceDetailView.LoopingVideoPlayerView.PlayerContainerView(frame: frame)
        let url = URL(fileURLWithPath: "/tmp/playback-layout-test.mp4")
        view.configure(with: url, muted: false, videoGravity: .resizeAspectFill)
        defer { view.cleanup() }
        let layer = try #require(view.layer as? AVPlayerLayer)
        let player = try #require(layer.player)
        #expect(layer.bounds.size == frame.size)
        #expect(layer.videoGravity == .resizeAspectFill)
        #expect(player.isMuted)
        #expect(player.volume == 1)
        view.setPlaying(false)
        #expect(player.rate == 0)
        #expect(player.isMuted)
        view.configure(with: url, muted: true, videoGravity: .resizeAspect)
        #expect(layer.player === player)
        #expect(layer.videoGravity == .resizeAspect)
        view.cleanup()
        #expect(layer.player == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func bundledVideoPlaysAndLoopsWithoutStoryProgressCallbacks() async throws {
        let resource = "istockphoto-1467181036-640_adpp_is"
        let url = try #require(Bundle.main.url(forResource: resource, withExtension: "mp4")
            ?? Bundle.main.url(forResource: resource, withExtension: "mp4", subdirectory: "Mock"))
        try #require(url.isFileURL, "Playback must use the bundled asset, never the network")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        try #require(duration.isFinite && duration > 0 && duration < 10)

        let view = ExperienceDetailView.LoopingVideoPlayerView.PlayerContainerView(
            frame: CGRect(x: 0, y: 0, width: 180, height: 320)
        )
        defer { view.cleanup() }
        view.configure(with: url, muted: true, videoGravity: .resizeAspect)
        let layer = try #require(view.layer as? AVPlayerLayer)
        let player = try #require(layer.player)
        view.setPlaying(true)

        // Observe the real player's queue advancing into another loop. No
        // story timer, progress callback or synthetic end event drives it.
        // SuspendingClock excludes Mac sleep from this bounded playback wait.
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(duration + 5))
        var firstPlayingItem: AVPlayerItem?
        var furthestFirstCycleTime: TimeInterval = 0
        var playedAnotherLoop = false
        while clock.now < deadline {
            if player.timeControlStatus == .playing, let item = player.currentItem {
                let elapsed = player.currentTime().seconds
                if elapsed.isFinite, elapsed > 0.1 {
                    if firstPlayingItem == nil { firstPlayingItem = item }
                    if item === firstPlayingItem {
                        furthestFirstCycleTime = max(furthestFirstCycleTime, elapsed)
                    } else if furthestFirstCycleTime >= duration * 0.8 {
                        playedAnotherLoop = true
                        break
                    }
                }
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        #expect(playedAnotherLoop,
                "The selected video must keep looping without advancing stories; reached \(furthestFirstCycleTime) of \(duration) seconds")
        #expect(layer.player === player)
        #expect(player.isMuted)
    }

    @Test @MainActor
    func audibleSessionIsScopedMixableAndRestoresPreviousConfiguration() {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .zero)
        let owner = UUID()
        #expect(session.activationRequests.isEmpty)
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        #expect(session.category == .playback)
        #expect(session.mode == .moviePlayback)
        #expect(session.categoryOptions == [.mixWithOthers])
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        #expect(session.activationRequests == [true])
        audio.release(owner: owner)
        #expect(session.activationRequests == [true, false])
        #expect(session.lastDeactivationOptions == [.notifyOthersOnDeactivation])
        #expect(session.category == .ambient)
        #expect(session.mode == .default)
        #expect(session.categoryOptions == [])
        audio.release(owner: owner)
        #expect(session.activationRequests == [true, false])
    }

    @Test @MainActor
    func selectingAnotherVideoStopsPreviousOwnerAndIgnoresLateCleanup() {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .zero)
        let first = UUID()
        let second = UUID()
        var stoppedFirst = false
        #expect(audio.acquire(owner: first) {
            stoppedFirst = true
            audio.release(owner: first)
        })
        #expect(audio.acquire(owner: second, stopPlayback: {}))
        #expect(stoppedFirst)
        #expect(session.activationRequests == [true])
        #expect(session.categoryChanges.count == 1)
        audio.release(owner: first)
        #expect(session.activationRequests == [true])
        audio.release(owner: second)
        #expect(session.activationRequests == [true, false])
        #expect(session.category == .ambient)
    }

    @Test @MainActor
    func outgoingFirstHandoffCancelsDeferredReleaseAndEventuallyReleases() async throws {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .milliseconds(40))
        let first = UUID()
        let second = UUID()
        #expect(audio.acquire(owner: first, stopPlayback: {}))
        audio.release(owner: first)
        #expect(session.activationRequests == [true])
        // The new page may not become selected until a subsequent UI update.
        try await Task.sleep(for: .milliseconds(5))
        #expect(audio.acquire(owner: second, stopPlayback: {}))
        audio.release(owner: first)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.activationRequests == [true])
        #expect(session.categoryChanges.count == 1)
        audio.release(owner: second)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.activationRequests == [true, false])
        #expect(session.category == .ambient)
    }

    @Test @MainActor
    func twentyMixedOrderHandoffsUseOneSessionAndSilenceEveryPredecessor() async throws {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .milliseconds(40))
        var current = UUID()
        var stoppedOwners: Set<UUID> = []
        let first = current
        #expect(audio.acquire(owner: first) {
            stoppedOwners.insert(first)
            audio.release(owner: first)
        })
        for index in 0..<20 {
            let outgoing = current
            if index.isMultiple(of: 2) {
                // An outgoing-first caller stops its own player before release.
                stoppedOwners.insert(outgoing)
                audio.release(owner: outgoing)
            }
            let incoming = UUID()
            #expect(audio.acquire(owner: incoming) {
                stoppedOwners.insert(incoming)
                audio.release(owner: incoming)
            })
            audio.release(owner: outgoing)
            current = incoming
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(stoppedOwners.count == 20)
        #expect(!stoppedOwners.contains(current))
        #expect(session.activationRequests == [true])
        #expect(session.categoryChanges.count == 1)
        audio.release(owner: current)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.activationRequests == [true, false])
        #expect(session.categoryChanges.count == 2)
    }

    @Test @MainActor
    func backgroundStopsCurrentPlayerAndReleasesWithoutGracePeriod() {
        let session = PlaybackAudioSessionSpy()
        let notifications = NotificationCenter()
        let audio = VideoPlaybackAudioSession(session: session, notificationCenter: notifications)
        let first = UUID()
        var stopped = false
        #expect(audio.acquire(owner: first) {
            stopped = true
            audio.release(owner: first)
        })
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(stopped)
        #expect(session.activationRequests == [true, false])
        #expect(!audio.acquire(owner: first, stopPlayback: {}))
        notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(audio.acquire(owner: first, stopPlayback: {}))
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(session.activationRequests == [true, false, true, false])
    }

    @Test @MainActor
    func interruptionInvalidatesCachedSessionAndAllowsFreshPlaybackAfterEnding() {
        let session = PlaybackAudioSessionSpy()
        let notifications = NotificationCenter()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .zero,
                                               notificationCenter: notifications)
        let first = UUID()
        var stopped = false
        #expect(audio.acquire(owner: first) {
            stopped = true
            audio.release(owner: first)
        })
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(stopped)
        #expect(!audio.acquire(owner: first, stopPlayback: {}))
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        #expect(audio.acquire(owner: first, stopPlayback: {}))
        #expect(session.activationRequests == [true, false, true])
        audio.release(owner: first)
        #expect(session.activationRequests == [true, false, true, false])
    }

    @Test @MainActor
    func foregroundCanRetryAfterInterruptionWithoutMatchingEndNotification() {
        let session = PlaybackAudioSessionSpy()
        let notifications = NotificationCenter()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .zero,
                                               notificationCenter: notifications)
        let owner = UUID()
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        // The OS, rather than a stale local interruption flag, decides whether
        // audio is available after the app resumes.
        session.rejectActivation = true
        #expect(!audio.acquire(owner: owner, stopPlayback: {}))
        #expect(session.activationRequests == [true, false, true])
        session.rejectActivation = false
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        audio.release(owner: owner)
        #expect(session.activationRequests == [true, false, true, true, false])
        #expect(session.category == .ambient)
    }

    @Test @MainActor
    func delayedCleanupDoesNotDeactivateOrOverwriteCameraConfiguration() async throws {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .milliseconds(40))
        let owner = UUID()
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        audio.release(owner: owner)
        try session.setCategory(.playAndRecord, mode: .videoRecording, options: [])
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.activationRequests == [true])
        #expect(session.category == .playAndRecord)
        #expect(session.mode == .videoRecording)
        #expect(session.categoryChanges.count == 2)
    }

    @Test @MainActor
    func failedActivationDoesNotClaimOwnershipOrLeavePlaybackCategoryBehind() {
        let session = PlaybackAudioSessionSpy()
        session.rejectActivation = true
        let audio = VideoPlaybackAudioSession(session: session, releaseDelay: .zero)
        let owner = UUID()
        #expect(!audio.acquire(owner: owner, stopPlayback: {}))
        #expect(session.category == .ambient)
        audio.release(owner: owner)
        #expect(session.activationRequests == [true])
        session.rejectActivation = false
        #expect(audio.acquire(owner: owner, stopPlayback: {}))
        audio.release(owner: owner)
        #expect(session.activationRequests == [true, true, false])
    }
}

@MainActor
private final class PlaybackAudioSessionSpy: VideoAudioSessionControlling {
    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var activationRequests: [Bool] = []
    var lastDeactivationOptions: AVAudioSession.SetActiveOptions = []
    var rejectActivation = false
    var categoryChanges: [AVAudioSession.Category] = []

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        self.category = category
        categoryChanges.append(category)
        self.mode = mode
        categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activationRequests.append(active)
        if active && rejectActivation { throw CocoaError(.featureUnsupported) }
        if !active { lastDeactivationOptions = options }
    }
}

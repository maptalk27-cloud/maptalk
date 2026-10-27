import AVFoundation
import Foundation
import SwiftUI
import Testing
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
    func compactDefaultsToQuietButOpenedVideoIsAudibleUnlessExplicitlyMuted() {
        let url = URL(fileURLWithPath: "/tmp/playback-test.mp4")
        let compact = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue, mode: .card)
        let opened = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue, mode: .lightbox)
        let muted = ExperienceDetailView.AutoPlayVideoView(url: url, poster: nil, accentColor: .blue,
                                                          mode: .lightbox, isMuted: true)
        #expect(compact.isMuted)
        #expect(!opened.isMuted)
        #expect(muted.isMuted)
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

    @Test @MainActor
    func audibleSessionIsScopedMixableAndRestoresPreviousConfiguration() {
        let session = PlaybackAudioSessionSpy()
        let audio = VideoPlaybackAudioSession(session: session)
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
        let audio = VideoPlaybackAudioSession(session: session)
        let first = UUID()
        let second = UUID()
        var stoppedFirst = false
        #expect(audio.acquire(owner: first) {
            stoppedFirst = true
            audio.release(owner: first)
        })
        #expect(audio.acquire(owner: second, stopPlayback: {}))
        #expect(stoppedFirst)
        #expect(session.activationRequests == [true, false, true])
        audio.release(owner: first)
        #expect(session.activationRequests == [true, false, true])
        audio.release(owner: second)
        #expect(session.activationRequests == [true, false, true, false])
        #expect(session.category == .ambient)
    }

    @Test @MainActor
    func failedActivationDoesNotClaimOwnershipOrLeavePlaybackCategoryBehind() {
        let session = PlaybackAudioSessionSpy()
        session.rejectActivation = true
        let audio = VideoPlaybackAudioSession(session: session)
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

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        self.category = category
        self.mode = mode
        categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activationRequests.append(active)
        if active && rejectActivation { throw CocoaError(.featureUnsupported) }
        if !active { lastDeactivationOptions = options }
    }
}

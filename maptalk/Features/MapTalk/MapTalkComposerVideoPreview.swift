import AVFoundation
import SwiftUI

/// Review stays on the composer's canvas. This surface never presents another
/// controller, takes ownership of the file, or starts audible playback by itself.
struct MapTalkComposerVideoPreview: View {
    let player: AVPlayer
    var startTime: Double = 0
    var isActive = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPlaying = false
    @State private var wantsSound = true
    @State private var audioOwner = UUID()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ComposerPlayerLayer(player: player)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Button(action: togglePlayback) {
                ZStack {
                    Color.clear
                    if !isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Video preview")
            .accessibilityValue(isPlaying ? "Playing" : "Paused")
            .accessibilityHint(isPlaying ? "Tap to pause" : "Tap to play")
            .accessibilityIdentifier("maptalk.place.video.playback")

            Button {
                wantsSound.toggle()
                if isPlaying { configureSound() }
            } label: {
                Image(systemName: wantsSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(wantsSound ? "Mute video" : "Unmute video")
            .accessibilityIdentifier("maptalk.place.video.sound")
            .padding(8)
        }
        .background(.black)
        .onAppear { player.isMuted = true }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = status != .paused
            if status == .paused {
                player.isMuted = true
                VideoPlaybackAudioSession.shared.release(owner: audioOwner)
            }
        }
        .onChange(of: isActive) { _, active in if !active { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }

    private func togglePlayback() {
        guard isActive, scenePhase == .active else { return }
        if isPlaying { stop(); return }
        let end = player.currentItem?.forwardPlaybackEndTime.seconds
        let duration = player.currentItem?.duration.seconds
        let endTime = end.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? duration.flatMap { $0.isFinite ? $0 : nil }
        if let endTime, player.currentTime().seconds >= endTime - 0.05 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        configureSound()
        player.play()
    }

    private func configureSound() {
        if wantsSound {
            let acquired = VideoPlaybackAudioSession.shared.acquire(owner: audioOwner) { stop() }
            player.isMuted = !acquired
        } else {
            player.isMuted = true
            VideoPlaybackAudioSession.shared.release(owner: audioOwner)
        }
    }

    private func stop() {
        player.pause()
        player.isMuted = true
        isPlaying = false
        VideoPlaybackAudioSession.shared.release(owner: audioOwner)
    }
}

private struct ComposerPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            playerLayer.videoGravity = .resizeAspect
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

import AVFoundation
import SwiftUI

/// Review stays on the composer's canvas. This surface never presents another
/// controller, takes ownership of the file, or starts audible playback by itself.
struct MapTalkComposerVideoPreview: View {
    let player: AVPlayer
    var startTime: Double = 0
    var isActive = true
    var poster: UIImage?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPlaying = false
    @State private var wantsSound = true
    @State private var audioOwner = UUID()
    @State private var generatedPoster: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ComposerPlayerLayer(player: player, poster: poster ?? generatedPoster)
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
        .task(id: ObjectIdentifier(player)) {
            generatedPoster = nil
            guard poster == nil,
                  let source = player.currentItem?.asset as? AVURLAsset else { return }
            // The raw capture can be reviewed while its upload copy is being
            // prepared. A small in-memory poster bridges player warm-up.
            let image = try? await makeComposerVideoPoster(at: source.url, startTime: startTime)
            guard !Task.isCancelled, let image else { return }
            generatedPoster = UIImage(cgImage: image.image)
        }
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
    let poster: UIImage?

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        view.configure(player: player, poster: poster)
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.cleanup()
    }

    final class Surface: UIView {
        private let playerLayer = AVPlayerLayer()
        private let posterView = UIImageView()
        private var readyObservation: NSKeyValueObservation?
        private var hasReadyFrame = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.black.cgColor
            playerLayer.opacity = 0
            layer.addSublayer(playerLayer)
            posterView.contentMode = .scaleAspectFit
            posterView.backgroundColor = .black
            posterView.isHidden = true
            addSubview(posterView)
            isUserInteractionEnabled = false
        }

        func configure(player: AVPlayer, poster: UIImage?) {
            if playerLayer.player !== player {
                cleanup()
                playerLayer.player = player
                let playerID = ObjectIdentifier(player)
                readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let activePlayer = self.playerLayer.player,
                              ObjectIdentifier(activePlayer) == playerID else { return }
                        self.hasReadyFrame = true
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.playerLayer.opacity = 1
                        self.posterView.isHidden = true
                        CATransaction.commit()
                    }
                }
            }
            posterView.image = poster
            posterView.isHidden = hasReadyFrame || poster == nil
        }

        func cleanup() {
            readyObservation?.invalidate()
            readyObservation = nil
            hasReadyFrame = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = 0
            playerLayer.player = nil
            CATransaction.commit()
            posterView.image = nil
            posterView.isHidden = true
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            posterView.frame = bounds
            CATransaction.commit()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

@concurrent
nonisolated private func makeComposerVideoPoster(at url: URL, startTime: Double) async throws -> LocalMapDecodedImage {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 960)
    let time = CMTime(seconds: max(0, startTime), preferredTimescale: 600)
    let frame = try await generator.image(at: time)
    try Task.checkCancellation()
    return LocalMapDecodedImage(frame.image)
}

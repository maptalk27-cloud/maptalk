import AVKit
import SwiftUI
import UIKit

// MARK: - Media

extension ExperienceDetailView {
struct ExperienceMediaGallery: View {
    let items: [MediaDisplayItem]
    let accentColor: Color

    @State private var selection: UUID
    @State private var isLightboxPresented = false

    init(items: [MediaDisplayItem], accentColor: Color) {
        self.items = items
        self.accentColor = accentColor
        _selection = State(initialValue: items.first?.id ?? UUID())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if items.isEmpty {
                EmptyGalleryPlaceholder(accentColor: accentColor)
            } else {
                if usesGridLayout {
                    LazyVGrid(columns: ExperienceMediaGalleryLayout.gridColumns, spacing: ExperienceMediaGalleryLayout.gridSpacing) {
                        ForEach(items) { item in
                            MediaCardView(item: item, accentColor: accentColor, mode: .card)
                                .frame(height: ExperienceMediaGalleryLayout.gridItemHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = item.id
                                    isLightboxPresented = true
                                }
                        }
                    }
                } else {
                    TabView(selection: $selection) {
                        ForEach(items) { item in
                            MediaCardView(item: item, accentColor: accentColor, mode: .card)
                                .tag(item.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isLightboxPresented = true
                    }
                    .overlay(pageIndicator, alignment: .bottomTrailing)
                }
            }

            if let summary = summaryText {
                Text(summary)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule(style: .continuous))
                    .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selection)
        .fullScreenCover(isPresented: $isLightboxPresented) {
            MediaLightbox(
                items: items,
                selection: $selection,
                accentColor: accentColor,
                isPresented: $isLightboxPresented
            )
        }
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selection }) ?? 0
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if items.count > 1 && usesGridLayout == false {
            Text("\(currentIndex + 1)/\(items.count)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule(style: .continuous))
                .padding(12)
        }
    }

    private var summaryText: String? {
        let counts = ExperienceDetailView.mediaCounts(for: items)
        var segments: [String] = []
        if counts.photos > 0 {
            segments.append("\(counts.photos) \(counts.photos == 1 ? "Photo" : "Photos")")
        }
        if counts.videos > 0 {
            segments.append("\(counts.videos) \(counts.videos == 1 ? "Video" : "Videos")")
        }
        if counts.emojis > 0 {
            segments.append("\(counts.emojis) \(counts.emojis == 1 ? "Emoji" : "Emoji")")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    private var usesGridLayout: Bool {
        ExperienceMediaGalleryLayout.requiresGrid(for: items)
    }
}

enum ExperienceMediaGalleryLayout {
    static let gridThreshold: Int = 3
    static let gridSpacing: CGFloat = 12
    static let gridItemHeight: CGFloat = 120
    static let carouselHeight: CGFloat = 240

    static func visualItemCount(in items: [MediaDisplayItem]) -> Int {
        items.filter { item in
            switch item.content {
            case .photo, .video:
                return true
            case .emoji:
                return false
            }
        }.count
    }

    static func requiresGrid(for items: [MediaDisplayItem]) -> Bool {
        visualItemCount(in: items) > gridThreshold
    }

    static func gridHeight(for items: [MediaDisplayItem]) -> CGFloat {
        let rows = max(1, Int(ceil(Double(visualItemCount(in: items)) / 3.0)))
        let spacing = CGFloat(max(0, rows - 1)) * gridSpacing
        return CGFloat(rows) * gridItemHeight + spacing
    }

    static func height(for items: [MediaDisplayItem]) -> CGFloat {
        requiresGrid(for: items) ? gridHeight(for: items) : carouselHeight
    }

    static var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)
    }
}

struct MediaLightbox: View {
    let items: [MediaDisplayItem]
    @Binding var selection: UUID
    let accentColor: Color
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(items) { item in
                    MediaCardView(item: item, accentColor: accentColor, mode: .lightbox)
                        .tag(item.id)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 40)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .overlay(indexBadge, alignment: .bottom)
            .animation(.easeInOut(duration: 0.22), value: selection)

            VStack {
                HStack {
                    if let summary = summaryText {
                        Text(summary)
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.4), in: Capsule(style: .continuous))
                    }
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.top, 30)
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selection }) ?? 0
    }

    private var summaryText: String? {
        let counts = ExperienceDetailView.mediaCounts(for: items)
        var segments: [String] = []
        if counts.photos > 0 {
            segments.append("\(counts.photos) \(counts.photos == 1 ? "Photo" : "Photos")")
        }
        if counts.videos > 0 {
            segments.append("\(counts.videos) \(counts.videos == 1 ? "Video" : "Videos")")
        }
        if counts.emojis > 0 {
            segments.append("\(counts.emojis) \(counts.emojis == 1 ? "Emoji" : "Emoji")")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    private var indexBadge: some View {
        Text("\(currentIndex + 1) / \(max(items.count, 1))")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule(style: .continuous))
            .padding(.bottom, 40)
    }
}

struct MediaCardView: View {
    enum Mode {
        case card
        case lightbox
    }

    let item: MediaDisplayItem
    let accentColor: Color
    let mode: Mode

    var body: some View {
        ZStack {
            switch item.content {
            case let .photo(url):
                imageView(url)
            case let .video(url, poster, metadata):
                videoView(url: url, poster: poster, metadata: metadata)
            case let .emoji(emoji):
                emojiView(emoji)
            }
        }
    }

    private func emojiView(_ emoji: String) -> some View {
        VStack(spacing: 16) {
            Text(emoji)
                .font(.system(size: mode == .lightbox ? 120 : 92))
                .shadow(color: accentColor.opacity(0.85), radius: 18)
            if mode == .card {
                Text("Live Drop")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [accentColor.opacity(0.5), .black.opacity(0.85)],
                center: .center,
                startRadius: 12,
                endRadius: mode == .lightbox ? 520 : 320
            )
        )
    }

    private func imageView(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.05), .black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            case .empty:
                ProgressView()
            case .failure:
                placeholder(symbol: "photo")
            @unknown default:
                placeholder(symbol: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func videoView(url: URL, poster: URL?, metadata: RealPost.Attachment.VideoMetadata?) -> some View {
        let shouldFit = metadata?.isStandardLandscape == false
        return AutoPlayVideoView(
            url: url,
            poster: poster,
            accentColor: accentColor,
            mode: mode,
            usesAspectFit: shouldFit
        )
    }

    private func placeholder(symbol: String) -> some View {
        placeholderBackground {
            Image(systemName: symbol)
                .font(.system(size: mode == .lightbox ? 68 : 54, weight: .bold))
                .foregroundStyle(.white)
        } subtitle: {
            Text("Content arriving soon")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func placeholderBackground<Title: View, Subtitle: View>(
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        VStack(spacing: 18) {
            title()
            subtitle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [accentColor.opacity(0.35), .black.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct AutoPlayVideoView: View {
    let url: URL
    let poster: URL?
    let accentColor: Color
    let mode: MediaCardView.Mode
    let showsPlaceholderBadge: Bool
    let usesAspectFit: Bool
    let isMuted: Bool

    @State private var isVideoVisible = false

    init(
        url: URL,
        poster: URL?,
        accentColor: Color,
        mode: MediaCardView.Mode,
        showsPlaceholderBadge: Bool = true,
        usesAspectFit: Bool = false,
        isMuted: Bool = true
    ) {
        self.url = url
        self.poster = poster
        self.accentColor = accentColor
        self.mode = mode
        self.showsPlaceholderBadge = showsPlaceholderBadge
        self.usesAspectFit = usesAspectFit
        self.isMuted = isMuted
    }

    var body: some View {
        ZStack {
            posterLayer

            LoopingVideoPlayerView(
                url: url,
                isMuted: isMuted,
                shouldPlay: isVideoVisible,
                videoGravity: usesAspectFit ? .resizeAspect : .resizeAspectFill
            )
                .opacity(isVideoVisible ? 1 : 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isVideoVisible = true
                    }
                }
                .onDisappear {
                    isVideoVisible = false
                }

            LinearGradient(
                colors: [.clear, .black.opacity(mode == .lightbox ? 0.25 : 0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var posterLayer: some View {
        if let poster {
            AsyncImage(url: poster) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: usesAspectFit ? .fit : .fill)
                        .overlay { Color.black.opacity(0.15) }
                case .empty:
                    ProgressView()
                case .failure:
                    placeholderPoster
                @unknown default:
                    placeholderPoster
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(usesAspectFit ? Color.black : Color.clear)
            .clipped()
        } else {
            placeholderPoster
        }
    }

    @ViewBuilder
    private var placeholderPoster: some View {
        if showsPlaceholderBadge {
            VStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: mode == .lightbox ? 52 : 38, weight: .bold))
                    .foregroundStyle(accentColor)
                Text("Loading video")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [accentColor.opacity(0.35), .black.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            LinearGradient(
                colors: [accentColor.opacity(0.2), .black.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct LoopingVideoPlayerView: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let shouldPlay: Bool
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(with: url, muted: isMuted, videoGravity: videoGravity)
        view.setPlaying(shouldPlay)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.configure(with: url, muted: isMuted, videoGravity: videoGravity)
        uiView.setPlaying(shouldPlay)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.cleanup()
    }

    final class PlayerContainerView: UIView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?

        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        private var playerLayer: AVPlayerLayer {
            guard let layer = layer as? AVPlayerLayer else {
                fatalError("Expected AVPlayerLayer.")
            }
            return layer
        }

        func configure(with url: URL, muted: Bool, videoGravity: AVLayerVideoGravity) {
            playerLayer.videoGravity = videoGravity
            guard currentURL != url else {
                player?.isMuted = muted
                return
            }
            cleanup()
            currentURL = url

            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = muted
            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

            playerLayer.player = queuePlayer
            playerLayer.videoGravity = videoGravity

            self.player = queuePlayer
            self.looper = looper
        }

        func setPlaying(_ shouldPlay: Bool) {
            guard let player else { return }
            if shouldPlay {
                player.play()
            } else {
                player.pause()
            }
        }

        func cleanup() {
            player?.pause()
            playerLayer.player = nil
            player = nil
            looper = nil
            currentURL = nil
        }
    }
}

struct EmptyGalleryPlaceholder: View {
    let accentColor: Color

    var body: some View {
        VStack(spacing: 10) {
            Text("No media yet")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Add a photo or video to bring this spot to life.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ExperienceMediaGalleryLayout.carouselHeight)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(
                colors: [accentColor.opacity(0.4), .black.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
}
}

extension ExperienceDetailView {
    static func mediaCounts(for items: [MediaDisplayItem]) -> (photos: Int, videos: Int, emojis: Int) {
        items.reduce(into: (0, 0, 0)) { result, item in
            switch item.content {
            case .photo:
                result.0 += 1
            case .video:
                result.1 += 1
            case .emoji:
                result.2 += 1
            }
        }
    }
}

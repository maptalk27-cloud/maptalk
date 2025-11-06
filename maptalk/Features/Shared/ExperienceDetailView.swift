import MapKit
import SwiftUI

struct ExperienceDetailView: View {
    enum Mode {
        case real(RealPost, User?)
        case poi(RatedPOI)
    }

    struct ReelPager {
        struct Item: Identifiable {
            let real: RealPost
            let user: User?

            var id: UUID { real.id }
        }

        let items: [Item]
        let initialId: UUID
    }

    struct ReelContext {
        let pager: ReelPager
        var selection: Binding<UUID>
    }

    fileprivate struct ContentData {
        let title: String
        let subtitle: String?
        let badges: [String]
        let highlight: String?
        let secondary: String?
        let media: ExperienceMedia
        let accentColor: Color
        let backgroundGradient: [Color]
        let mapRegion: MKCoordinateRegion
        let primaryActionTitle: String
        let primaryActionSymbol: String
    }

    private let poi: RatedPOI?
    private let reelContext: ReelContext?
    private let isExpanded: Bool

    init(ratedPOI: RatedPOI, isExpanded: Bool) {
        self.poi = ratedPOI
        self.reelContext = nil
        self.isExpanded = isExpanded
    }

    init(reelPager: ReelPager, selection: Binding<UUID>, isExpanded: Bool) {
        self.poi = nil
        self.reelContext = ReelContext(pager: reelPager, selection: selection)
        self.isExpanded = isExpanded
    }

    var body: some View {
        let currentData = contentData(for: currentMode)

        ZStack {
            background(for: currentData)

            if isExpanded {
                expandedContent(using: currentData)
            } else {
                collapsedPreview(using: currentData)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Presentation helpers

private extension ExperienceDetailView {
    var currentMode: Mode {
        if let context = reelContext {
            let identifier = context.selection.wrappedValue
            if let item = context.pager.items.first(where: { $0.id == identifier }) {
                return .real(item.real, item.user)
            }
            if let first = context.pager.items.first {
                return .real(first.real, first.user)
            }
        } else if let poi {
            return .poi(poi)
        }

        fatalError("ExperienceDetailView invoked without mode context.")
    }

    private func expandedContent(using data: ContentData) -> some View {
        Group {
            if let context = reelContext {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        ExperiencePanel(
                            data: contentData(for: .real(item.real, item.user))
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            } else {
                ExperiencePanel(data: data)
            }
        }
    }

    private func collapsedPreview(using data: ContentData) -> some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 44, height: 4)

            if let context = reelContext {
                CompactReelPager(
                    pager: context.pager,
                    selection: context.selection
                )
                .frame(height: 110)
            } else {
                VStack(spacing: 8) {
                    Text(data.title)
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if let subtitle = data.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }

                    let previewHighlight = data.highlight ?? data.media.previewText
                    if let highlight = previewHighlight {
                        Text(highlight)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(data.accentColor.opacity(0.2), in: Capsule(style: .continuous))
                    }
                }
            }

            Text("向上拖动以查看更多实时内容")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func background(for data: ContentData) -> some View {
        LinearGradient(
            colors: data.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            RadialGradient(
                colors: [data.accentColor.opacity(0.45), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            .blur(radius: 40)
            .blendMode(.screen)
        }
        .overlay {
            Color.black.opacity(0.55).ignoresSafeArea()
        }
    }
}

// MARK: - Content data

private extension ExperienceDetailView {
    func contentData(for mode: Mode) -> ContentData {
        switch mode {
        case let .real(real, user):
            let accent = accentColor(for: real.visibility)
            let gradient = gradient(for: real.visibility)
            let badges = makeRealBadges(for: real)
            let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let highlight = highlightText(for: real, message: message)
            let secondary = secondaryText(for: real)
            let media = media(for: real)
            let mapRegion = MKCoordinateRegion(
                center: real.center,
                latitudinalMeters: max(real.radiusMeters * 8, 600),
                longitudinalMeters: max(real.radiusMeters * 8, 600)
            )
            return ContentData(
                title: user?.handle ?? "Shared Real",
                subtitle: "Posted \(real.createdAt.formatted(.relative(presentation: .named)))",
                badges: badges,
                highlight: highlight,
                secondary: secondary,
                media: media,
                accentColor: accent,
                backgroundGradient: gradient,
                mapRegion: mapRegion,
                primaryActionTitle: "React",
                primaryActionSymbol: "face.smiling"
            )
        case let .poi(rated):
            let accent = rated.poi.category.accentColor
            let averageScore = rated.ratings.compactMap(\.score).average
            let highlight = rated.ratings.first(where: { $0.text?.isEmpty == false })?.text
            let secondary: String?
            secondary = averageScore
                .map { avg in
                    let formatted = String(format: "%.1f", avg)
                    return "Average score \(formatted) · Latest vibes from friends."
                }
                ?? "Friends are starting to rate this spot."
            return ContentData(
                title: rated.poi.name,
                subtitle: rated.poi.category.displayName,
                badges: ["\(rated.ratings.count) Ratings"],
                highlight: highlight,
                secondary: secondary,
                media: media(for: rated),
                accentColor: accent,
                backgroundGradient: [Color.black, accent.opacity(0.25)],
                mapRegion: MKCoordinateRegion(
                    center: rated.poi.coordinate,
                    latitudinalMeters: 800,
                    longitudinalMeters: 800
                ),
                primaryActionTitle: "Add Rating",
                primaryActionSymbol: "star.fill"
            )
        }
    }

    func media(for real: RealPost) -> ExperienceMedia {
        switch real.media {
        case let .emoji(emoji):
            return .emoji(emoji)
        case let .photo(url):
            return .image(url)
        case let .video(url, poster):
            return .video(url: url, poster: poster)
        case .none:
            if let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               message.isEmpty == false {
                return .text(message)
            }
            return .symbol("sparkles")
        }
    }

    func highlightText(for real: RealPost, message: String?) -> String? {
        if let message, message.isEmpty == false {
            if case .none = real.media {
                return nil
            }
            return message
        }
        if case let .emoji(emoji) = real.media {
            return "\(emoji) Live moment happening here."
        }
        return nil
    }

    func secondaryText(for real: RealPost) -> String {
        let base = "Visibility • \(real.visibility.displayName)"
        let descriptor: String?
        if let mediaDescriptor = mediaDescriptor(for: real.media) {
            descriptor = mediaDescriptor
        } else if let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  message.isEmpty == false {
            descriptor = "Shared a note"
        } else {
            descriptor = nil
        }

        guard let descriptor else { return base }
        return "\(base) · \(descriptor)"
    }

    func mediaDescriptor(for media: RealPost.Media) -> String? {
        switch media {
        case .none:
            return nil
        case .photo:
            return "Shared a photo"
        case .video:
            return "Shared a video"
        case let .emoji(emoji):
            return "\(emoji) moment"
        }
    }

    func media(for ratedPOI: RatedPOI) -> ExperienceMedia {
        if let emoji = ratedPOI.ratings.compactMap(\.emoji).first {
            return .emoji(emoji)
        }
        return .symbol(ratedPOI.poi.category.symbolName)
    }

    func makeRealBadges(for real: RealPost) -> [String] {
        let expiry = real.expiresAt.formatted(.relative(presentation: .named))
        var badges = [real.visibility.displayName, "Expires \(expiry)"]

        if real.metrics.likeCount > 0 {
            badges.append("❤️ \(formatCount(real.metrics.likeCount))")
        }
        if real.metrics.commentCount > 0 {
            badges.append("💬 \(formatCount(real.metrics.commentCount))")
        }

        return badges
    }

    func accentColor(for visibility: RealPost.Visibility) -> Color {
        switch visibility {
        case .publicAll:
            return Theme.neonPrimary
        case .friendsOnly:
            return Theme.neonAccent
        case .anonymous:
            return Theme.neonWarning
        }
    }

    func gradient(for visibility: RealPost.Visibility) -> [Color] {
        switch visibility {
        case .publicAll:
            return [Color.black, Theme.neonPrimary.opacity(0.25)]
        case .friendsOnly:
            return [Color.black, Theme.neonAccent.opacity(0.28)]
        case .anonymous:
            return [Color.black, Theme.neonWarning.opacity(0.28)]
        }
    }
}

private func formatCount(_ value: Int) -> String {
    guard value >= 1000 else { return "\(value)" }
    let doubleValue = Double(value)
    if value >= 1_000_000 {
        return trimmedCount(doubleValue / 1_000_000) + "M"
    } else {
        return trimmedCount(doubleValue / 1_000) + "K"
    }
}

private func trimmedCount(_ value: Double) -> String {
    let formatted = String(format: "%.1f", value)
    if formatted.hasSuffix(".0") {
        return String(formatted.dropLast(2))
    }
    return formatted
}

// MARK: - Experience panel

private struct ExperiencePanel: View {
    let data: ExperienceDetailView.ContentData

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                ExperienceMediaView(media: data.media, accentColor: data.accentColor)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [data.accentColor.opacity(0.8), .white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blendMode(.screen)
                    }

                VStack(alignment: .leading, spacing: 18) {
                    badgesSection

                    if let highlight = data.highlight {
                        Text(highlight)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineSpacing(4)
                    }

                    if let secondary = data.secondary {
                        Text(secondary)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    coordinatePreview
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
                .modifier(Theme.neonGlow(data.accentColor))

                actionsBar
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text(data.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let subtitle = data.subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
    }

    private var badgesSection: some View {
        HStack(spacing: 10) {
            ForEach(data.badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(data.accentColor.opacity(0.22))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(data.accentColor.opacity(0.55), lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
        }
    }

    private var coordinatePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Map Preview")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            Map(initialPosition: .region(data.mapRegion))
                .disabled(true)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private var actionsBar: some View {
        HStack(spacing: 16) {
            Button {
                // hook up soon
            } label: {
                Label(data.primaryActionTitle, systemImage: data.primaryActionSymbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(color: data.accentColor))

            Button {
                // hook up soon
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3.bold())
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(NeonIconButtonStyle(color: data.accentColor))
        }
    }
}

// MARK: - Compact reel pager

private struct CompactReelPager: View {
    let pager: ExperienceDetailView.ReelPager
    let selection: Binding<UUID>

    var body: some View {
        TabView(selection: selection) {
            ForEach(pager.items) { item in
                CompactRealCard(real: item.real, user: item.user)
                    .padding(.horizontal, 8)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

private struct CompactRealCard: View {
    let real: RealPost
    let user: User?

    var body: some View {
        HStack(spacing: 16) {
            mediaPreview

            VStack(alignment: .leading, spacing: 10) {
                header

                Text(previewDescription)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                metricsRow
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.neonPrimary.opacity(0.2), Color.black.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(user?.handle ?? "Unknown user")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(real.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var previewDescription: String {
        if let message = trimmedMessage, message.isEmpty == false {
            if case .none = real.media {
                let base = "Radius \(Int(real.radiusMeters))m · \(real.visibility.displayName)"
                return "Shared a note · \(base)"
            }
            return message
        }

        let base = "Radius \(Int(real.radiusMeters))m · \(real.visibility.displayName)"
        switch real.media {
        case let .emoji(emoji):
            return "\(emoji) happening nearby"
        case .photo:
            return "Shared a photo · \(base)"
        case .video:
            return "Shared a video · \(base)"
        case .none:
            return base
        }
    }

    private var trimmedMessage: String? {
        real.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metricsPill(symbol: "heart.fill", text: formatCount(real.metrics.likeCount))
            metricsPill(symbol: "bubble.right.fill", text: formatCount(real.metrics.commentCount))
        }
    }

    private func metricsPill(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule(style: .continuous))
    }

    private var mediaPreview: some View {
        ZStack(alignment: .bottomLeading) {
            mediaContent

            avatarBadge
                .offset(x: 8, y: -8)
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch real.media {
        case let .photo(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.05), .black.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                case .empty:
                    ProgressView()
                case .failure:
                    previewFallback(symbol: "photo")
                @unknown default:
                    previewFallback(symbol: "photo")
                }
            }
        case let .video(_, poster):
            ZStack {
                if let poster {
                    AsyncImage(url: poster) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                                .overlay { Color.black.opacity(0.25) }
                        case .empty:
                            ProgressView()
                        case .failure:
                            previewFallback(symbol: "play.rectangle.fill")
                        @unknown default:
                            previewFallback(symbol: "play.rectangle.fill")
                        }
                    }
                } else {
                    previewFallback(symbol: "play.rectangle.fill")
                }

                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.neonPrimary)
                            .offset(x: 2)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }
        case let .emoji(emoji):
            ZStack {
                LinearGradient(
                    colors: [Theme.neonPrimary.opacity(0.85), Theme.neonAccent.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(emoji)
                    .font(.system(size: 54))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
        case .none:
            if let text = trimmedMessage, text.isEmpty == false {
                previewTextCard(text)
            } else {
                previewFallback(symbol: "sparkles")
            }
        }
    }

    private func previewFallback(symbol: String) -> some View {
        LinearGradient(
            colors: [Theme.neonPrimary.opacity(0.35), Color.black.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func previewTextCard(_ text: String) -> some View {
        LinearGradient(
            colors: [Theme.neonPrimary.opacity(0.28), Theme.neonAccent.opacity(0.22)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(12)
        }
    }

    private var avatarBadge: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.gray
                    default:
                        ProgressView()
                    }
                }
            } else {
                Text(user?.handle.prefix(2).uppercased() ?? "??")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.65), lineWidth: 1)
        }
        .background(
            Circle()
                .fill(Color.black.opacity(0.35))
                .blur(radius: 0.5)
        )
    }
}

// MARK: - Media

private struct ExperienceMediaView: View {
    let media: ExperienceMedia
    let accentColor: Color

    var body: some View {
        ZStack {
            switch media {
            case let .emoji(emoji):
                emojiView(emoji)
            case let .image(url):
                imageView(url)
            case let .video(_, poster):
                videoPreview(poster: poster)
            case let .text(text):
                textView(text)
            case let .symbol(symbol):
                placeholder(symbol: symbol)
            }
        }
    }

    private var placeholder: some View {
        placeholder(symbol: "sparkles")
    }

    private func placeholder(symbol: String) -> some View {
        placeholderBackground {
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .bold))
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

    private func emojiView(_ emoji: String) -> some View {
        VStack {
            Text(emoji)
                .font(.system(size: 92))
                .shadow(color: accentColor.opacity(0.8), radius: 16)
            Text("Live Drop")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [accentColor.opacity(0.45), .black.opacity(0.8)],
                center: .center,
                startRadius: 10,
                endRadius: 320
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
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private func videoPreview(poster: URL?) -> some View {
        ZStack {
            if let poster {
                AsyncImage(url: poster) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .overlay {
                                Color.black.opacity(0.25)
                            }
                    case .empty:
                        ProgressView()
                    case .failure:
                        placeholder(symbol: "play.rectangle.fill")
                    @unknown default:
                        placeholder(symbol: "play.rectangle.fill")
                    }
                }
            } else {
                placeholder(symbol: "play.rectangle.fill")
            }

            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(accentColor)
                        .offset(x: 4)
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        }
    }

    private func textView(_ text: String) -> some View {
        placeholderBackground {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
        } subtitle: {
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .lineSpacing(4)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
    }
}

private enum ExperienceMedia {
    case emoji(String)
    case image(URL)
    case video(url: URL, poster: URL?)
    case text(String)
    case symbol(String)
}

private extension ExperienceMedia {
    var previewText: String? {
        switch self {
        case let .text(text):
            return text
        case .emoji, .image, .video, .symbol:
            return nil
        }
    }
}

// MARK: - Button styles

private struct NeonButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .modifier(Theme.neonGlow(color))
    }
}

private struct NeonIconButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                Circle()
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .modifier(Theme.neonGlow(color))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Helpers

private extension RealPost.Visibility {
    var displayName: String {
        switch self {
        case .publicAll:
            return "Public"
        case .friendsOnly:
            return "Friends"
        case .anonymous:
            return "Anonymous"
        }
    }
}

private extension Array where Element == Int {
    var average: Double? {
        guard isEmpty == false else { return nil }
        let total = reduce(0, +)
        return Double(total) / Double(count)
    }
}

private extension Array where Element == Rating {
    var average: Double? {
        compactMap(\.score).average
    }
}

#if DEBUG
struct ExperienceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let items = PreviewData.sampleReals.map {
            ExperienceDetailView.ReelPager.Item(real: $0, user: PreviewData.user(for: $0.userId))
        }
        let pager = ExperienceDetailView.ReelPager(
            items: items,
            initialId: items.first!.id
        )
        ExperienceDetailView(
            reelPager: pager,
            selection: .constant(items.first!.id),
            isExpanded: false
        )
        .preferredColorScheme(.dark)

        ExperienceDetailView(ratedPOI: PreviewData.sampleRatedPOIs[0], isExpanded: true)
            .preferredColorScheme(.dark)
    }
}
#endif

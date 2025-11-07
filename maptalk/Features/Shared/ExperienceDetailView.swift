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
        let galleryItems: [MediaDisplayItem]
        let friendLikes: [FriendEngagement]
        let friendComments: [FriendEngagement]
        let friendRatings: [FriendEngagement]
        let accentColor: Color
        let backgroundGradient: [Color]
        let mapRegion: MKCoordinateRegion
        let primaryActionTitle: String
        let primaryActionSymbol: String
    }

    private let poi: RatedPOI?
    private let reelContext: ReelContext?
    private let isExpanded: Bool
    private let userProvider: (UUID) -> User?

    init(ratedPOI: RatedPOI, isExpanded: Bool, userProvider: @escaping (UUID) -> User? = { _ in nil }) {
        self.poi = ratedPOI
        self.reelContext = nil
        self.isExpanded = isExpanded
        self.userProvider = userProvider
    }

    init(
        reelPager: ReelPager,
        selection: Binding<UUID>,
        isExpanded: Bool,
        userProvider: @escaping (UUID) -> User? = { _ in nil }
    ) {
        self.poi = nil
        self.reelContext = ReelContext(pager: reelPager, selection: selection)
        self.isExpanded = isExpanded
        self.userProvider = userProvider
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

// MARK: - Media display helpers

private struct MediaDisplayItem: Identifiable, Hashable {
    enum Content: Hashable {
        case photo(URL)
        case video(url: URL, poster: URL?)
        case emoji(String)
        case text(String)
        case symbol(String)
    }

    let id: UUID
    let content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }
}

private struct FriendEngagement: Identifiable {
    enum Kind {
        case like
        case comment
        case rating
    }

    let id: UUID
    let kind: Kind
    let user: User?
    let message: String
    let badge: String?
    let timestamp: Date?
}

private extension MediaDisplayItem {
    var previewText: String? {
        switch content {
        case let .text(text):
            return text
        default:
            return nil
        }
    }
}

private func firstEmoji(in attachments: [RealPost.Attachment]) -> String? {
    attachments.compactMap { attachment -> String? in
        if case let .emoji(emoji) = attachment.kind {
            return emoji
        }
        return nil
    }.first
}

private func mediaCounts(for attachments: [RealPost.Attachment]) -> (photos: Int, videos: Int, emojis: Int) {
    attachments.reduce(into: (0, 0, 0)) { result, attachment in
        switch attachment.kind {
        case .photo:
            result.0 += 1
        case .video:
            result.1 += 1
        case .emoji:
            result.2 += 1
        }
    }
}

private func mediaDescriptor(for real: RealPost) -> String? {
    let counts = mediaCounts(for: real.attachments)
    var segments: [String] = []

    if counts.photos > 0 {
        segments.append(counts.photos == 1 ? "1 photo" : "\(counts.photos) photos")
    }
    if counts.videos > 0 {
        segments.append(counts.videos == 1 ? "1 video" : "\(counts.videos) videos")
    }
    if counts.emojis > 0 {
        segments.append(counts.emojis == 1 ? "1 emoji" : "\(counts.emojis) emoji")
    }

    if segments.isEmpty {
        if let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           message.isEmpty == false {
            return "Shared a note"
        }
        return nil
    }

    return "Shared \(segments.joined(separator: " · "))"
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
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                ExperiencePanel(data: data)
            }
        }
    }

    private func collapsedPreview(using data: ContentData) -> some View {
        VStack(spacing: 16) {
            if let context = reelContext {
                CompactReelPager(
                    pager: context.pager,
                    selection: context.selection
                )
                .padding(.top, 0)
                .frame(height: 240)
                .padding(.horizontal, -4)
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

                    let previewHighlight = data.highlight ?? data.galleryItems.first(where: { $0.previewText != nil })?.previewText
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
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
            let gallery = galleryItems(for: real)
            let friendLikes = real.likes.compactMap { userId -> FriendEngagement? in
                guard let user = userProvider(userId) else { return nil }
                return FriendEngagement(
                    id: userId,
                    kind: .like,
                    user: user,
                    message: "Reacted to this drop.",
                    badge: nil,
                    timestamp: nil
                )
            }
            let friendComments = real.comments.compactMap { comment -> FriendEngagement? in
                guard let user = userProvider(comment.userId) else { return nil }
                return FriendEngagement(
                    id: comment.id,
                    kind: .comment,
                    user: user,
                    message: comment.text,
                    badge: nil,
                    timestamp: comment.createdAt
                )
            }
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
                galleryItems: gallery,
                friendLikes: friendLikes,
                friendComments: friendComments,
                friendRatings: [],
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
            let gallery = galleryItems(for: rated)
            let friendRatings = rated.ratings.compactMap { rating -> FriendEngagement? in
                guard let user = userProvider(rating.userId) else { return nil }
                var message = "Left a rating"
                if let text = rating.text, text.isEmpty == false {
                    message = text
                } else if let score = rating.score {
                    message = "Rated \(score)/5"
                } else if let emoji = rating.emoji {
                    message = "Reacted with \(emoji)"
                }
                let badge: String?
                if let emoji = rating.emoji {
                    badge = emoji
                } else if let score = rating.score {
                    badge = "\(score)★"
                } else {
                    badge = nil
                }
                return FriendEngagement(
                    id: rating.id,
                    kind: .rating,
                    user: user,
                    message: message,
                    badge: badge,
                    timestamp: rating.createdAt
                )
            }
            return ContentData(
                title: rated.poi.name,
                subtitle: rated.poi.category.displayName,
                badges: ["\(rated.ratings.count) Ratings"],
                highlight: highlight,
                secondary: secondary,
                galleryItems: gallery,
                friendLikes: [],
                friendComments: [],
                friendRatings: friendRatings,
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

    func galleryItems(for real: RealPost) -> [MediaDisplayItem] {
        var items: [MediaDisplayItem] = real.attachments.map { attachment in
            switch attachment.kind {
            case let .photo(url):
                return MediaDisplayItem(id: attachment.id, content: .photo(url))
            case let .video(url, poster):
                return MediaDisplayItem(id: attachment.id, content: .video(url: url, poster: poster))
            case let .emoji(emoji):
                return MediaDisplayItem(id: attachment.id, content: .emoji(emoji))
            }
        }

        if let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           message.isEmpty == false {
            items.append(MediaDisplayItem(content: .text(message)))
        }

        if items.isEmpty {
            return [MediaDisplayItem(content: .symbol("sparkles"))]
        }

        return items
    }

    func highlightText(for real: RealPost, message: String?) -> String? {
        if let message, message.isEmpty == false {
            return message
        }
        if let emoji = firstEmoji(in: real.attachments) {
            return "\(emoji) Live moment happening here."
        }
        return nil
    }

    func secondaryText(for real: RealPost) -> String {
        let base = "Visibility • \(real.visibility.displayName)"
        guard let descriptor = mediaDescriptor(for: real) else {
            return base
        }
        return "\(base) · \(descriptor)"
    }

    func galleryItems(for ratedPOI: RatedPOI) -> [MediaDisplayItem] {
        if let emoji = ratedPOI.ratings.compactMap(\.emoji).first {
            return [MediaDisplayItem(content: .emoji(emoji))]
        }
        return [MediaDisplayItem(content: .symbol(ratedPOI.poi.category.symbolName))]
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

                ExperienceMediaGallery(items: data.galleryItems, accentColor: data.accentColor)
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

                    if data.friendLikes.isEmpty == false {
                        FriendEngagementList(title: "Friend Likes", entries: data.friendLikes)
                    }

                    if data.friendComments.isEmpty == false {
                        FriendEngagementList(title: "Friend Comments", entries: data.friendComments)
                    }

                    if data.friendRatings.isEmpty == false {
                        FriendEngagementList(title: "Friend Ratings", entries: data.friendRatings)
                    }
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
                CompactRealCard(real: item.real, user: item.user, style: .collapsed)
                    .padding(.horizontal, 8)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

private struct CompactRealCard: View {
    enum Style {
        case standard
        case collapsed
    }

    let real: RealPost
    let user: User?
    let style: Style

    init(real: RealPost, user: User?, style: Style = .standard) {
        self.real = real
        self.user = user
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            avatarView
                .alignmentGuide(.top) { $0[.top] }
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 12) {
                userNameRow

                contentText

                if hasMedia {
                    mediaRow
                }

                footerRow
            }
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
    }

    private var horizontalPadding: CGFloat {
        style == .collapsed ? 16 : 24
    }

    private var verticalPadding: CGFloat {
        style == .collapsed ? 12 : 22
    }

    private var headerTopPadding: CGFloat { 40 }

    private var avatarSize: CGFloat {
        style == .collapsed ? 34 : 40
    }

    private var mediaHeight: CGFloat {
        style == .collapsed ? 88 : 120
    }

    private var textLineLimit: Int {
        style == .collapsed ? 2 : 3
    }

    private var userNameRow: some View {
        Text(user?.handle ?? "Unknown user")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatarView: some View {
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
                Color.gray.opacity(0.4)
                    .overlay {
                        Text(user?.handle.prefix(2).uppercased() ?? "??")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    private var contentText: some View {
        Text(trimmedMessage ?? fallbackDescription)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(textLineLimit)
    }

    private var trimmedMessage: String? {
        let text = real.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private var fallbackDescription: String {
        if let descriptor = mediaDescriptor(for: real) {
            return descriptor
        }
        return "\(real.visibility.displayName) drop"
    }

    private var hasMedia: Bool {
        real.attachments.isEmpty == false
    }

    private var collageSources: [RealPost.Attachment?] {
        if hasMedia {
            return Array(real.attachments.prefix(3)).map { Optional($0) }
        }
        return []
    }

    @ViewBuilder
    private func collageTile(for attachment: RealPost.Attachment?) -> some View {
        if let attachment {
            attachmentThumbnail(for: attachment)
        } else if let text = trimmedMessage {
            previewTextCard(text)
        } else {
            previewFallback(symbol: "sparkles")
        }
    }

    private var mediaRow: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let totalSpacing = spacing * 2
            let calculatedWidth = max((proxy.size.width - totalSpacing) / 3, 0)
            let size = min(calculatedWidth, mediaHeight)

            HStack(spacing: spacing) {
                ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                    collageTile(for: element.element)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: mediaHeight)
    }

    private var footerRow: some View {
        HStack(spacing: 14) {
            Text(real.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

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


    @ViewBuilder
    private func attachmentThumbnail(for attachment: RealPost.Attachment) -> some View {
        switch attachment.kind {
        case let .photo(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    ProgressView()
                case .failure:
                    previewFallback(symbol: "photo")
                @unknown default:
                    previewFallback(symbol: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
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
                        case .empty:
                            ProgressView()
                        case .failure:
                            previewFallback(symbol: "play.rectangle.fill")
                        @unknown default:
                            previewFallback(symbol: "play.rectangle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay { Color.black.opacity(0.25) }
                } else {
                    previewFallback(symbol: "play.rectangle.fill")
                }

                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.neonPrimary)
                            .offset(x: 1.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            }
        case let .emoji(emoji):
            LinearGradient(
                colors: [Theme.neonPrimary.opacity(0.85), Theme.neonAccent.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Text(emoji)
                    .font(.system(size: 48))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
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

private struct FriendEngagementList: View {
    let title: String
    let entries: [FriendEngagement]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))

            VStack(spacing: 10) {
                ForEach(entries) { entry in
                    FriendEngagementRow(entry: entry)
                }
            }
        }
    }
}

private struct FriendEngagementRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestampText {
                        Text(timestampText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }

            if let badgeText = entry.badge {
                Text(badgeText)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule(style: .continuous))
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var avatar: some View {
        ZStack {
            if let url = entry.user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .offset(x: 6, y: 6)
        }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.3))
    }

    private var initials: String {
        guard let handle = entry.user?.handle else { return "??" }
        return String(handle.prefix(2)).uppercased()
    }

    private var iconName: String {
        switch entry.kind {
        case .like:
            return "heart.fill"
        case .comment:
            return "text.bubble.fill"
        case .rating:
            return "star.fill"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .like:
            return Theme.neonPrimary
        case .comment:
            return .white
        case .rating:
            return Theme.neonAccent
        }
    }

    private var timestampText: String? {
        entry.timestamp?.formatted(.relative(presentation: .named))
    }
}

// MARK: - Media

private struct ExperienceMediaGallery: View {
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
                MediaCardView(
                    item: MediaDisplayItem(content: .symbol("sparkles")),
                    accentColor: accentColor,
                    mode: .card
                )
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
        if items.count > 1 {
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
        let counts = mediaCounts(for: items)
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
}

private struct MediaLightbox: View {
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
        let counts = mediaCounts(for: items)
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

private struct MediaCardView: View {
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
            case let .video(_, poster):
                videoView(poster: poster)
            case let .emoji(emoji):
                emojiView(emoji)
            case let .text(text):
                textView(text)
            case let .symbol(symbol):
                placeholder(symbol: symbol)
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

    private func videoView(poster: URL?) -> some View {
        ZStack {
            if let poster {
                AsyncImage(url: poster) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .overlay { Color.black.opacity(0.28) }
                    case .empty:
                        ProgressView()
                    case .failure:
                        placeholder(symbol: "play.rectangle.fill")
                    @unknown default:
                        placeholder(symbol: "play.rectangle.fill")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                placeholder(symbol: "play.rectangle.fill")
            }

            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: mode == .lightbox ? 72 : 58, height: mode == .lightbox ? 72 : 58)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: mode == .lightbox ? 28 : 22, weight: .bold))
                        .foregroundStyle(accentColor)
                        .offset(x: 3)
                }
                .shadow(color: .black.opacity(0.45), radius: mode == .lightbox ? 14 : 10, y: 6)
        }
    }

    private func textView(_ text: String) -> some View {
        placeholderBackground {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: mode == .lightbox ? 48 : 36, weight: .bold))
                .foregroundStyle(.white)
        } subtitle: {
            Text(text)
                .font(mode == .lightbox ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .lineSpacing(4)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 12)
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

private func mediaCounts(for items: [MediaDisplayItem]) -> (photos: Int, videos: Int, emojis: Int) {
    items.reduce(into: (0, 0, 0)) { result, item in
        switch item.content {
        case .photo:
            result.0 += 1
        case .video:
            result.1 += 1
        case .emoji:
            result.2 += 1
        case .text, .symbol:
            break
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
            isExpanded: false,
            userProvider: PreviewData.user(for:)
        )
        .preferredColorScheme(.dark)

        ExperienceDetailView(
            ratedPOI: PreviewData.sampleRatedPOIs[0],
            isExpanded: true,
            userProvider: PreviewData.user(for:)
        )
            .preferredColorScheme(.dark)
    }
}
#endif

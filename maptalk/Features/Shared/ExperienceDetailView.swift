import AVKit
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
        let hero: HeroSectionModel?
        let badges: [String]
        let story: StorySectionModel?
        let highlights: HighlightsSectionModel
        let engagement: EngagementSectionModel
        let poiInfo: POIInfoModel?
        let poiStats: POIStatsModel?
        let accentColor: Color
        let backgroundGradient: [Color]
    }

    fileprivate struct HeroSectionModel {
        let real: RealPost
        let user: User?
        let displayNameOverride: String?
        let avatarCategory: POICategory?
        let suppressContent: Bool
    }

    fileprivate struct StorySectionModel {
        let galleryItems: [MediaDisplayItem]
    }

    fileprivate struct HighlightsSectionModel {
        let title: String
        let subtitle: String?
        let highlight: String?
        let secondary: String?
    }

    fileprivate struct EndorsementBadge: Identifiable {
        let id = UUID()
        let iconName: String
        let count: Int
        let tint: Color
    }

    fileprivate struct POIInfoModel {
        let name: String
        let category: POICategory
        let endorsementBadges: [EndorsementBadge]
    }

    fileprivate struct POIStatsModel {
        let checkIns: Int
        let comments: Int
        let favorites: Int
        let endorsements: RatedPOI.EndorsementSummary
    }

    fileprivate struct POIStoryContributor: Identifiable {
        struct Item: Identifiable {
            let id: UUID
            let media: MediaDisplayItem
            let timestamp: Date
        }

        let id: UUID
        let userId: UUID
        let user: User?
        let items: [Item]
        let mostRecent: Date
    }

    fileprivate struct EngagementSectionModel {
        let friendLikesIconName: String
        let friendLikesTitle: String
        let friendLikes: [FriendEngagement]
        let friendCommentsTitle: String
        let friendComments: [FriendEngagement]
        let friendRatingsTitle: String
        let friendRatings: [FriendEngagement]
        let storyContributors: [POIStoryContributor]

        var hasContent: Bool {
            friendLikes.isEmpty == false ||
                friendComments.isEmpty == false ||
                friendRatings.isEmpty == false
        }
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
    let replies: [FriendEngagement]
    let endorsement: RatedPOI.Endorsement?
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
                .padding(.horizontal, 0)
            } else if let hero = data.hero {
                HeroSection(model: hero, style: .collapsed)
            } else if let poiInfo = data.poiInfo {
                POICollapsedHero(
                    info: poiInfo,
                    stats: data.poiStats,
                    accentColor: data.accentColor
                )
            } else {
                VStack(spacing: 12) {
                    SummarySection(model: data.highlights, accentColor: data.accentColor)

                    if let stats = data.poiStats {
                        POIHeroStatsRow(model: stats)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.horizontal, -ExperienceSheetLayout.horizontalInset)
        .padding(.top, 12)
        .padding(.bottom, -8)
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
            let friendLikes = real.likes.compactMap { userId -> FriendEngagement? in
                guard let user = userProvider(userId) else { return nil }
                return FriendEngagement(
                    id: userId,
                    kind: .like,
                    user: user,
                    message: "Reacted to this drop.",
                    badge: nil,
                    timestamp: nil,
                    replies: [],
                    endorsement: nil
                )
            }
            let friendComments = real.comments.compactMap { comment -> FriendEngagement? in
                guard let user = userProvider(comment.userId) else { return nil }
                let replies = comment.replies.compactMap { reply -> FriendEngagement? in
                    guard let replyUser = userProvider(reply.userId) else { return nil }
                    return FriendEngagement(
                        id: reply.id,
                        kind: .comment,
                        user: replyUser,
                        message: reply.text,
                        badge: nil,
                        timestamp: reply.createdAt,
                        replies: [],
                        endorsement: nil
                    )
                }
                return FriendEngagement(
                    id: comment.id,
                    kind: .comment,
                    user: user,
                    message: comment.text,
                    badge: nil,
                    timestamp: comment.createdAt,
                    replies: replies,
                    endorsement: nil
                )
            }
            let hero = HeroSectionModel(
                real: real,
                user: user,
                displayNameOverride: nil,
                avatarCategory: nil,
                suppressContent: false
            )
            return ContentData(
                hero: hero,
                badges: badges,
                story: nil,
                highlights: HighlightsSectionModel(
                    title: user?.handle ?? "Shared Real",
                    subtitle: "Posted \(real.createdAt.formatted(.relative(presentation: .named)))",
                    highlight: highlight,
                    secondary: secondary
                ),
                engagement: EngagementSectionModel(
                    friendLikesIconName: "heart",
                    friendLikesTitle: "Friend Likes",
                    friendLikes: friendLikes,
                    friendCommentsTitle: "Friend Comments",
                    friendComments: friendComments,
                    friendRatingsTitle: "Friend Ratings",
                    friendRatings: [],
                    storyContributors: []
                ),
                poiInfo: nil,
                poiStats: nil,
                accentColor: accent,
                backgroundGradient: gradient
            )
        case let .poi(rated):
            let accent = rated.poi.category.accentColor
            let friendCheckIns = checkInEngagements(for: rated)
            let friendComments = poiCommentEngagements(for: rated)
            let endorsementBadges = poiEndorsementBadges(for: rated)
            let tagBadges = poiBadgeStrings(for: rated)
            let stories = poiStoryContributors(for: rated)
            return ContentData(
                hero: nil,
                badges: tagBadges,
                story: nil,
                highlights: HighlightsSectionModel(
                    title: "",
                    subtitle: nil,
                    highlight: nil,
                    secondary: nil
                ),
                engagement: EngagementSectionModel(
                    friendLikesIconName: "shoeprints.fill",
                    friendLikesTitle: "Friend Check-ins",
                    friendLikes: friendCheckIns,
                    friendCommentsTitle: "Friend Notes",
                    friendComments: friendComments,
                    friendRatingsTitle: "Endorsements",
                    friendRatings: [],
                    storyContributors: stories
                ),
                poiInfo: POIInfoModel(
                    name: rated.poi.name,
                    category: rated.poi.category,
                    endorsementBadges: endorsementBadges
                ),
                poiStats: POIStatsModel(
                    checkIns: rated.checkIns.count,
                    comments: rated.comments.count,
                    favorites: rated.favoritesCount,
                    endorsements: rated.endorsements
                ),
                accentColor: accent,
                backgroundGradient: [Color.black, accent.opacity(0.25)]
            )
        }
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
        let mapped = ratedPOI.media.map(mediaDisplayItem)
        if mapped.isEmpty {
            return [MediaDisplayItem(content: .symbol(ratedPOI.poi.category.symbolName))]
        }
        return mapped
    }

    func mediaDisplayItem(_ media: RatedPOI.Media) -> MediaDisplayItem {
        switch media.kind {
        case let .photo(url):
            return MediaDisplayItem(content: .photo(url))
        case let .video(url, poster):
            return MediaDisplayItem(content: .video(url: url, poster: poster))
        case let .text(text):
            return MediaDisplayItem(content: .text(text))
        case let .symbol(name):
            return MediaDisplayItem(content: .symbol(name))
        }
    }

    func poiBadgeStrings(for ratedPOI: RatedPOI) -> [String] {
        ratedPOI.tags.map { "\($0.tag.emoji) \($0.tag.displayName) · \($0.count)" }
    }

    func poiEndorsementBadges(for ratedPOI: RatedPOI) -> [EndorsementBadge] {
        let summary = ratedPOI.endorsements
        let entries: [(RatedPOI.Endorsement, Int)] = [
            (.hype, summary.hype),
            (.solid, summary.solid),
            (.meh, summary.meh),
            (.questionable, summary.questionable)
        ]
        return entries.compactMap { endorsement, count in
            guard count > 0 else { return nil }
            return EndorsementBadge(
                iconName: endorsementIconName(for: endorsement),
                count: count,
                tint: endorsementColor(for: endorsement)
            )
        }
    }

    func poiStoryContributors(for ratedPOI: RatedPOI) -> [POIStoryContributor] {
        let mediaCheckIns = ratedPOI.checkIns.filter { checkIn in
            checkIn.media.contains { media in
                if case .photo = media.kind { return true }
                return false
            }
        }
        guard mediaCheckIns.isEmpty == false else { return [] }

        let grouped = Dictionary(grouping: mediaCheckIns, by: { $0.userId })
        let contributors: [POIStoryContributor] = grouped.compactMap { userId, entries in
            let sortedEntries = entries.sorted { $0.createdAt < $1.createdAt }
            let items: [POIStoryContributor.Item] = sortedEntries.flatMap { checkIn in
                checkIn.media.compactMap { media -> POIStoryContributor.Item? in
                    guard case .photo = media.kind else { return nil }
                    return POIStoryContributor.Item(
                        id: UUID(),
                        media: mediaDisplayItem(media),
                        timestamp: checkIn.createdAt
                    )
                }
            }
            guard items.isEmpty == false else { return nil }
            let mostRecent = sortedEntries.map(\.createdAt).max() ?? Date()
            return POIStoryContributor(
                id: userId,
                userId: userId,
                user: userProvider(userId),
                items: items,
                mostRecent: mostRecent
            )
        }

        return contributors.sorted { $0.mostRecent > $1.mostRecent }
    }

    func checkInEngagements(for ratedPOI: RatedPOI) -> [FriendEngagement] {
        ratedPOI.checkIns.map { checkIn in
            let endorsement = checkIn.endorsement
            let kind: FriendEngagement.Kind = endorsement == nil ? .like : .rating
            return FriendEngagement(
                id: checkIn.id,
                kind: kind,
                user: userProvider(checkIn.userId),
                message: endorsementMessage(for: endorsement),
                badge: nil,
                timestamp: checkIn.createdAt,
                replies: [],
                endorsement: checkIn.endorsement
            )
        }
    }

    func poiCommentEngagements(for ratedPOI: RatedPOI) -> [FriendEngagement] {
        ratedPOI.comments.map { comment in
            FriendEngagement(
                id: comment.id,
                kind: .comment,
                user: userProvider(comment.userId),
                message: commentMessage(for: comment.content),
                badge: nil,
                timestamp: comment.createdAt,
                replies: [],
                endorsement: nil
            )
        }
    }

    func commentMessage(for content: RatedPOI.Comment.Content) -> String {
        switch content {
        case let .text(text):
            return text
        case .photo:
            return "Shared a photo"
        case .video:
            return "Shared a video"
        }
    }

    func endorsementMessage(for endorsement: RatedPOI.Endorsement?) -> String {
        guard let endorsement else { return "Checked in" }
        switch endorsement {
        case .hype:
            return "Loved this spot"
        case .solid:
            return "Solid vibes"
        case .meh:
            return "Said it's meh"
        case .questionable:
            return "Questioned this place"
        }
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

private func endorsementIconName(for endorsement: RatedPOI.Endorsement) -> String {
    switch endorsement {
    case .hype:
        return "heart.fill"
    case .solid:
        return "hand.thumbsup.fill"
    case .meh:
        return "face.smiling.fill"
    case .questionable:
        return "questionmark.circle.fill"
    }
}

private func endorsementColor(for endorsement: RatedPOI.Endorsement) -> Color {
    switch endorsement {
    case .hype:
        return Theme.neonPrimary
    case .solid:
        return Theme.neonAccent
    case .meh:
        return Color.yellow.opacity(0.9)
    case .questionable:
        return Theme.neonWarning
    }
}

private enum ExperienceSheetLayout {
    static let horizontalInset: CGFloat = 16
    static let panelHorizontalPadding: CGFloat = 0
    static let detailContentInset: CGFloat = 16
    static let engagementHorizontalInset: CGFloat = 22
}

// MARK: - Experience panel

private struct ExperiencePanel: View {
    let data: ExperienceDetailView.ContentData

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if let hero = data.hero {
                    HeroSection(model: hero, style: .standard)
                        .padding(.horizontal, 4)

                    if data.engagement.hasContent {
                        EngagementSection(model: data.engagement, accentColor: data.accentColor)
                            .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                    }
                } else {
                    defaultExperienceContent
                }
            }
            .padding(.horizontal, ExperienceSheetLayout.panelHorizontalPadding)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
        .padding(.horizontal, -ExperienceSheetLayout.horizontalInset)
    }

    @ViewBuilder
    private var defaultExperienceContent: some View {
        if let poiInfo = data.poiInfo {
            VStack(spacing: 18) {
                POIExpandedHero(
                    info: poiInfo,
                    stats: data.poiStats,
                    accentColor: data.accentColor
                )
                .padding(.horizontal, ExperienceSheetLayout.detailContentInset)

                if data.badges.isEmpty == false {
                    POITagList(badges: data.badges, accentColor: data.accentColor)
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }

                if data.engagement.hasContent {
                    EngagementSection(model: data.engagement, accentColor: data.accentColor)
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }
            }
        } else {
            VStack(spacing: 24) {
                SummarySection(model: data.highlights, accentColor: data.accentColor)
                    .padding(.horizontal, 12)

                if let story = data.story {
                    ExperienceMediaGallery(items: story.galleryItems, accentColor: data.accentColor)
                        .frame(height: ExperienceMediaGalleryLayout.height(for: story.galleryItems))
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
                }

                if data.engagement.hasContent {
                    EngagementSection(model: data.engagement, accentColor: data.accentColor)
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }
            }
        }
    }

}

private struct POITagList: View {
    let badges: [String]
    let accentColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accentColor.opacity(0.22))
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(accentColor.opacity(0.55), lineWidth: 1)
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct POICollapsedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            POIAvatar(category: info.category, accentColor: accentColor, size: POIHeroLayout.collapsedAvatarSize)
                .alignmentGuide(.top) { $0[.top] }
                .padding(.trailing, POIHeroLayout.avatarSpacing)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text(info.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(info.endorsementBadges) { badge in
                            POIBadgeSummaryPill(badge: badge)
                        }
                    }
                }

                if let stats {
                    POIHeroStatsRow(model: stats)
                }
            }
        }
        .padding(.top, POIHeroLayout.headerTopPadding)
        .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
        .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
    }
}

private struct POIExpandedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            POIAvatar(category: info.category, accentColor: accentColor, size: POIHeroLayout.collapsedAvatarSize)
                .alignmentGuide(.top) { $0[.top] }
                .padding(.trailing, POIHeroLayout.avatarSpacing)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text(info.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(info.endorsementBadges) { badge in
                            POIBadgeSummaryPill(badge: badge)
                        }
                    }
                }

                if let stats {
                    POIHeroStatsRow(model: stats)
                }
            }
        }
        .padding(.top, POIHeroLayout.headerTopPadding)
        .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
        .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
    }
}

private struct POIHeroStatsRow: View {
    let model: ExperienceDetailView.POIStatsModel

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            POIStatPill(icon: "shoeprints.fill", value: model.checkIns)
            POIStatPill(icon: "text.bubble.fill", value: model.comments)
            POIStatPill(icon: "star.fill", value: model.favorites)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }
}

private struct POIStatPill: View {
    let icon: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(formatCount(value))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule(style: .continuous))
    }
}

private struct POIBadgeSummaryPill: View {
    let badge: ExperienceDetailView.EndorsementBadge

    var body: some View {
        HStack(spacing: 4) {
            iconView
                .font(.caption.weight(.bold))
            Text(formatCount(badge.count))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var iconView: some View {
        if badge.iconName == "heart.fill" {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.neonPrimary.opacity(0.65),
                                Theme.neonAccent.opacity(0.35),
                                Color.pink.opacity(0.15),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 26
                        )
                    )
                    .frame(width: 24, height: 24)
                    .blur(radius: 0.8)
                    .overlay {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [Theme.neonPrimary, .white, Theme.neonAccent, Color.pink],
                                    center: .center
                                ),
                                lineWidth: 1.2
                            )
                            .blur(radius: 0.6)
                    }

                Image(systemName: badge.iconName)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.neonPrimary, Color.pink, Theme.neonAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pink.opacity(0.7), radius: 8, y: 1)

                let sparkleOffsets: [CGPoint] = [
                    CGPoint(x: -9, y: -9),
                    CGPoint(x: 8, y: -7),
                    CGPoint(x: 0, y: 10)
                ]
                ForEach(Array(sparkleOffsets.enumerated()), id: \.offset) { item in
                    Image(systemName: "sparkles")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .offset(x: item.element.x, y: item.element.y)
                        .opacity(0.8)
                }
            }
        } else {
            Image(systemName: badge.iconName)
                .foregroundStyle(badge.tint)
        }
    }
}

private struct EndorsementBadgeIcon: View {
    let endorsement: RatedPOI.Endorsement
    var size: CGFloat = 18

    var body: some View {
        if endorsement == .hype {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.neonPrimary.opacity(0.7),
                                Theme.neonAccent.opacity(0.4),
                                Color.pink.opacity(0.2),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: size * 1.2
                        )
                    )
                    .frame(width: size * 1.2, height: size * 1.2)
                    .blur(radius: 0.6)
                    .overlay {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Theme.neonPrimary,
                                        .white,
                                        Theme.neonAccent,
                                        Color.pink
                                    ],
                                    center: .center
                                ),
                                lineWidth: 1
                            )
                            .blur(radius: 0.4)
                    }

                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.6, weight: .heavy))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.neonPrimary, Color.pink, Theme.neonAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pink.opacity(0.7), radius: 4, y: 1)

                let sparkleOffsets: [CGPoint] = [
                    CGPoint(x: -size * 0.45, y: -size * 0.45),
                    CGPoint(x: size * 0.45, y: -size * 0.35),
                    CGPoint(x: 0, y: size * 0.5)
                ]
                ForEach(Array(sparkleOffsets.enumerated()), id: \.offset) { item in
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.25))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .offset(x: item.element.x, y: item.element.y)
                        .opacity(0.85)
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
        } else {
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: endorsementIconName(for: endorsement))
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(endorsementColor(for: endorsement))
                }
        }
    }
}

private struct POIAvatar: View {
    let category: POICategory
    let accentColor: Color
    var size: CGFloat = 54

    var body: some View {
        let gradient = category.markerGradientColors
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)

            Image(systemName: category.symbolName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
    }
}

private enum POIHeroLayout {
    static let headerTopPadding: CGFloat = 40
    static let collapsedHorizontalPadding: CGFloat = 32
    static let collapsedVerticalPadding: CGFloat = 12
    static let standardHorizontalPadding: CGFloat = 24
    static let standardVerticalPadding: CGFloat = 22
    static let collapsedAvatarSize: CGFloat = 34
    static let standardAvatarSize: CGFloat = 40
    static let avatarSpacing: CGFloat = 10
}

private struct SummarySection: View {
    let model: ExperienceDetailView.HighlightsSectionModel
    let accentColor: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(model.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            if let highlight = model.highlight {
                Text(highlight)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(accentColor.opacity(0.2), in: Capsule(style: .continuous))
            }
        }
    }
}

private struct HighlightsSection: View {
    let model: ExperienceDetailView.HighlightsSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let highlight = model.highlight {
                Text(highlight)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
            }

            if let secondary = model.secondary {
                Text(secondary)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct EngagementSection: View {
    let model: ExperienceDetailView.EngagementSectionModel
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.friendLikes.isEmpty == false {
                LikesAvatarGrid(
                    entries: model.friendLikes,
                    iconName: model.friendLikesIconName,
                    storyContributors: model.storyContributors,
                    accentColor: accentColor
                )
            }

            if model.friendComments.isEmpty == false {
                CommentThreadList(entries: model.friendComments)
            }
        }
    }
}

private struct HeroSection: View {
    let model: ExperienceDetailView.HeroSectionModel
    let style: CompactRealCard.Style

    var body: some View {
        CompactRealCard(
            real: model.real,
            user: model.user,
            style: style,
            displayNameOverride: model.displayNameOverride,
            avatarCategory: model.avatarCategory,
            suppressContent: model.suppressContent
        )
    }
}

// MARK: - Compact reel pager

private struct CompactReelPager: View {
    let pager: ExperienceDetailView.ReelPager
    let selection: Binding<UUID>

    var body: some View {
        TabView(selection: selection) {
            ForEach(pager.items) { item in
                HeroSection(
                    model: ExperienceDetailView.HeroSectionModel(
                        real: item.real,
                        user: item.user,
                        displayNameOverride: nil,
                        avatarCategory: nil,
                        suppressContent: false
                    ),
                    style: .collapsed
                )
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
    let displayNameOverride: String?
    let avatarCategory: POICategory?
    let suppressContent: Bool

    @State private var isLightboxPresented = false
    @State private var lightboxSelection: UUID

    init(
        real: RealPost,
        user: User?,
        style: Style = .standard,
        displayNameOverride: String? = nil,
        avatarCategory: POICategory? = nil,
        suppressContent: Bool = false
    ) {
        self.real = real
        self.user = user
        self.style = style
        self.displayNameOverride = displayNameOverride
        self.avatarCategory = avatarCategory
        self.suppressContent = suppressContent
        _lightboxSelection = State(initialValue: real.attachments.first?.id ?? UUID())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            avatarView
                .alignmentGuide(.top) { $0[.top] }
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 12) {
                userNameRow

                if suppressContent == false {
                    contentText

                    if hasMedia {
                        mediaRow
                    }
                }

                footerRow
            }
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
        .fullScreenCover(isPresented: $isLightboxPresented) {
            if lightboxItems.isEmpty == false {
                MediaLightbox(
                    items: lightboxItems,
                    selection: $lightboxSelection,
                    accentColor: lightboxAccentColor,
                    isPresented: $isLightboxPresented
                )
            }
        }
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

    private var mediaSpacing: CGFloat { 10 }

    private var standardTileSize: CGFloat { 88 }

    private var lightboxItems: [MediaDisplayItem] {
        real.attachments.map { attachment in
            switch attachment.kind {
            case let .photo(url):
                return MediaDisplayItem(id: attachment.id, content: .photo(url))
            case let .video(url, poster):
                return MediaDisplayItem(id: attachment.id, content: .video(url: url, poster: poster))
            case let .emoji(emoji):
                return MediaDisplayItem(id: attachment.id, content: .emoji(emoji))
            }
        }
    }

    private var lightboxAccentColor: Color {
        switch real.visibility {
        case .publicAll:
            return Theme.neonPrimary
        case .friendsOnly:
            return Theme.neonAccent
        case .anonymous:
            return Theme.neonWarning
        }
    }

    private var maxVisibleMediaCount: Int {
        style == .collapsed ? 3 : 9
    }

    private var overflowCount: Int {
        max(0, real.attachments.count - maxVisibleMediaCount)
    }

    private var textLineLimit: Int {
        style == .collapsed ? 2 : 3
    }

    private var userNameRow: some View {
        Text(displayName)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatarView: some View {
        Group {
            if let category = avatarCategory {
                POICategoryAvatar(category: category, size: avatarSize)
            } else if let url = user?.avatarURL {
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
                        Text(displayInitials)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    private var displayName: String {
        displayNameOverride ?? user?.handle ?? "Unknown user"
    }

    private var displayInitials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "??" }
        return String(trimmed.prefix(2)).uppercased()
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
        guard hasMedia else { return [] }
        return Array(real.attachments.prefix(maxVisibleMediaCount)).map { Optional($0) }
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

    @ViewBuilder
    private var mediaRow: some View {
        if style == .collapsed {
            collapsedMediaStrip
        } else {
            standardMediaGrid
        }
    }

    private var collapsedMediaStrip: some View {
        GeometryReader { proxy in
            let totalSpacing = mediaSpacing * 2
            let calculatedWidth = max((proxy.size.width - totalSpacing) / 3, 0)
            let size = min(calculatedWidth, mediaHeight)

            HStack(spacing: mediaSpacing) {
                ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                    collageTile(for: element.element)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .trailing) {
                            collapsedOverflowOverlay(for: element.offset, tileSize: size)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleMediaTap(for: element.element)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: mediaHeight)
    }

    private var standardMediaGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(standardTileSize), spacing: mediaSpacing, alignment: .leading), count: 3)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: mediaSpacing) {
            ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                collageTile(for: element.element)
                    .frame(width: standardTileSize, height: standardTileSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .trailing) {
                        standardOverflowOverlay(for: element.offset, tileSize: standardTileSize)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleMediaTap(for: element.element)
                    }
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 14) {
            Text(real.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                metricsPill(symbol: "heart.fill", text: formatCount(real.metrics.likeCount))
                metricsPill(symbol: "bubble.right.fill", text: formatCount(real.metrics.commentCount))
            }
        }
        .padding(.trailing, metricsTrailingPadding)
    }

    private var metricsTrailingPadding: CGFloat {
        style == .collapsed ? 18 : 26
    }

    private func handleMediaTap(for attachment: RealPost.Attachment?) {
        guard let first = lightboxItems.first else { return }
        if let attachment, let match = lightboxItems.first(where: { $0.id == attachment.id }) {
            lightboxSelection = match.id
        } else {
            lightboxSelection = first.id
        }
        isLightboxPresented = true
    }

    private func collapsedOverflowOverlay(for index: Int, tileSize: CGFloat) -> some View {
        Group {
            if style == .collapsed,
               overflowCount > 0,
               index == maxVisibleMediaCount - 1 {
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: tileSize * 0.65)
                        .offset(x: tileSize * 0.175)
                    Text("+\(overflowCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
            }
        }
    }

    private func standardOverflowOverlay(for index: Int, tileSize: CGFloat) -> some View {
        Group {
            if style == .standard,
               overflowCount > 0,
               index == maxVisibleMediaCount - 1 {
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                    Text("+\(overflowCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
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

    private struct POICategoryAvatar: View {
        let category: POICategory
        let size: CGFloat

        var body: some View {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: category.markerGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: category.markerGradientColors.last?.opacity(0.5) ?? .black.opacity(0.5), radius: 6, y: 3)

                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.2)

                Image(systemName: category.symbolName)
                    .font(.system(size: max(size * 0.38, 14), weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .frame(width: size, height: size)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))

            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    FriendEngagementRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, ExperienceSheetLayout.engagementHorizontalInset)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            overlayBadge
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

    @ViewBuilder
    private var overlayBadge: some View {
        if let endorsement = entry.endorsement {
            Circle()
                .fill(Color.black.opacity(0.8))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: endorsementIconName(for: endorsement))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(endorsementColor(for: endorsement))
                }
        } else {
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(iconColor)
                }
        }
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

// MARK: - Real detail sections

private struct LikesAvatarGrid: View {
    let entries: [FriendEngagement]
    let iconName: String
    let storyContributors: [ExperienceDetailView.POIStoryContributor]
    let accentColor: Color

    @State private var viewerState: POIStoryViewerState?

    private let columns: [GridItem] = {
        let availableWidth = UIScreen.main.bounds.width - (ExperienceSheetLayout.engagementHorizontalInset * 2) - 16
        let count = 6
        let spacing: CGFloat = 8
        let totalSpacing = spacing * CGFloat(count - 1)
        let tileWidth = max((availableWidth - totalSpacing) / CGFloat(count), 34)
        return Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: count)
    }()
    private let leadingInset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    let storyIndex = contributorIndex(for: entry.user?.id)
                    if let index = storyIndex {
                        Button {
                            viewerState = POIStoryViewerState(contributorIndex: index)
                        } label: {
                            AvatarSquare(
                                user: entry.user,
                                endorsement: entry.endorsement,
                                hasStory: true,
                                storyAccent: accentColor
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        AvatarSquare(user: entry.user, endorsement: entry.endorsement)
                    }
                }
            }
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ExperienceSheetLayout.engagementHorizontalInset)
        .fullScreenCover(item: $viewerState) { state in
            POIStoryViewer(
                contributors: storyContributors,
                initialIndex: state.contributorIndex,
                accentColor: accentColor
            ) {
                viewerState = nil
            }
            .preferredColorScheme(.dark)
        }
    }

    private func contributorIndex(for userId: UUID?) -> Int? {
        guard let userId else { return nil }
        return storyIndexMap[userId]
    }

    private var storyIndexMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, contributor) in storyContributors.enumerated() {
            map[contributor.id] = index
        }
        return map
    }
}

private struct POIStoryViewerState: Identifiable {
    let contributorIndex: Int
    var id: Int { contributorIndex }
}

private struct POIStoryViewer: View {
    let contributors: [ExperienceDetailView.POIStoryContributor]
    let initialIndex: Int
    let accentColor: Color
    let onClose: () -> Void

    @State private var contributorIndex: Int
    @State private var itemIndex: Int = 0

    init(
        contributors: [ExperienceDetailView.POIStoryContributor],
        initialIndex: Int,
        accentColor: Color,
        onClose: @escaping () -> Void
    ) {
        self.contributors = contributors
        self.initialIndex = initialIndex
        self.accentColor = accentColor
        self.onClose = onClose
        _contributorIndex = State(initialValue: min(max(initialIndex, 0), max(contributors.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let contributor = currentContributor {
                storyMedia(for: contributor)
                    .overlay(alignment: .top) {
                        storyProgress(for: contributor)
                            .padding(.top, 28)
                            .padding(.horizontal, 20)
                    }
                    .overlay(alignment: .topLeading) {
                        header(for: contributor)
                            .padding(.top, 60)
                            .padding(.horizontal, 20)
                    }
                    .overlay(alignment: .bottom) {
                        actionBar
                            .padding(.bottom, 40)
                            .padding(.horizontal, 24)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                if value.translation.width < -40 {
                                    goToNextContributor()
                                } else if value.translation.width > 40 {
                                    goToPreviousContributor()
                                }
                            }
                    )
                    .onChange(of: contributorIndex) { _ in
                        itemIndex = 0
                    }
            } else {
                Color.black
                    .ignoresSafeArea()
                    .onAppear {
                        onClose()
                    }
            }
        }
    }

    private var currentContributor: ExperienceDetailView.POIStoryContributor? {
        guard contributors.indices.contains(contributorIndex) else { return nil }
        return contributors[contributorIndex]
    }

    private var currentItem: ExperienceDetailView.POIStoryContributor.Item? {
        guard let contributor = currentContributor,
              contributor.items.indices.contains(itemIndex) else { return nil }
        return contributor.items[itemIndex]
    }

    @ViewBuilder
    private func storyMedia(for contributor: ExperienceDetailView.POIStoryContributor) -> some View {
        GeometryReader { proxy in
            ZStack {
                if let item = currentItem {
                    MediaCardView(item: item.media, accentColor: accentColor, mode: .lightbox)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Color.black
                }

                HStack(spacing: 0) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            goToPreviousItem()
                        }
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            goToNextItem()
                        }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func storyProgress(for contributor: ExperienceDetailView.POIStoryContributor) -> some View {
        HStack(spacing: 4) {
            ForEach(contributor.items.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= itemIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(height: 4)
            }
        }
    }

    private func header(for contributor: ExperienceDetailView.POIStoryContributor) -> some View {
        HStack(spacing: 12) {
            POIStoryAvatarView(contributor: contributor)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(contributor.user?.handle ?? "Friend")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                if let timestamp = currentItem?.timestamp {
                    Text(timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 24) {
            storyActionButton(icon: "heart", label: "Like")
            storyActionButton(icon: "bubble.left.and.bubble.right", label: "Message")
            storyActionButton(icon: "paperplane", label: "Share")
        }
    }

    private func storyActionButton(icon: String, label: String) -> some View {
        Button { } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(label)
                    .font(.caption2.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func goToNextItem() {
        guard let contributor = currentContributor else { return }
        if contributor.items.indices.contains(itemIndex + 1) {
            itemIndex += 1
        } else {
            goToNextContributor()
        }
    }

    private func goToPreviousItem() {
        if itemIndex > 0 {
            itemIndex -= 1
        } else {
            goToPreviousContributor()
        }
    }

    private func goToNextContributor() {
        if contributors.indices.contains(contributorIndex + 1) {
            contributorIndex += 1
            itemIndex = 0
        } else {
            onClose()
        }
    }

    private func goToPreviousContributor() {
        if contributors.indices.contains(contributorIndex - 1) {
            contributorIndex -= 1
            if let contributor = currentContributor {
                itemIndex = max(contributor.items.count - 1, 0)
            }
        } else {
            onClose()
        }
    }
}

private struct POIStoryAvatarView: View {
    let contributor: ExperienceDetailView.POIStoryContributor

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Theme.neonPrimary,
                            Theme.neonAccent,
                            Theme.neonWarning,
                            Theme.neonPrimary
                        ]),
                        center: .center
                    ),
                    lineWidth: 3
                )
                .shadow(color: Theme.neonPrimary.opacity(0.5), radius: 10, y: 4)

            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            avatarContent
                .frame(width: 64, height: 64)
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let url = contributor.user?.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                case .empty:
                    ProgressView()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
    }

    private var initials: String {
        guard let handle = contributor.user?.handle else { return "?" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct AvatarSquare: View {
    let user: User?
    var size: CGFloat = 44
    var endorsement: RatedPOI.Endorsement? = nil
    var hasStory: Bool = false
    var storyAccent: Color = Theme.neonPrimary

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(hasStory ? 0.2 : 0.3), lineWidth: 1)
            }
            .overlay {
                if hasStory {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    storyAccent,
                                    Theme.neonAccent,
                                    storyAccent
                                ]),
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .padding(-4)
                        .shadow(color: storyAccent.opacity(0.4), radius: 6, y: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                endorsementBadge
            }
    }

    private var avatarContent: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        avatarPlaceholder
                    default:
                        ProgressView()
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
    }

    @ViewBuilder
    private var endorsementBadge: some View {
        if let endorsement {
            EndorsementBadgeIcon(endorsement: endorsement, size: 20)
                .offset(x: endorsementOffset.x, y: endorsementOffset.y)
        }
    }

    private var endorsementOffset: CGPoint {
        guard let endorsement else {
            return CGPoint(x: 5, y: 5)
        }
        if endorsement == .hype {
            let delta = size * 0.12
            return CGPoint(x: 5 + delta, y: 5 + delta)
        }
        return CGPoint(x: 5, y: 5)
    }

    private var avatarPlaceholder: some View {
        Text(initials)
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
    }

    private var initials: String {
        guard let handle = user?.handle else { return "??" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct CommentThreadList: View {
    let entries: [FriendEngagement]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 14) {
                ForEach(entries) { entry in
                    CommentThreadRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, ExperienceSheetLayout.engagementHorizontalInset)
    }
}

private struct CommentThreadRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarSquare(user: entry.user)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestamp = entry.timestamp?.formatted(.relative(presentation: .named)) {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.95))

                if entry.replies.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.replies) { reply in
                            CommentReplyRow(entry: reply)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct CommentReplyRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarSquare(user: entry.user, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestamp = entry.timestamp?.formatted(.relative(presentation: .named)) {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
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

    private var usesGridLayout: Bool {
        ExperienceMediaGalleryLayout.requiresGrid(for: items)
    }
}

private enum ExperienceMediaGalleryLayout {
    static let gridThreshold: Int = 3
    static let gridSpacing: CGFloat = 12
    static let gridItemHeight: CGFloat = 120
    static let carouselHeight: CGFloat = 240

    static func visualItemCount(in items: [MediaDisplayItem]) -> Int {
        items.filter { item in
            switch item.content {
            case .photo, .video:
                return true
            default:
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
            case let .video(url, poster):
                videoView(url: url, poster: poster)
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

    private func videoView(url: URL, poster: URL?) -> some View {
        AutoPlayVideoView(url: url, poster: poster, accentColor: accentColor, mode: mode)
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

private struct AutoPlayVideoView: View {
    let url: URL
    let poster: URL?
    let accentColor: Color
    let mode: MediaCardView.Mode

    @State private var isVideoVisible = false

    var body: some View {
        ZStack {
            posterLayer

            LoopingVideoPlayerView(url: url, isMuted: true, shouldPlay: isVideoVisible)
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
                        .scaledToFill()
                        .overlay { Color.black.opacity(0.15) }
                case .empty:
                    ProgressView()
                case .failure:
                    placeholderPoster
                @unknown default:
                    placeholderPoster
                }
            }
        } else {
            placeholderPoster
        }
    }

    private var placeholderPoster: some View {
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
    }
}

private struct LoopingVideoPlayerView: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let shouldPlay: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(with: url, muted: isMuted)
        view.setPlaying(shouldPlay)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.configure(with: url, muted: isMuted)
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

        func configure(with url: URL, muted: Bool) {
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
            playerLayer.videoGravity = .resizeAspectFill

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

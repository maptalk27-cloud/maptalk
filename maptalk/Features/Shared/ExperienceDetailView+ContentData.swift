import SwiftUI

// MARK: - Content data

extension ExperienceDetailView {
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
                    userId: userId,
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
                        userId: reply.userId,
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
                    userId: comment.userId,
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
                backgroundGradient: gradient,
                recentSharers: []
            )
        case let .poi(rated):
            let accent = rated.poi.category.accentColor
            let friendCheckIns = checkInEngagements(for: rated)
            let friendComments = poiCommentEngagements(for: rated)
            let endorsementBadges = poiEndorsementBadges(for: rated)
            let tagBadges = poiBadgeStrings(for: rated)
            let stories = poiStoryContributors(for: rated)
            let gallery = galleryItems(for: rated)
            let recentSharers = stories.filter { contributor in
                Date().timeIntervalSince(contributor.mostRecent) <= 60 * 60 * 24
            }
            return ContentData(
                hero: nil,
                badges: tagBadges,
                story: gallery.isEmpty ? nil : StorySectionModel(galleryItems: gallery),
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
                backgroundGradient: [Color.black, accent.opacity(0.25)],
                recentSharers: recentSharers
            )
        }
    }

    func highlightText(for real: RealPost, message: String?) -> String? {
        if let message, message.isEmpty == false {
            return message
        }
        if let emoji = Self.firstEmoji(in: real.attachments) {
            return "\(emoji) Live moment happening here."
        }
        return nil
    }

    func secondaryText(for real: RealPost) -> String {
        let base = "Visibility • \(real.visibility.displayName)"
        guard let descriptor = Self.mediaDescriptor(for: real) else {
            return base
        }
        return "\(base) · \(descriptor)"
    }

    func galleryItems(for ratedPOI: RatedPOI) -> [MediaDisplayItem] {
        ratedPOI.media.map(mediaDisplayItem)
    }

    func mediaDisplayItem(_ media: RatedPOI.Media) -> MediaDisplayItem {
        switch media.kind {
        case let .photo(url):
            return MediaDisplayItem(content: .photo(url))
        case let .video(url, poster):
            return MediaDisplayItem(content: .video(url: url, poster: poster))
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
                iconName: Self.endorsementIconName(for: endorsement),
                count: count,
                tint: Self.endorsementColor(for: endorsement)
            )
        }
    }

    func poiStoryContributors(for ratedPOI: RatedPOI) -> [POIStoryContributor] {
        let isStoryEligibleMedia: (RatedPOI.Media) -> Bool = { media in
            switch media.kind {
            case .photo, .video:
                return true
            }
        }

        let mediaCheckIns = ratedPOI.checkIns.filter { checkIn in
            checkIn.media.contains(where: isStoryEligibleMedia)
        }
        guard mediaCheckIns.isEmpty == false else { return [] }

        let grouped = Dictionary(grouping: mediaCheckIns, by: { $0.userId })
        let contributors: [POIStoryContributor] = grouped.compactMap { userId, entries -> POIStoryContributor? in
            let sortedEntries = entries.sorted { $0.createdAt < $1.createdAt }
            let items: [POIStoryContributor.Item] = sortedEntries.flatMap { checkIn in
                checkIn.media.compactMap { media -> POIStoryContributor.Item? in
                    guard isStoryEligibleMedia(media) else { return nil }
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
                userId: checkIn.userId,
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
                userId: comment.userId,
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
            badges.append("❤️ \(Self.formatCount(real.metrics.likeCount))")
        }
        if real.metrics.commentCount > 0 {
            badges.append("💬 \(Self.formatCount(real.metrics.commentCount))")
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

extension ExperienceDetailView {
    static func formatCount(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        let doubleValue = Double(value)
        if value >= 1_000_000 {
            return trimmedCount(doubleValue / 1_000_000) + "M"
        } else {
            return trimmedCount(doubleValue / 1_000) + "K"
        }
    }

    static func trimmedCount(_ value: Double) -> String {
        let formatted = String(format: "%.1f", value)
        if formatted.hasSuffix(".0") {
            return String(formatted.dropLast(2))
        }
        return formatted
    }

    static func endorsementIconName(for endorsement: RatedPOI.Endorsement) -> String {
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

    static func endorsementColor(for endorsement: RatedPOI.Endorsement) -> Color {
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

    enum ExperienceSheetLayout {
        static let horizontalInset: CGFloat = 16
        static let panelHorizontalPadding: CGFloat = 0
        static let detailContentInset: CGFloat = 16
        static let engagementHorizontalInset: CGFloat = 22
    }
}

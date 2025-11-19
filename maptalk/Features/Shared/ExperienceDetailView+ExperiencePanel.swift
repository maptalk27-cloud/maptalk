import SwiftUI

// MARK: - Experience panel

extension ExperienceDetailView {
struct ExperiencePanel: View {
    let data: ExperienceDetailView.ContentData
    let onRecentSharerSelected: ((Int, ExperienceDetailView.ContentData) -> Void)?

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
                    accentColor: data.accentColor,
                    recentSharers: data.recentSharers,
                    onRecentSharerSelected: { index in
                        onRecentSharerSelected?(index, data)
                    }
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
struct POITagList: View {
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
struct POICollapsedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color
    let recentSharers: [ExperienceDetailView.POIStoryContributor]
    let onRecentSharerSelected: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: POIHeroLayout.avatarSpacing) {
                POIAvatar(category: info.category, accentColor: accentColor, size: POIHeroLayout.collapsedAvatarSize)
                    .alignmentGuide(.top) { $0[.top] }

                VStack(alignment: .leading, spacing: 3) {
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
            }

            if recentSharers.isEmpty == false {
                POIRecentSharersRow(
                    sharers: recentSharers,
                    accentColor: accentColor
                ) { index in
                    onRecentSharerSelected?(index)
                }
            }

            if let stats {
                POIHeroStatsRow(model: stats)
            }
        }
        .padding(.top, POIHeroLayout.headerTopPadding)
        .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
        .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
    }
}

struct POIExpandedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color
    let recentSharers: [ExperienceDetailView.POIStoryContributor]
    let onRecentSharerSelected: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: POIHeroLayout.avatarSpacing) {
                POIAvatar(category: info.category, accentColor: accentColor, size: POIHeroLayout.collapsedAvatarSize)
                    .alignmentGuide(.top) { $0[.top] }

                VStack(alignment: .leading, spacing: 3) {
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
            }

            if recentSharers.isEmpty == false {
                POIRecentSharersRow(
                    sharers: recentSharers,
                    accentColor: accentColor
                ) { index in
                    onRecentSharerSelected?(index)
                }
            }

            if let stats {
                POIHeroStatsRow(model: stats)
            }
        }
        .padding(.top, POIHeroLayout.headerTopPadding)
        .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
        .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
    }
}
struct POIHeroStatsRow: View {
    let model: ExperienceDetailView.POIStatsModel

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            POIStatPill(icon: "shoeprints.fill", value: model.checkIns)
            POIStatPill(icon: "text.bubble.fill", value: model.comments)
            POIStatPill(icon: "star.fill", value: model.favorites)
        }
        .padding(.horizontal, 2)
    }
}
struct POIStatPill: View {
    let icon: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(ExperienceDetailView.formatCount(value))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule(style: .continuous))
    }
}
struct POIBadgeSummaryPill: View {
    let badge: ExperienceDetailView.EndorsementBadge

    var body: some View {
        HStack(spacing: 4) {
            iconView
                .font(.caption.weight(.bold))
            Text(ExperienceDetailView.formatCount(badge.count))
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
struct EndorsementBadgeIcon: View {
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
                    Image(systemName: ExperienceDetailView.endorsementIconName(for: endorsement))
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(ExperienceDetailView.endorsementColor(for: endorsement))
                }
        }
    }
}
struct POIAvatar: View {
    let category: POICategory
    let accentColor: Color
    var size: CGFloat = 54

    var body: some View {
        let gradient = category.markerGradientColors
        let corner = size * 0.22
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(45))
                .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1.2)
                        .rotationEffect(.degrees(45))
                }

            Image(systemName: category.symbolName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
        .frame(width: size, height: size)
    }
}

struct POIRecentSharersRow: View {
    let sharers: [ExperienceDetailView.POIStoryContributor]
    let accentColor: Color
    let onSelect: (Int) -> Void

    private let avatarSize: CGFloat = 56

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Array(sharers.enumerated()), id: \.element.id) { index, sharer in
                    Button {
                        onSelect(index)
                    } label: {
                        VStack(spacing: 6) {
                            POISharerAvatarCircle(
                                contributor: sharer,
                                accentColor: accentColor,
                                size: avatarSize
                            )
                            Text(sharer.user?.handle ?? "Friend")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: avatarSize + 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.vertical, 2)
    }
}

private enum POIHighlightStyle {
    static let highlightColor = Color.orange
    static let avatarLineWidth: CGFloat = 2.0
    static let statLineWidth: CGFloat = 1.2
}

private struct POISharerAvatarCircle: View {
    let contributor: ExperienceDetailView.POIStoryContributor
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        let avatar = Group {
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

        avatar
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .inset(by: 1.5)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            }
            .overlay {
                Circle()
                    .stroke(POIHighlightStyle.highlightColor, lineWidth: POIHighlightStyle.avatarLineWidth)
            }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.gray.opacity(0.5))
    }

    private var initials: String {
        let handle = contributor.user?.handle ?? "PO"
        return String(handle.prefix(2)).uppercased()
    }
}
enum POIHeroLayout {
    static let headerTopPadding: CGFloat = 40
    static let collapsedHorizontalPadding: CGFloat = 32
    static let collapsedVerticalPadding: CGFloat = 12
    static let standardHorizontalPadding: CGFloat = 24
    static let standardVerticalPadding: CGFloat = 22
    static let collapsedAvatarSize: CGFloat = 30
    static let standardAvatarSize: CGFloat = 40
    static let avatarSpacing: CGFloat = 10
}
struct SummarySection: View {
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

struct HighlightsSection: View {
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

struct EngagementSection: View {
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

struct HeroSection: View {
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
}

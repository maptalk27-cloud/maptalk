import SwiftUI

private struct ExperienceNeutralAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var experienceNeutralAppearance: Bool {
        get { self[ExperienceNeutralAppearanceKey.self] }
        set { self[ExperienceNeutralAppearanceKey.self] = newValue }
    }
}

// MARK: - Experience panel

extension ExperienceDetailView {
struct ExperiencePanel: View {
    let data: ExperienceDetailView.ContentData
    let onRecentSharerSelected: ((Int, ExperienceDetailView.ContentData) -> Void)?
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onJourneyAvatarStackTap: ((JourneyPost) -> Void)?
    let onUserSelected: (User) -> Void
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool
    var isPlaybackActive = true
    var usesNeutralAppearance = false
    var commentTarget: BackendCommentTarget? = nil
    var featuredPOIMedia: RatedPOI.Media? = nil
    var featuredPOIMediaContent: AnyView? = nil
    @Environment(\.appEnv) private var environment
    @Environment(\.postEngagementRequest) private var postEngagementRequest
    @State private var contentNeedsScrolling = false

    var body: some View {
        if usesNeutralAppearance && isSingleVideoHero {
            GeometryReader { geometry in
                scrollContent(singleVideoViewportHeight: geometry.size.height)
            }
        } else {
            scrollContent()
        }
    }

    private func scrollContent(singleVideoViewportHeight: CGFloat? = nil) -> some View {
        ScrollViewReader { scroll in
        ScrollView {
            panelContent(singleVideoViewportHeight: singleVideoViewportHeight)
                .background(ExperienceContentScrollHandoff(isScrollable: contentNeedsScrolling))
        }
        // Keep one content/player tree while the sheet moves. Only the outer
        // vertical scroll view's own pan is disabled when there is no overflow;
        // horizontal media galleries and long comments retain their scrolling.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                > geometry.containerSize.height + 1
        } action: { _, needsScrolling in
            contentNeedsScrolling = needsScrolling
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .padding(.horizontal, isSingleVideoHero || usesNeutralAppearance ? 0 : -ExperienceSheetLayout.horizontalInset)
        .environment(\.experienceNeutralAppearance, usesNeutralAppearance)
        .task(id: postEngagementRequest?.id) {
            guard usesNeutralAppearance, let request = postEngagementRequest,
                  data.hero?.real.id == request.postID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            scroll.scrollTo(request.section, anchor: .top)
        }
        }
    }

    private func panelContent(singleVideoViewportHeight: CGFloat?) -> some View {
        VStack(spacing: 28) {
                if let journey = data.journey {
                    JourneyCard(
                        journey: journey.journey,
                        user: journey.user,
                        style: .standard,
                        userProvider: userProvider,
                        onUserTap: onUserSelected,
                        onAvatarStackTap: {
                            onJourneyAvatarStackTap?(journey.journey)
                        }
                    )
                    .padding(.horizontal, 4)

                    if data.engagement.hasContent {
                        EngagementSection(
                            model: data.engagement,
                            accentColor: data.accentColor,
                            onUserSelected: onUserSelected,
                            onPOIContributorViewed: onPOIContributorViewed,
                            isPOIContributorUnseen: isPOIContributorUnseen
                        )
                            .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                    }
                } else if let hero = data.hero {
                    HeroSection(
                        model: hero,
                        style: .standard,
                        journeyProvider: journeyProvider,
                        userProvider: userProvider,
                        usesNeutralAppearance: usesNeutralAppearance && !isSingleVideoHero,
                        singleVideoViewportHeight: singleVideoViewportHeight,
                        isPlaybackActive: isPlaybackActive,
                        onUserSelected: onUserSelected,
                        onCapsuleTap: onJourneyAvatarStackTap
                    )
                        .padding(.horizontal, isSingleVideoHero || usesNeutralAppearance ? 0 : 4)

                    if usesNeutralAppearance {
                        if let locationName = hero.real.locationName {
                            Label(locationName, systemImage: "mappin.and.ellipse")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                                .accessibilityIdentifier("experience.real.location.\(hero.real.id.uuidString)")
                        }
                        postEngagementContent
                    } else if data.engagement.hasContent {
                        EngagementSection(
                            model: data.engagement,
                            accentColor: data.accentColor,
                            onUserSelected: onUserSelected,
                            onPOIContributorViewed: onPOIContributorViewed,
                            isPOIContributorUnseen: isPOIContributorUnseen
                        )
                            .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                    }
                } else {
                    defaultExperienceContent
                }

                if let commentTarget, let backend = environment.backend {
                    BackendCommentThread(store: backend, target: commentTarget, onUserSelected: onUserSelected)
                        .id(commentTarget)
                        .id(PostEngagementSection.comments)
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }
        }
        .padding(.horizontal, ExperienceSheetLayout.panelHorizontalPadding)
        .padding(.top, isSingleVideoHero || featuredPOIMedia != nil || usesNeutralAppearance ? 0 : 40)
        .padding(.bottom, 60)
    }

    private var postEngagementContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Group {
                if data.engagement.friendLikes.isEmpty {
                    Text("No likes yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LikesAvatarGrid(
                        entries: data.engagement.friendLikes,
                        iconName: "heart",
                        storyContributors: [],
                        accentColor: data.accentColor,
                        onUserSelected: onUserSelected,
                        onContributorViewed: onPOIContributorViewed,
                        isContributorUnseen: isPOIContributorUnseen
                    )
                }
            }
            .id(PostEngagementSection.likes)

            if environment.backend == nil || commentTarget == nil {
                Group {
                    if data.engagement.friendComments.isEmpty {
                        Text("No comments yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        CommentThreadList(entries: data.engagement.friendComments, onUserSelected: onUserSelected)
                    }
                }
                .id(PostEngagementSection.comments)
            }
        }
        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
    }

    private var isSingleVideoHero: Bool {
        guard let hero = data.hero else { return false }
        guard hero.real.attachments.count == 1,
              let attachment = hero.real.attachments.first,
              case .video = attachment.kind else {
            return false
        }
        return true
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
                    },
                    isContributorUnseen: isPOIContributorUnseen,
                    featuredMedia: featuredPOIMedia,
                    featuredMediaContent: featuredPOIMediaContent,
                    isPlaybackActive: isPlaybackActive
                )
                .padding(.horizontal, ExperienceSheetLayout.detailContentInset)

                if data.badges.isEmpty == false {
                    POITagList(badges: data.badges, accentColor: data.accentColor)
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }

                if data.engagement.hasContent {
                    EngagementSection(
                        model: data.engagement,
                        accentColor: data.accentColor,
                        onUserSelected: onUserSelected,
                        onPOIContributorViewed: onPOIContributorViewed,
                        isPOIContributorUnseen: isPOIContributorUnseen
                    )
                        .padding(.horizontal, ExperienceSheetLayout.detailContentInset)
                }
            }
        } else {
            VStack(spacing: 24) {
                SummarySection(model: data.highlights, accentColor: data.accentColor)
                    .padding(.horizontal, 12)

                if let story = data.story {
                    ExperienceMediaGallery(items: story.galleryItems, accentColor: data.accentColor,
                                           isPlaybackActive: isPlaybackActive)
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
                    EngagementSection(
                        model: data.engagement,
                        accentColor: data.accentColor,
                        onUserSelected: onUserSelected,
                        onPOIContributorViewed: onPOIContributorViewed,
                        isPOIContributorUnseen: isPOIContributorUnseen
                    )
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
struct POIPlaceHeading: View {
    let info: ExperienceDetailView.POIInfoModel
    let accentColor: Color

    var body: some View {
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
    }
}

struct POICollapsedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color
    let recentSharers: [ExperienceDetailView.POIStoryContributor]
    let onRecentSharerSelected: ((Int) -> Void)?
    let isContributorUnseen: ([String]) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            POIPlaceHeading(info: info, accentColor: accentColor)
                .accessibilityIdentifier("experience.poi.collapsed.heading")

            if recentSharers.isEmpty == false {
                POIRecentSharersRow(
                    sharers: recentSharers,
                    accentColor: accentColor,
                    isContributorUnseen: isContributorUnseen
                ) { index in
                    onRecentSharerSelected?(index)
                }
            }

            Spacer(minLength: 0)

            if let stats {
                POIHeroStatsRow(model: stats, directionsDestination: info.directionsDestination)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("experience.poi.collapsed.stats")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, POIHeroLayout.headerTopPadding)
        .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
        .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("experience.poi.collapsed")
    }
}

struct POIExpandedHero: View {
    let info: ExperienceDetailView.POIInfoModel
    let stats: ExperienceDetailView.POIStatsModel?
    let accentColor: Color
    let recentSharers: [ExperienceDetailView.POIStoryContributor]
    let onRecentSharerSelected: ((Int) -> Void)?
    let isContributorUnseen: ([String]) -> Bool
    var featuredMedia: RatedPOI.Media? = nil
    var featuredMediaContent: AnyView? = nil
    var isPlaybackActive = true

    var body: some View {
        Group {
            if let featuredMedia {
                VStack(alignment: .leading, spacing: 16) {
                    featuredStage(media: featuredMedia)

                    if !recentSharers.isEmpty {
                        recentSharersRow
                            .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
                            .padding(.bottom, POIHeroLayout.collapsedVerticalPadding)
                    }
                }
            } else {
                // The direct-map place page keeps its original layout.
                VStack(alignment: .leading, spacing: 6) {
                    POIPlaceHeading(info: info, accentColor: accentColor)
                        .accessibilityIdentifier("experience.poi.expanded.heading")

                    if !recentSharers.isEmpty {
                        recentSharersRow
                    }

                    if let stats {
                        POIHeroStatsRow(model: stats, directionsDestination: info.directionsDestination)
                    }
                }
                .padding(.top, POIHeroLayout.headerTopPadding)
                .padding(.horizontal, POIHeroLayout.collapsedHorizontalPadding)
                .padding(.vertical, POIHeroLayout.collapsedVerticalPadding)
            }
        }
        .background {
            if let featuredMedia {
                POIMediaBackdrop(media: featuredMedia)
                    .padding(.horizontal, -ExperienceSheetLayout.detailContentInset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("experience.poi.expanded")
    }

    private func featuredStage(media: RatedPOI.Media) -> some View {
        ZStack {
            if let featuredMediaContent {
                featuredMediaContent
            } else {
                POIFeaturedMedia(media: media, accentColor: accentColor,
                                 isPlaybackActive: isPlaybackActive)
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.72), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            POIPlaceHeading(info: info, accentColor: accentColor)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .allowsHitTesting(false)
                .accessibilityIdentifier("experience.poi.expanded.heading")
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottomTrailing) {
            if let stats {
                POIHeroStatsRow(model: stats, directionsDestination: info.directionsDestination)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("experience.poi.expanded.stats")
            }
        }
    }

    private var recentSharersRow: some View {
        POIRecentSharersRow(
            sharers: recentSharers,
            accentColor: accentColor,
            isContributorUnseen: isContributorUnseen
        ) { index in
            onRecentSharerSelected?(index)
        }
    }
}
struct POIHeroStatsRow: View {
    let model: ExperienceDetailView.POIStatsModel
    var directionsDestination: MapDirectionsDestination? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let directionsDestination {
                PlaceDirectionsButton(destination: directionsDestination)
            }
            Spacer(minLength: 0)
            POIStatPill(icon: "shoeprints.fill", value: model.checkIns)
                .allowsHitTesting(false)
            POIStatPill(icon: "text.bubble.fill", value: model.comments, commentTarget: model.commentTarget)
                .allowsHitTesting(false)
            POIStatPill(icon: "star.fill", value: model.favorites)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 2)
    }
}
struct POIStatPill: View {
    let icon: String
    let value: Int
    var commentTarget: BackendCommentTarget? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            ExperienceCommentCount(target: commentTarget, fallback: ExperienceDetailView.formatCount(value))
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
    let isContributorUnseen: ([String]) -> Bool
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
                                size: avatarSize,
                                isUnseen: isContributorUnseen(sharer.readKeys)
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
                    .accessibilityIdentifier("experience.poi.sharer.\(sharer.userId.uuidString)")
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
    let isUnseen: Bool

    var body: some View {
        let avatar = Group {
            if let url = contributor.user?.avatarURL {
                MapImage(url: url) { phase in
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

        ZStack {
            StoryStatusCircleRing(
                diameter: size + 8,
                isUnseen: isUnseen,
                unreadLineWidth: POIHighlightStyle.avatarLineWidth,
                seenLineWidth: 1.2,
                unreadShadowRadius: 4
            )

            avatar
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .inset(by: 1.5)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1.2)
                }
        }
        .frame(width: size + 14, height: size + 14)
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
    let onUserSelected: (User) -> Void
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.friendLikes.isEmpty == false {
                LikesAvatarGrid(
                    entries: model.friendLikes,
                    iconName: model.friendLikesIconName,
                    storyContributors: model.storyContributors,
                    accentColor: accentColor,
                    onUserSelected: onUserSelected,
                    onContributorViewed: onPOIContributorViewed,
                    isContributorUnseen: isPOIContributorUnseen
                )
            }

            if model.friendComments.isEmpty == false {
                CommentThreadList(entries: model.friendComments, onUserSelected: onUserSelected)
            }
        }
    }
}

struct HeroSection: View {
    let model: ExperienceDetailView.HeroSectionModel
    let style: CompactRealCard.Style
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let hideMedia: Bool
    let useTallLayout: Bool
    let usesNeutralAppearance: Bool
    let singleVideoViewportHeight: CGFloat?
    let isPlaybackActive: Bool
    let onUserSelected: ((User) -> Void)?
    let onCapsuleTap: ((JourneyPost) -> Void)?

    init(
        model: ExperienceDetailView.HeroSectionModel,
        style: CompactRealCard.Style,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { PreviewData.journey(for: $0) },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        hideMedia: Bool = false,
        useTallLayout: Bool = false,
        usesNeutralAppearance: Bool = false,
        singleVideoViewportHeight: CGFloat? = nil,
        isPlaybackActive: Bool = true,
        onUserSelected: ((User) -> Void)? = nil,
        onCapsuleTap: ((JourneyPost) -> Void)? = nil
    ) {
        self.model = model
        self.style = style
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.hideMedia = hideMedia
        self.useTallLayout = useTallLayout
        self.usesNeutralAppearance = usesNeutralAppearance
        self.singleVideoViewportHeight = singleVideoViewportHeight
        self.isPlaybackActive = isPlaybackActive
        self.onUserSelected = onUserSelected
        self.onCapsuleTap = onCapsuleTap
    }

    var body: some View {
        CompactRealCard(
            real: model.real,
            user: model.user,
            style: style,
            displayNameOverride: model.displayNameOverride,
            avatarCategory: model.avatarCategory,
            journeyProvider: journeyProvider,
            userProvider: userProvider,
            suppressContent: model.suppressContent,
            hideHeader: false,
            hideMedia: hideMedia,
            useTallLayout: useTallLayout,
            usesNeutralAppearance: usesNeutralAppearance,
            singleVideoViewportHeight: singleVideoViewportHeight,
            isPlaybackActive: isPlaybackActive,
            onUserSelected: onUserSelected,
            onCapsuleTap: onCapsuleTap
        )
    }
}
}

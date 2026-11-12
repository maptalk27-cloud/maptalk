import SwiftUI

// MARK: - Presentation helpers

extension ExperienceDetailView {
    var currentMode: Mode {
        if let standaloneMode {
            return standaloneMode
        } else if let context = sequenceContext {
            let identifier = context.selection.wrappedValue
            if let item = context.pager.items.first(where: { $0.id == identifier }) {
                return item.mode
            }
            if let first = context.pager.items.first {
                return first.mode
            }
        } else if let poi {
            return .poi(poi)
        }

        fatalError("ExperienceDetailView invoked without mode context.")
    }

    func expandedContent(using data: ContentData) -> some View {
        Group {
            // A single post has nothing to page through. Keeping its vertical
            // scroll view directly in the sheet preserves native drag handoff.
            if let context = sequenceContext, context.pager.items.count > 1 {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        ExperiencePanel(
                            data: contentData(for: item.mode),
                            onRecentSharerSelected: { index, data in
                                openRecentSharer(at: index, using: data)
                            },
                            journeyProvider: journeyProvider,
                            userProvider: userProvider,
                            onJourneyAvatarStackTap: onJourneyAvatarStackTap,
                            onUserSelected: openProfile,
                            onPOIContributorViewed: onPOIContributorViewed,
                            isPOIContributorUnseen: isPOIContributorUnseen,
                            isPlaybackActive: isMediaPlaybackActive && context.selection.wrappedValue == item.id,
                            usesNeutralAppearance: isClassicPostPreview,
                            commentTarget: item.mode.commentTarget,
                            featuredPOIMedia: browsingPOIMedia(for: item.mode)
                        )
                        .background(ExperiencePagerVerticalBounceGuard())
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                ExperiencePanel(
                    data: data,
                    onRecentSharerSelected: { index, content in
                        openRecentSharer(at: index, using: content)
                    },
                    journeyProvider: journeyProvider,
                    userProvider: userProvider,
                    onJourneyAvatarStackTap: onJourneyAvatarStackTap,
                    onUserSelected: openProfile,
                    onPOIContributorViewed: onPOIContributorViewed,
                    isPOIContributorUnseen: isPOIContributorUnseen,
                    isPlaybackActive: isMediaPlaybackActive,
                    usesNeutralAppearance: isClassicPostPreview,
                    commentTarget: currentMode.commentTarget,
                    featuredPOIMedia: expandedPOIMedia ?? browsingPOIMedia(for: currentMode),
                    featuredPOIMediaContent: expandedPOIMediaContent
                )
            }
        }
    }

    func collapsedPreview(using data: ContentData) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            Group {
                if let context = sequenceContext {
                    TabView(selection: context.selection) {
                        ForEach(context.pager.items) { item in
                            collapsedPreviewContent(
                                for: item.mode,
                                isPlaybackActive: isMediaPlaybackActive && context.selection.wrappedValue == item.id,
                                viewportHeight: size.height
                            )
                                .collapsedPreviewTap(onCollapsedTap)
                                .tag(item.id)
                                .frame(width: size.width, height: size.height, alignment: .top)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: size.width, height: size.height)
                } else {
                    Group {
                        if usesClassicPostPreview, poiBrowsingUserID != nil {
                            collapsedPreviewContent(for: currentMode,
                                isPlaybackActive: isMediaPlaybackActive, viewportHeight: size.height)
                        } else {
                            collapsedPreviewLayer(using: data, viewportHeight: size.height)
                        }
                    }
                        .collapsedPreviewTap(onCollapsedTap)
                        .frame(width: size.width, height: size.height, alignment: .top)
                }
            }
            .padding(.horizontal, usesNeutralPreviewBackground || isClassicPOIMediaPreview
                ? 0 : -ExperienceSheetLayout.horizontalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isClassicPOIMediaPreview: Bool {
        guard case .poi = currentMode else { return false }
        return classicPageFillsBottom(for: currentMode)
    }

    func classicPageFillsBottom(for mode: Mode) -> Bool {
        guard usesClassicPostPreview else { return false }
        switch mode {
        case let .real(post, _):
            guard post.attachments.count == 1, let attachment = post.attachments.first,
                  case .video = attachment.kind else { return false }
            return true
        case let .poi(place):
            return !isExpanded && browsingPOISelection(for: place)?.media != nil
        case .journey:
            return false
        }
    }

    @ViewBuilder
    private func collapsedPreviewContent(for mode: Mode, isPlaybackActive: Bool, viewportHeight: CGFloat) -> some View {
        if case let .poi(place) = mode,
           let media = browsingPOISelection(for: place)?.media {
            FriendStoryPOIPreview(place: place, media: media, isPlaybackActive: isPlaybackActive)
        } else {
            collapsedPreviewLayer(using: contentData(for: mode), viewportHeight: viewportHeight)
        }
    }

    private func browsingPOIMedia(for mode: Mode) -> RatedPOI.Media? {
        guard case let .poi(place) = mode else { return nil }
        return browsingPOISelection(for: place)?.media
    }

    @ViewBuilder
    private func collapsedPreviewBody(using data: ContentData) -> some View {
        if let journey = data.journey {
            JourneyCard(
                journey: journey.journey,
                user: journey.user,
                style: .collapsed,
                userProvider: userProvider,
                onUserTap: openProfile,
                onAvatarStackTap: {
                    onJourneyAvatarStackTap?(journey.journey)
                }
            )
            .padding(.horizontal, 12)
        } else if let poiInfo = data.poiInfo {
            POICollapsedHero(
                info: poiInfo,
                stats: data.poiStats,
                accentColor: data.accentColor,
                recentSharers: data.recentSharers,
                onRecentSharerSelected: { index in
                    openRecentSharer(at: index, using: data)
                },
                isContributorUnseen: isPOIContributorUnseen
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

    @ViewBuilder
    private func collapsedPreviewLayer(using data: ContentData, viewportHeight: CGFloat) -> some View {
        if let hero = data.hero {
            let isSplitLayout = shouldHideMediaTile(for: data)
            ExperienceDetailView.HeroSection(
                model: hero,
                style: .collapsed,
                journeyProvider: journeyProvider,
                userProvider: userProvider,
                hideMedia: isSplitLayout,
                useTallLayout: true,
                usesNeutralAppearance: usesNeutralPreviewBackground,
                singleVideoViewportHeight: isClassicPostPreview && isSplitLayout ? viewportHeight : nil,
                isPlaybackActive: isMediaPlaybackActive,
                onUserSelected: openProfile,
                onCapsuleTap: onJourneyAvatarStackTap
            )
            .padding(.horizontal, usesNeutralPreviewBackground ? 0 : 12)
            .padding(.top, usesNeutralPreviewBackground ? 0 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            collapsedPreviewBody(using: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func backgroundVideo(for data: ContentData) -> (url: URL, poster: URL?, metadata: RealPost.Attachment.VideoMetadata?)? {
        guard let hero = data.hero else { return nil }
        guard storyExpectedMedia.isEmpty || storyExpectedMedia.count == 1 else { return nil }
        guard hero.real.attachments.count == 1,
              let attachment = hero.real.attachments.first,
              case let .video(url, poster) = attachment.kind else {
            return nil
        }
        return (url, poster, attachment.videoMetadata)
    }

    private func shouldHideMediaTile(for data: ContentData) -> Bool {
        backgroundVideo(for: data) != nil
    }

    var usesNeutralPreviewBackground: Bool {
        // Single-video cards retain their original video backdrop and white text.
        isClassicPostPreview && (isExpanded || !shouldHideMediaTile(for: contentData(for: currentMode)))
    }

    @ViewBuilder
    func background(for data: ContentData, isExpanded: Bool) -> some View {
        if isExpanded == false, let video = backgroundVideo(for: data) {
            AutoPlayVideoView(
                url: video.url,
                poster: video.poster,
                accentColor: data.accentColor,
                mode: .card,
                showsPlaceholderBadge: false,
                usesAspectFit: false,
                isPlaybackActive: isMediaPlaybackActive
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.18),
                        .black.opacity(0.1),
                        .black.opacity(0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        } else {
            gradientBackground(for: data)
        }
    }

    private func gradientBackground(for data: ContentData) -> some View {
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

private extension View {
    @ViewBuilder
    func collapsedPreviewTap(_ action: (() -> Void)?) -> some View {
        if let action {
            // Only otherwise unhandled taps expand the card. An ancestor
            // simultaneous gesture also catches photo/profile/Bubble taps,
            // replacing the compact branch while it is presenting a child.
            background {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .accessibilityHidden(true)
            }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Open details")
                .accessibilityAction(.default, action)
        } else {
            self
        }
    }
}

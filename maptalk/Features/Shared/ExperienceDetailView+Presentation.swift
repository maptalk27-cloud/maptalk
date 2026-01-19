import SwiftUI

// MARK: - Presentation helpers

extension ExperienceDetailView {
    var currentMode: Mode {
        if let context = sequenceContext {
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
            if let context = sequenceContext {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        ExperiencePanel(
                            data: contentData(for: item.mode),
                            onRecentSharerSelected: { index, data in
                                openRecentSharer(at: index, using: data)
                            },
                            userProvider: userProvider,
                            onJourneyAvatarStackTap: onJourneyAvatarStackTap
                        )
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
                    userProvider: userProvider,
                    onJourneyAvatarStackTap: onJourneyAvatarStackTap
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
                            collapsedPreviewContent(for: item.mode)
                                .tag(item.id)
                                .frame(width: size.width, height: size.height)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: size.width, height: size.height)
                } else {
                    collapsedPreviewLayer(using: data)
                        .frame(width: size.width, height: size.height)
                }
            }
            .padding(.horizontal, -ExperienceSheetLayout.horizontalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func collapsedPreviewContent(for mode: Mode) -> some View {
        let data = contentData(for: mode)
        collapsedPreviewLayer(using: data)
    }

    @ViewBuilder
    private func collapsedPreviewBody(using data: ContentData) -> some View {
        if let journey = data.journey {
            JourneyCard(
                journey: journey.journey,
                user: journey.user,
                style: .collapsed,
                userProvider: userProvider,
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
                }
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
    private func collapsedPreviewLayer(using data: ContentData) -> some View {
        if let hero = data.hero {
            let isSplitLayout = shouldHideMediaTile(for: data)
            let useTallLayout = true
            ExperienceDetailView.HeroSection(
                model: hero,
                style: .collapsed,
                userProvider: userProvider,
                hideMedia: isSplitLayout,
                useTallLayout: useTallLayout
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            collapsedPreviewBody(using: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func backgroundVideo(for data: ContentData) -> (url: URL, poster: URL?, metadata: RealPost.Attachment.VideoMetadata?)? {
        guard let hero = data.hero else { return nil }
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

    @ViewBuilder
    func background(for data: ContentData, isExpanded: Bool) -> some View {
        if isExpanded == false, let video = backgroundVideo(for: data) {
            AutoPlayVideoView(
                url: video.url,
                poster: video.poster,
                accentColor: data.accentColor,
                mode: .card,
                showsPlaceholderBadge: false,
                usesAspectFit: video.metadata?.isStandardLandscape == false
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

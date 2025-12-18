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
        VStack(spacing: 16) {
            if let context = sequenceContext {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        collapsedPreviewContent(for: item.mode)
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .padding(.top, 0)
                .frame(height: 240)
                .padding(.horizontal, 0)
            } else {
                collapsedPreviewBody(using: data)
            }
        }
        .padding(.horizontal, -ExperienceSheetLayout.horizontalInset)
        .padding(.top, 12)
        .padding(.bottom, -8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func collapsedPreviewContent(for mode: Mode) -> some View {
        let data = contentData(for: mode)
        collapsedPreviewBody(using: data)
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
        } else if let hero = data.hero {
            HeroSection(model: hero, style: .collapsed)
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

    func background(for data: ContentData) -> some View {
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

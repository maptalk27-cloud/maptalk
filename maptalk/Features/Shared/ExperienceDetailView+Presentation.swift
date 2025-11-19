import SwiftUI

// MARK: - Presentation helpers

extension ExperienceDetailView {
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

    func expandedContent(using data: ContentData) -> some View {
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

    func collapsedPreview(using data: ContentData) -> some View {
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

    func triggerAutoStoryIfNeeded(with data: ContentData) {
        let canAutoPresent = autoPresentRecentStories
        let hasNotTriggered = hasTriggeredAutoStory == false
        let hasSharers = data.recentSharers.isEmpty == false
        guard canAutoPresent, hasNotTriggered, hasSharers else {
#if DEBUG
            print("[ExperienceDetailView] autoStory skipped autoPresent=\(canAutoPresent) hasTriggered=\(hasTriggeredAutoStory) sharers=\(data.recentSharers.count)")
#endif
            return
        }
        autoStoryViewerState = POIStoryViewerState(contributorIndex: 0)
        hasTriggeredAutoStory = true
#if DEBUG
        print("[ExperienceDetailView] autoStory presenting sharers=\(data.recentSharers.count)")
#endif
    }
}

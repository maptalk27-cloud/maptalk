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

    struct ContentData {
        let hero: HeroSectionModel?
        let badges: [String]
        let story: StorySectionModel?
        let highlights: HighlightsSectionModel
        let engagement: EngagementSectionModel
        let poiInfo: POIInfoModel?
        let poiStats: POIStatsModel?
        let accentColor: Color
        let backgroundGradient: [Color]
        let recentSharers: [POIStoryContributor]
    }

    struct HeroSectionModel {
        let real: RealPost
        let user: User?
        let displayNameOverride: String?
        let avatarCategory: POICategory?
        let suppressContent: Bool
    }

    struct StorySectionModel {
        let galleryItems: [MediaDisplayItem]
    }

    struct HighlightsSectionModel {
        let title: String
        let subtitle: String?
        let highlight: String?
        let secondary: String?
    }

    struct EndorsementBadge: Identifiable {
        let id = UUID()
        let iconName: String
        let count: Int
        let tint: Color
    }

    struct POIInfoModel {
        let name: String
        let category: POICategory
        let endorsementBadges: [EndorsementBadge]
    }

    struct POIStatsModel {
        let checkIns: Int
        let comments: Int
        let favorites: Int
        let endorsements: RatedPOI.EndorsementSummary
    }

    struct POIStoryContributor: Identifiable {
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

    struct EngagementSectionModel {
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

    let poi: RatedPOI?
    let reelContext: ReelContext?
    let isExpanded: Bool
    let userProvider: (UUID) -> User?
    let autoPresentRecentStories: Bool
    @State var autoStoryViewerState: POIStoryViewerState?
    @State var hasTriggeredAutoStory = false

    init(
        ratedPOI: RatedPOI,
        isExpanded: Bool,
        autoPresentRecentStories: Bool = false,
        userProvider: @escaping (UUID) -> User? = { _ in nil }
    ) {
        self.poi = ratedPOI
        self.reelContext = nil
        self.isExpanded = isExpanded
        self.autoPresentRecentStories = autoPresentRecentStories
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
        self.autoPresentRecentStories = false
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
        .onAppear {
            logPOIDebug(event: "onAppear", data: currentData)
            triggerAutoStoryIfNeeded(with: currentData)
        }
        .onChange(of: poi?.id) { _ in
            autoStoryViewerState = nil
            hasTriggeredAutoStory = false
            guard autoPresentRecentStories else { return }
            let latestData = contentData(for: currentMode)
            logPOIDebug(event: "poiChanged", data: latestData)
            triggerAutoStoryIfNeeded(with: latestData)
        }
        .fullScreenCover(item: $autoStoryViewerState) { state in
            POIStoryViewer(
                contributors: currentData.recentSharers,
                initialIndex: state.contributorIndex,
                accentColor: currentData.accentColor
            ) {
                autoStoryViewerState = nil
            }
        }
    }
}

#if DEBUG
extension ExperienceDetailView {
    func logPOIDebug(event: String, data: ContentData) {
        let currentPOI = poi?.poi.name ?? "nil"
        let sharers = data.recentSharers.count
        print("[ExperienceDetailView] \(event) poi=\(currentPOI) id=\(poi?.id.uuidString ?? "nil") autoPresent=\(autoPresentRecentStories) sharers=\(sharers)")
    }
}
#else
extension ExperienceDetailView {
    func logPOIDebug(event: String, data: ContentData) {}
}
#endif

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

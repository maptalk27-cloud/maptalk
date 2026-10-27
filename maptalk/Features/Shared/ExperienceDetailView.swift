import AVKit
import MapKit
import SwiftUI

private struct BackendSafetyMenuTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 16
}

extension EnvironmentValues {
    var backendSafetyMenuTrailingInset: CGFloat {
        get { self[BackendSafetyMenuTrailingInsetKey.self] }
        set { self[BackendSafetyMenuTrailingInsetKey.self] = newValue }
    }
}

struct ExperienceDetailView: View {
    enum Mode {
        case real(RealPost, User?)
        case poi(RatedPOI)
        case journey(JourneyPost)
    }

    struct SequencePager {
        struct Item: Identifiable {
            let id: UUID
            let mode: Mode
        }

        let items: [Item]

        init(items: [Item]) {
            self.items = items
        }
    }

    struct SequenceContext {
        let pager: SequencePager
        var selection: Binding<UUID>
    }

    struct ContentData {
        let hero: HeroSectionModel?
        let journey: JourneyCardModel?
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

    struct JourneyCardModel {
        let journey: JourneyPost
        let user: User?
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
        var commentTarget: BackendCommentTarget? = nil
    }

    struct POIStoryContributor: Identifiable {
        struct Item: Identifiable {
            let id: UUID
            let media: MediaDisplayItem
            let timestamp: Date
            let readKey: String
        }

        let id: UUID
        let userId: UUID
        let user: User?
        let items: [Item]
        let mostRecent: Date

        var readKeys: [String] {
            items.reduce(into: [String]()) { keys, item in
                if keys.contains(item.readKey) == false {
                    keys.append(item.readKey)
                }
            }
        }
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
    let standaloneMode: Mode?
    let sequenceContext: SequenceContext?
    let isExpanded: Bool
    let onCollapsedTap: (() -> Void)?
    let onJourneyAvatarStackTap: ((JourneyPost) -> Void)?
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool
    @Environment(\.appEnv) private var environment
    @Environment(\.friendStoryPlaybackEnabled) private var parentPlaybackEnabled
    @Environment(\.friendStoryExpectedMedia) var storyExpectedMedia
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @Environment(\.backendSafetyMenuTrailingInset) private var safetyMenuTrailingInset
    @State private var storyViewerState: POIStoryViewerState?
    @State private var selectedProfileContext: UserMapViewModel.Context?
    @State var editedCaptions: [UUID: String] = [:]
    @State private var isEditingCaption = false
    @State private var childPresentationID = UUID()

    init(
        mode: Mode,
        isExpanded: Bool = true,
        onCollapsedTap: (() -> Void)? = nil,
        onJourneyAvatarStackTap: ((JourneyPost) -> Void)? = nil,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { _ in nil },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        onPOIContributorViewed: @escaping ([String]) -> Void = { _ in },
        isPOIContributorUnseen: @escaping ([String]) -> Bool = { _ in true }
    ) {
        if case let .poi(ratedPOI) = mode {
            self.poi = ratedPOI
        } else {
            self.poi = nil
        }
        self.standaloneMode = mode
        self.sequenceContext = nil
        self.isExpanded = isExpanded
        self.onCollapsedTap = onCollapsedTap
        self.onJourneyAvatarStackTap = onJourneyAvatarStackTap
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.onPOIContributorViewed = onPOIContributorViewed
        self.isPOIContributorUnseen = isPOIContributorUnseen
    }

    init(
        ratedPOI: RatedPOI,
        isExpanded: Bool,
        onCollapsedTap: (() -> Void)? = nil,
        onJourneyAvatarStackTap: ((JourneyPost) -> Void)? = nil,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { PreviewData.journey(for: $0) },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        onPOIContributorViewed: @escaping ([String]) -> Void = { _ in },
        isPOIContributorUnseen: @escaping ([String]) -> Bool = { _ in true }
    ) {
        self.poi = ratedPOI
        self.standaloneMode = nil
        self.sequenceContext = nil
        self.isExpanded = isExpanded
        self.onCollapsedTap = onCollapsedTap
        self.onJourneyAvatarStackTap = onJourneyAvatarStackTap
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.onPOIContributorViewed = onPOIContributorViewed
        self.isPOIContributorUnseen = isPOIContributorUnseen
    }

    init(
        sequencePager: SequencePager,
        selection: Binding<UUID>,
        isExpanded: Bool,
        onCollapsedTap: (() -> Void)? = nil,
        onJourneyAvatarStackTap: ((JourneyPost) -> Void)? = nil,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { PreviewData.journey(for: $0) },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        onPOIContributorViewed: @escaping ([String]) -> Void = { _ in },
        isPOIContributorUnseen: @escaping ([String]) -> Bool = { _ in true }
    ) {
        self.poi = nil
        self.standaloneMode = nil
        self.sequenceContext = SequenceContext(pager: sequencePager, selection: selection)
        self.isExpanded = isExpanded
        self.onCollapsedTap = onCollapsedTap
        self.onJourneyAvatarStackTap = onJourneyAvatarStackTap
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.onPOIContributorViewed = onPOIContributorViewed
        self.isPOIContributorUnseen = isPOIContributorUnseen
    }

    var body: some View {
        let currentData = contentData(for: currentMode)

        Group {
            if isExpanded {
                expandedContent(using: currentData)
            } else {
                collapsedPreview(using: currentData)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Media is decoration behind the card, not a layout sibling. In
        // particular, a full-resolution portrait poster must not enlarge the
        // sheet and push its author/footer outside the compact detent.
        .background {
            background(for: currentData, isExpanded: isExpanded)
                .accessibilityHidden(true)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if isExpanded, let backend = environment.backend, !actionablePosts.isEmpty {
                BackendContentSafetyMenu(store: backend, posts: actionablePosts,
                    onCaptionEdited: { editedCaptions[$0.id] = $0.caption },
                    onEditorVisibilityChanged: { isEditingCaption = $0 })
                    .padding([.top, .leading, .bottom], 16)
                    .padding(.trailing, safetyMenuTrailingInset)
            }
        }
        .onAppear {
            logPOIDebug(event: "onAppear", data: currentData)
        }
        .onChangeCompat(of: hasPresentedChildContent) { presented in
            childPresentationChanged?(childPresentationID, presented)
        }
        .onDisappear {
            if !hasPresentedChildContent { childPresentationChanged?(childPresentationID, false) }
        }
        .fullScreenCover(item: $storyViewerState) { state in
            let refreshedData = contentData(for: currentMode)
            POIStoryViewer(
                contributors: refreshedData.recentSharers,
                initialIndex: min(state.contributorIndex, max(refreshedData.recentSharers.count - 1, 0)),
                accentColor: refreshedData.accentColor,
                onUserSelected: openProfile,
                onPageViewed: { readKey in
                    onPOIContributorViewed([readKey])
                }
            ) {
                storyViewerState = nil
            }
            .environment(\.friendStoryExpectedMedia, [])
            .environment(\.friendStoryOnMediaReady, nil)
            .environment(\.friendStoryPlaybackEnabled, true)
            .environment(\.friendStoryChildPresentationChanged, nil)
        }
        .fullScreenCover(item: $selectedProfileContext) { context in
            NavigationStack {
                UserProfileView(
                    viewModel: .init(environment: environment, context: context),
                    showsCloseButton: true
                )
            }
            .environment(\.friendStoryExpectedMedia, [])
            .environment(\.friendStoryOnMediaReady, nil)
            .environment(\.friendStoryPlaybackEnabled, true)
            .environment(\.friendStoryChildPresentationChanged, nil)
        }
    }

    var isMediaPlaybackActive: Bool {
        parentPlaybackEnabled && storyViewerState == nil && selectedProfileContext == nil && !isEditingCaption
    }

    private var hasPresentedChildContent: Bool {
        storyViewerState != nil || selectedProfileContext != nil || isEditingCaption
    }

    func openRecentSharer(at index: Int, using data: ContentData) {
        guard data.recentSharers.indices.contains(index) else { return }
        storyViewerState = POIStoryViewerState(contributorIndex: index)
    }

    func openProfile(for user: User) {
        selectedProfileContext = .profileContext(for: user)
    }

    private var actionablePosts: [BackendContentSafetyMenu.Post] {
        guard let backend = environment.backend else { return [] }
        switch currentMode {
        case let .real(post, _):
            return [.init(id: post.id, ownerID: post.userId, title: "Post")]
        case let .poi(place):
            return place.checkIns.map {
                .init(id: $0.id, ownerID: $0.userId,
                      title: "\($0.userId == backend.user.id ? "Your check-in" : "@\(backend.user(for: $0.userId)?.handle ?? "member")") · \($0.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))")
            }
        case .journey: return []
        }
    }
}


#if DEBUG
extension ExperienceDetailView {
    func logPOIDebug(event: String, data: ContentData) {
        let currentPOI = poi?.poi.name ?? "nil"
        let sharers = data.recentSharers.count
        print("[ExperienceDetailView] \(event) poi=\(currentPOI) id=\(poi?.id.uuidString ?? "nil") sharers=\(sharers)")
    }
}
#else
extension ExperienceDetailView {
    func logPOIDebug(event: String, data: ContentData) {}
}
#endif

#if DEBUG
@MainActor
struct ExperienceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let items = PreviewData.sampleReals.map {
            ExperienceDetailView.SequencePager.Item(
                id: $0.id,
                mode: .real($0, PreviewData.user(for: $0.userId))
            )
        }
        let pager = ExperienceDetailView.SequencePager(items: items)
        ExperienceDetailView(
            sequencePager: pager,
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

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

    /// A story selects one authentic visit slice without changing the shared
    /// place's metadata, statistics or discussion. A nil media value is an
    /// intentionally empty slice, including media that has not downloaded yet.
    struct POIStorySelection {
        let checkIn: RatedPOI.CheckIn
        let media: RatedPOI.Media?
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
        var directionsDestination: MapDirectionsDestination? = nil
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
    let usesClassicPostPreview: Bool
    let recordsActiveCompactViewportOnly: Bool
    let poiStorySelection: POIStorySelection?
    /// Personal browsing opens the owner's latest visit, while an explicit
    /// map-pin selection can still ask for the shared place overview.
    let poiBrowsingUserID: UUID?
    let poiOverviewID: UUID?
    // A featured story slice does not filter the shared place's visitor history.
    let expandedPOIMedia: RatedPOI.Media?
    // Person stories can supply their one existing pager as the media slot.
    // The place heading, statistics and discussion remain outside that pager.
    let expandedPOIMediaContent: AnyView?
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.postCardPalette) private var postCardPalette
    @Environment(\.colorScheme) private var inheritedCardColorScheme
    @Environment(\.profileCardSheetMotion) private var profileCardSheetMotion
    @Environment(\.postCompactViewportSize) private var postCompactViewportSize
    @AppStorage(PostCardPalette.storageKey) private var preferredPostCardPalette: PostCardPalette = .white
    @State private var storyViewerState: POIStoryViewerState?
    @State private var selectedProfileContext: UserMapViewModel.Context?
    @State var editedCaptions: [UUID: String] = [:]
    @State private var isEditingCaption = false
    @State private var childPresentationID = UUID()
    @State private var compactPostCardSizes: [PostMediaLayoutReference.Key: CGSize] = [:]
    @State private var measuredCompactPostCardSizes: [PostMediaLayoutReference.Key: CGSize] = [:]
    @State private var postEngagementRequest: PostEngagementRequest?

    init(
        mode: Mode,
        isExpanded: Bool = true,
        usesClassicPostPreview: Bool = false,
        recordsActiveCompactViewportOnly: Bool = false,
        poiStorySelection: POIStorySelection? = nil,
        poiBrowsingUserID: UUID? = nil,
        poiOverviewID: UUID? = nil,
        expandedPOIMedia: RatedPOI.Media? = nil,
        expandedPOIMediaContent: AnyView? = nil,
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
        self.usesClassicPostPreview = usesClassicPostPreview
        self.recordsActiveCompactViewportOnly = recordsActiveCompactViewportOnly
        self.poiStorySelection = poiStorySelection
        self.poiBrowsingUserID = poiBrowsingUserID
        self.poiOverviewID = poiOverviewID
        self.expandedPOIMedia = expandedPOIMedia
        self.expandedPOIMediaContent = expandedPOIMediaContent
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
        self.usesClassicPostPreview = false
        self.recordsActiveCompactViewportOnly = false
        self.poiStorySelection = nil
        self.poiBrowsingUserID = nil
        self.poiOverviewID = nil
        self.expandedPOIMedia = nil
        self.expandedPOIMediaContent = nil
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
        usesClassicPostPreview: Bool = false,
        poiBrowsingUserID: UUID? = nil,
        poiOverviewID: UUID? = nil,
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
        self.usesClassicPostPreview = usesClassicPostPreview
        self.recordsActiveCompactViewportOnly = false
        self.poiStorySelection = nil
        self.poiBrowsingUserID = poiBrowsingUserID
        self.poiOverviewID = poiOverviewID
        self.expandedPOIMedia = nil
        self.expandedPOIMediaContent = nil
        self.onCollapsedTap = onCollapsedTap
        self.onJourneyAvatarStackTap = onJourneyAvatarStackTap
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.onPOIContributorViewed = onPOIContributorViewed
        self.isPOIContributorUnseen = isPOIContributorUnseen
    }

    var body: some View {
        if usesClassicPostPreview, let context = sequenceContext {
            classicSequenceContent(context)
        } else {
            experienceContent
        }
    }

    private var experienceContent: some View {
        let currentData = contentData(for: currentMode)

        return Group {
            if isExpanded {
                expandedContent(using: currentData)
            } else {
                collapsedPreview(using: currentData)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.postEngagementRequest, postEngagementRequest)
        .environment(\.openPostEngagement, { postID, section in
            postEngagementRequest = PostEngagementRequest(postID: postID, section: section)
            if !isExpanded { onCollapsedTap?() }
        })
        .environment(\.postMediaLayoutReference, PostMediaLayoutReference(
            resolveCard: { postID, count in
                PostMediaLayoutReference.resolvedCardSize(
                    viewport: postCompactViewportSize,
                    recorded: compactPostCardSizes[.init(postID: postID, attachmentCount: count)]
                )
            },
            recordCardSize: rememberCompactPostCardSize
        ))
        // Media is decoration behind the card, not a layout sibling. In
        // particular, a full-resolution portrait poster must not enlarge the
        // sheet and push its author/footer outside the compact detent.
        .background {
            if usesNeutralPreviewBackground {
                PostCardBackdrop().ignoresSafeArea()
            } else {
                background(for: currentData, isExpanded: isExpanded)
                    .accessibilityHidden(true)
            }
        }
        .background((usesNeutralPreviewBackground ? postCardPalette.background : .black).ignoresSafeArea())
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
        .onChangeCompat(of: isExpanded) { expanded in
            // A later ordinary card open starts at its content, not at the
            // likes/comments shortcut used on the previous visit.
            if !expanded { postEngagementRequest = nil }
        }
        .onChangeCompat(of: parentPlaybackEnabled) { enabled in
            // A neighboring page can become current without another geometry
            // change. Adopt its first active compact reference only once; a
            // later native sheet drag must never overwrite it with a tall frame.
            guard recordsActiveCompactViewportOnly, enabled, !isExpanded,
                  PostMediaLayoutReference.validCardSize(postCompactViewportSize) == nil else { return }
            compactPostCardSizes.merge(measuredCompactPostCardSizes) { existing, _ in existing }
        }
        .onChangeCompat(of: verticalSizeClass) { _ in
            // Sheet-backed pages follow their host's resolved compact size,
            // including rotation. A transient UIKit trait change must not
            // erase that reference while the expanded card is being created.
            guard PostMediaLayoutReference.validCardSize(postCompactViewportSize) == nil else { return }
            compactPostCardSizes.removeAll()
            measuredCompactPostCardSizes.removeAll()
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

    /// Profile history is a mixed sequence, not a second card implementation.
    /// Each page owns its original media state and compact measurements across
    /// detent changes, and receives only the palette appropriate to that page.
    private func classicSequenceContent(_ context: SequenceContext) -> some View {
        Group {
            if let motion = profileCardSheetMotion {
                ProfileSequencePager(items: context.pager.items,
                    selection: context.selection, isExpanded: isExpanded, motion: motion,
                    background: { item in
                        if case .real = item.mode { return preferredPostCardPalette.background }
                        return .black
                    }) { item in
                        classicSequencePage(item, context: context)
                    }
            } else if context.pager.items.count == 1, let item = context.pager.items.first {
                classicSequencePage(item, context: context)
            } else {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        classicSequencePage(item, context: context)
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .background(isClassicPostPreview ? preferredPostCardPalette.background : .black)
        // Keep the native pager boundary stable across every page and detent.
        // Its hosted cards already handle their own content safe areas.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func classicSequencePage(
        _ item: SequencePager.Item,
        context: SequenceContext
    ) -> some View {
        let isPost: Bool = {
            if case .real = item.mode { return true }
            return false
        }()
        return ExperienceDetailView(
            mode: item.mode,
            isExpanded: isExpanded,
            usesClassicPostPreview: true,
            recordsActiveCompactViewportOnly: true,
            poiBrowsingUserID: poiBrowsingUserID,
            poiOverviewID: poiOverviewID,
            onCollapsedTap: onCollapsedTap,
            onJourneyAvatarStackTap: onJourneyAvatarStackTap,
            journeyProvider: journeyProvider,
            userProvider: userProvider,
            onPOIContributorViewed: onPOIContributorViewed,
            isPOIContributorUnseen: isPOIContributorUnseen
        )
        .environment(\.postCardPalette, isPost ? preferredPostCardPalette : .white)
        .environment(\.colorScheme, isPost ? preferredPostCardPalette.colorScheme : inheritedCardColorScheme)
        .environment(\.friendStoryPlaybackEnabled,
                     isMediaPlaybackActive && context.selection.wrappedValue == item.id)
        .background(isPost ? preferredPostCardPalette.background : .black)
        .background(ExperiencePagerVerticalBounceGuard())
        .accessibilityHidden(context.selection.wrappedValue != item.id)
        .id(item.id)
    }

    var isMediaPlaybackActive: Bool {
        parentPlaybackEnabled && storyViewerState == nil && selectedProfileContext == nil && !isEditingCaption
    }

    var isClassicPostPreview: Bool {
        guard usesClassicPostPreview, case .real = currentMode else { return false }
        return true
    }

    private func rememberCompactPostCardSize(_ size: CGSize, postID: UUID, count: Int) {
        guard isClassicPostPreview, !isExpanded, count >= 0,
              PostMediaLayoutReference.validCardSize(postCompactViewportSize) == nil,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }

        let key = PostMediaLayoutReference.Key(postID: postID, attachmentCount: count)
        guard compactPostCardSizes[key] == nil else { return }
        if recordsActiveCompactViewportOnly, !isMediaPlaybackActive {
            if measuredCompactPostCardSizes[key] != size { measuredCompactPostCardSizes[key] = size }
            return
        }
        compactPostCardSizes[key] = size
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
            return poiStoryCheckIns(for: place).map {
                .init(id: $0.id, ownerID: $0.userId,
                      title: "\($0.userId == backend.user.id ? "Your check-in" : "@\(backend.user(for: $0.userId)?.handle ?? "member")") · \($0.activityDate.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))")
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

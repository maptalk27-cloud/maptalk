import SwiftUI
import UIKit

private struct FriendStoryPlaybackEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct FriendStoryMediaReadyKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

private struct FriendStoryExpectedMediaKey: EnvironmentKey {
    static var defaultValue: [FriendStoryMediaDescriptor] { [] }
}

private struct FriendStoryChildPresentationKey: EnvironmentKey {
    static var defaultValue: ((UUID, Bool) -> Void)? { nil }
}

extension EnvironmentValues {
    /// A nested place, media viewer or Bubble owns playback until it returns.
    var friendStoryPlaybackEnabled: Bool {
        get { self[FriendStoryPlaybackEnabledKey.self] }
        set { self[FriendStoryPlaybackEnabledKey.self] = newValue }
    }

    /// Rendering a real frame is different from downloading its metadata.
    var friendStoryOnMediaReady: (() -> Void)? {
        get { self[FriendStoryMediaReadyKey.self] }
        set { self[FriendStoryMediaReadyKey.self] = newValue }
    }

    var friendStoryExpectedMedia: [FriendStoryMediaDescriptor] {
        get { self[FriendStoryExpectedMediaKey.self] }
        set { self[FriendStoryExpectedMediaKey.self] = newValue }
    }

    var friendStoryChildPresentationChanged: ((UUID, Bool) -> Void)? {
        get { self[FriendStoryChildPresentationKey.self] }
        set { self[FriendStoryChildPresentationKey.self] = newValue }
    }
}

/// The existing story rail's size, spacing and read-ring language, now one
/// button per author instead of one per Reel or shared place.
struct FriendStoriesRow: View {
    static let layoutHeight = RealStoriesRow.layoutHeight

    let groups: [FriendStoryGroup]
    let selectedAuthorID: UUID?
    let userProvider: (UUID) -> User?
    let isUnseen: (FriendStoryGroup) -> Bool
    let onSelect: (UUID) -> Void
    var usesLightLabels: Bool = false
    var transitionNamespace: Namespace.ID? = nil

    var body: some View {
        Group {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(groups) { group in
                        let user = userProvider(group.authorID) ?? group.user
                        let selected = selectedAuthorID == group.authorID
                        Button { onSelect(group.authorID) } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    StoryStatusCircleRing(
                                        diameter: 68,
                                        isUnseen: isUnseen(group),
                                        unreadLineWidth: 2.6,
                                        seenLineWidth: 1.5,
                                        unreadShadowRadius: 7
                                    )
                                    .opacity(selected ? 1 : 0.82)
                                    // Keep faces opaque above the map; only the
                                    // status ring changes emphasis on selection.
                                    FriendStoryAvatar(user: user, diameter: 60)
                                        .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                                }
                                .frame(width: 70, height: 70)
                                .modifier(MapTalkPOITransitionSource(
                                    id: .author(group.authorID), namespace: transitionNamespace,
                                    keepsSourceVisible: true))

                                Text(user?.handle ?? "Member")
                                    .font(.caption2.weight(usesLightLabels ? .medium : .thin))
                                    .foregroundStyle(usesLightLabels ? .white : .black)
                                    .shadow(color: .black.opacity(usesLightLabels ? 0.9 : 0), radius: 2, y: 1)
                                    .lineLimit(1)
                                    .padding(.vertical, 2)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(user?.handle ?? "Member"), \(group.moments.count) updates")
                        .accessibilityValue(isUnseen(group) ? "Unread" : "Viewed")
                        .accessibilityIdentifier("friend-story.author.\(group.authorID.uuidString)")
                        .id(group.authorID)
                    }
                }
                .padding(.horizontal, 12)
            }
            // Even one avatar keeps the rail's natural drag-and-return feel.
            // Let its artwork overflow during the bounce instead of clipping.
            .scrollBounceBehavior(.always, axes: .horizontal)
            .scrollClipDisabled()
            // Selecting or swiping a person's card must not recenter this rail.
            // Its scroll position belongs exclusively to the user's drag.
        }
        .frame(height: Self.layoutHeight)
        // A short rail must not claim the empty map beside its avatars.
        .frame(maxWidth: CGFloat(groups.count) * 72
            + CGFloat(max(0, groups.count - 1)) * 16 + 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("maptalk.friend-story.rail")
    }
}

/// Reuses the original cards for person stories and the separate Posts feed.
/// Cards keep ownership of media, comments, author controls and Bubbles.
struct FriendStoryContentView: View {
    let group: FriendStoryGroup
    let page: FriendStoryPage
    let pageIndex: Int
    let pagerPages: [FriendStoryPage]
    let pagerUserProvider: (UUID) -> User?
    let selectedPageID: Binding<String>
    let viewedKeys: Set<String>
    let isExpanded: Bool
    let isPlaybackActive: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onSelectPage: (Int) -> Void
    let onExpand: () -> Void
    let onClose: () -> Void
    let onJourney: (JourneyPost, FriendStoryPage) -> Void
    let onReadReady: (String) -> Void
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let placeProvider: (UUID) -> RatedPOI?
    var feedPresentation: MapTalkFeedPresentation = .personStory
    var showsFloatingHeader = true
    var showsVisitExpression = false
    var showsPersonalVisitCount = false
    var personalVisitCountLabel: String? = nil
    var allowsLoadedVisitCountFallback = true
    var showsHeaderTimestamp = true
    var placeAuthors: [User] = []
    var allowsPOIMediaLightbox = true
    var mediaExpression: AnyView? = nil
    var mediaDecoration: ((RatedPOI.Media) -> AnyView)? = nil

    @Environment(\.experiencePOIPlaybackActions) private var playbackActions
    @Environment(\.experiencePOIHeaderActions) private var headerActions
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @Environment(\.postCardPalette) private var postCardPalette
    @Environment(\.profileCardSheetMotion) private var sheetMotion
#if DEBUG
    @Environment(\.poiVisitCountPreviewStyle) private var visitCountPreviewStyle
#endif
    @State private var readyPageIDs: Set<String> = []
    @State private var selectedProfile: UserMapViewModel.Context?
    @State private var isKeyboardVisible = false
    @State private var activeChildPresentations: Set<UUID> = []
    @State private var mediaLoadFailures: Set<UUID> = []

    private var author: User? { userProvider(group.authorID) ?? group.user }
    private var playbackEnabled: Bool {
        isPlaybackActive && scenePhase == .active
            && selectedProfile == nil && !isKeyboardVisible && activeChildPresentations.isEmpty
    }
    private var canNavigate: Bool {
        isPlaybackActive && selectedProfile == nil
            && !isKeyboardVisible && activeChildPresentations.isEmpty
    }

    private var mediaRequestID: UUID? { playbackEnabled ? page.memoryID : nil }

    private var showsFullBleedPOIPreview: Bool {
        if case .poi = page.content { return true }
        return false
    }

    var body: some View {
        postPager
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .overlay(alignment: .bottom) {
                if feedPresentation == .personStory, !isExpanded, mediaPlaybackFooter == nil,
                   let momentIndex = group.momentIndex(containing: pageIndex),
                   group.moments[momentIndex].placeID != nil {
                    let range = group.moments[momentIndex].pageRange
                    FriendStoryPlacePageDots(count: range.count,
                        index: pageIndex - range.lowerBound)
                        .padding(.bottom, showsFullBleedPOIPreview ? 24 : 12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let mediaPlaybackFooter {
                    mediaPlaybackFooter
                        .environment(\.friendStoryChildPresentationChanged, childPresentationChanged)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        .background(feedPresentation == .posts
            ? postCardPalette.background : .black)
        // Match the Bubble Post viewport for every media type. Switching
        // photo/text ↔ video must not change the pager's safe-area geometry.
        // POI keeps its existing full-bleed rule.
        .ignoresSafeArea(.container, edges: feedPresentation == .posts || showsFullBleedPOIPreview ? .bottom : [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(feedPresentation == .posts ? "maptalk.posts.card" : "friend-story.card")
        .accessibilityValue(isExpanded ? "Expanded" : "Compact")
        .accessibilityAction(.escape, onClose)
        .modifier(FriendStoryCardHeader(
            isEnabled: feedPresentation == .personStory && showsFloatingHeader,
            isVisible: isPlaybackActive && selectedProfile == nil && activeChildPresentations.isEmpty,
            backgroundMaterial: showsPersonalVisitCount && showsHeaderTimestamp ? .thin : .regular,
            backgroundTint: showsPersonalVisitCount && !showsHeaderTimestamp
                ? Color(white: 0.08).opacity(0.65) : .clear
        ) {
            navigationHeader
                .environment(\.colorScheme, .dark)
                .environment(\.appEnv, environment)
        })
        .onChangeCompat(of: page.id) { _ in
            activeChildPresentations.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .task(id: mediaRequestID) {
            guard let id = mediaRequestID, let backend = environment.backend else { return }
            // Adjacent pages stay mounted for swiping. Only the selected
            // memory requests its video; metadata and cached photos show first.
            do {
                _ = try await backend.ensureMedia(for: [id])
                mediaLoadFailures.remove(id)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { mediaLoadFailures.insert(id) } }
        }
        .task(id: readinessTaskID) {
            guard canMarkViewed else { return }
            // A canceled page switch or an offscreen parent must not clear its
            // unread ring merely because an image happened to finish loading.
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, canMarkViewed else { return }
            onReadReady(page.readKey)
        }
        .fullScreenCover(item: $selectedProfile) { context in
            NavigationStack {
                UserProfileView(
                    viewModel: .init(environment: environment, context: context),
                    showsCloseButton: true
                )
            }
            .environment(\.friendStoryPlaybackEnabled, true)
            .environment(\.friendStoryExpectedMedia, [])
            .environment(\.friendStoryOnMediaReady, nil)
            .environment(\.friendStoryChildPresentationChanged, nil)
        }
    }

    private var navigationHeader: some View {
        FriendStoryNavigationHeader(author: author, group: group, page: page,
            pageIndex: pageIndex, canNavigate: canNavigate,
            onAuthor: {
                if let author { selectedProfile = .profileContext(for: author) }
            },
            onPreviousPage: onPreviousPage, onNextPage: onNextPage,
            onSelectPage: onSelectPage, onClose: onClose, trailingActions: headerActions,
            showsVisitExpression: showsVisitExpression,
            showsPersonalVisitCount: showsPersonalVisitCount,
            personalVisitCountLabel: personalVisitCountLabel,
            allowsLoadedVisitCountFallback: allowsLoadedVisitCountFallback,
            showsTimestamp: showsHeaderTimestamp,
            placeAuthors: placeAuthors)
#if DEBUG
            .environment(\.poiVisitCountPreviewStyle, visitCountPreviewStyle)
#endif
    }

    private var pageSelection: Binding<String> {
        Binding(get: { selectedPageID.wrappedValue }, set: { id in
            guard canNavigate, id != selectedPageID.wrappedValue,
                  pagerPages.contains(where: { $0.id == id }) else { return }
            selectedPageID.wrappedValue = id
        })
    }

    private var poiChromePages: [FriendStoryPOIChromePage] {
        pagerPages.map(FriendStoryPOIChromePage.storyPage)
    }

    @ViewBuilder
    private var postPager: some View {
        if feedPresentation == .posts, let sheetMotion {
            stablePostPager(motion: sheetMotion)
        } else if case .poi = page.content {
            // Expanding changes the viewport, not the content system. The
            // exact same media pager and fixed chrome own both detents.
            if isExpanded {
                nativePostPager(mediaOnly: true)
                .environment(\.friendStoryChildPresentationChanged, childPresentationChanged)
            } else {
                compactPOIPager(mediaOnly: true)
                    .environment(\.friendStoryChildPresentationChanged, childPresentationChanged)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("friend-story.poi.preview")
            }
        } else {
            if feedPresentation == .personStory, !isExpanded {
                compactPOIPager(mediaOnly: false)
            } else {
                nativePostPager(mediaOnly: false)
            }
        }
    }

    @ViewBuilder
    private func compactPOIPager(mediaOnly: Bool) -> some View {
        if let sheetMotion {
            FriendStoryCompactPOICanvas(motion: sheetMotion, includesBottomSafeArea: mediaOnly) {
                nativePostPager(mediaOnly: mediaOnly)
            }
        } else {
            nativePostPager(mediaOnly: mediaOnly)
        }
    }

    private func stablePostPager(motion: ProfileCardSheetMotion) -> some View {
        let pagesByMemory = Dictionary(pagerPages.map { ($0.memoryID, $0) },
            uniquingKeysWith: { first, _ in first })
        let items = pagerPages.compactMap { candidate -> ExperienceDetailView.SequencePager.Item? in
            guard case let .reel(real) = candidate.content else { return nil }
            return .init(id: candidate.memoryID,
                mode: .real(real, pagerUserProvider(candidate.authorID)))
        }
        let placeGroups = PostPlaceGrouping.groups(items.compactMap { item in
            if case let .real(post, _) = item.mode { return post }
            return nil
        }, mode: .consecutive)
        return ProfileSequencePager(items: items,
            selection: Binding(get: {
                pagerPages.first(where: { $0.id == selectedPageID.wrappedValue })?.memoryID ?? page.memoryID
            }, set: { identifier in
                guard let candidate = pagesByMemory[identifier] else { return }
                pageSelection.wrappedValue = candidate.id
            }),
            isExpanded: isExpanded, motion: motion, isActive: playbackEnabled,
            usesFixedCompactCanvas: true,
            background: { _ in postCardPalette.background }) { item in
                if let candidate = pagesByMemory[item.id] {
                    preparedPage(candidate, mediaOnly: false)
                }
            }
            .fixedPostPlaceChrome(groups: placeGroups,
                selectedID: pagerPages.first(where: { $0.id == selectedPageID.wrappedValue })?.memoryID
                    ?? page.memoryID, isExpanded: isExpanded)
            .accessibilityIdentifier("friend-story.post-pager")
    }

    /// Actions and position share one bottom anchor in both media sizes.
    private var mediaPlaybackFooter: AnyView? {
        if let mediaExpression {
            // Expression floats above the same media footer at either detent.
            // It must not change the action row's size or move the page dots.
            return AnyView(Group {
                if let playbackActions {
                    playbackActions
                } else {
                    Color.clear.frame(height: 44).allowsHitTesting(false)
                }
            }
            .overlay { placePageDots }
            .overlay(alignment: .bottomLeading) {
                mediaExpression
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -60)
                    .allowsHitTesting(false)
            }
            .padding(.bottom, 8))
        }
        guard let playbackActions else { return nil }
        return AnyView(playbackActions
            .overlay { placePageDots }
            .padding(.bottom, 8))
    }

    @ViewBuilder
    private var placePageDots: some View {
        if let momentIndex = group.momentIndex(containing: pageIndex),
           group.moments[momentIndex].placeID != nil {
            let range = group.moments[momentIndex].pageRange
            FriendStoryPlacePageDots(count: range.count, index: pageIndex - range.lowerBound)
                .allowsHitTesting(false)
        }
    }

    private func childPresentationChanged(_ id: UUID, _ presented: Bool) {
        if presented { activeChildPresentations.insert(id) }
        else { activeChildPresentations.remove(id) }
    }

    private func nativePostPager(mediaOnly: Bool) -> some View {
        // Each swipe advances one update, including across people at the edge.
        // Keep a single native pager rather than nesting a pager per author.
        let chromePages = mediaOnly ? poiChromePages : []
        let chromeRun = FriendStoryPOIChromeRun(pages: chromePages, selectedID: page.id)
        let postPlaceGroups = feedPresentation == .posts ? PostPlaceGrouping.groups(
            pagerPages.compactMap { candidate in
                if case let .reel(post) = candidate.content { return post }
                return nil
            }, mode: .consecutive) : []
        return TabView(selection: pageSelection) {
            ForEach(pagerPages) { candidate in
                preparedPage(candidate, mediaOnly: mediaOnly, chromeRun: chromeRun)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .postPlaceChromePage(postID: candidate.memoryID)
                    .tag(candidate.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("friend-story.post-pager")
        .fixedPOIChrome(pages: chromePages, selectedID: page.id)
        .fixedPostPlaceChrome(groups: postPlaceGroups, selectedID: page.memoryID, isExpanded: isExpanded)
    }

    private func preparedPage(_ candidate: FriendStoryPage, mediaOnly: Bool,
                              chromeRun: FriendStoryPOIChromeRun? = nil) -> some View {
        Group {
            if mediaOnly { mediaPage(for: candidate, chromeRun: chromeRun) }
            else { content(for: candidate) }
        }
                    .environment(\.poiMediaLightboxEnabled, allowsPOIMediaLightbox)
                    // The selected visit owns one fixed footer outside this
                    // pager. Adjacent mounted pages must not repeat its time
                    // or directions while a swipe is still settling.
                    .environment(\.experiencePOIPlaybackActions,
                                 feedPresentation == .personStory ? nil : playbackActions)
                    .background(ExperiencePagerVerticalBounceGuard())
                    // Native paging keeps adjacent cards mounted. Only the
                    // selected card may play, mark read or present a child.
                    .environment(\.friendStoryPlaybackEnabled, playbackEnabled && candidate.id == page.id)
                    .environment(\.friendStoryExpectedMedia, candidate.expectedMedia)
                    .environment(\.friendStoryOnMediaReady, { noteReady(for: candidate.id) })
                    .environment(\.friendStoryChildPresentationChanged, { id, presented in
                        guard candidate.id == page.id else { return }
                        if presented { activeChildPresentations.insert(id) }
                        else { activeChildPresentations.remove(id) }
                    })
                    .accessibilityHidden(!isPlaybackActive || candidate.id != page.id)
    }

    @ViewBuilder
    private func mediaPage(for candidate: FriendStoryPage, chromeRun: FriendStoryPOIChromeRun?) -> some View {
        if case let .poi(place, _, media) = candidate.content, let media {
            Group {
                FriendStoryPOIPreview(place: place, media: media,
                    isPlaybackActive: playbackEnabled && candidate.id == page.id,
                    showsPlaceChrome: chromeRun?.contains(candidate.id) != true,
                    chromePageID: candidate.id,
                    onMediaTap: isExpanded || allowsPOIMediaLightbox ? nil : onExpand)
            }
            .overlay {
                // A per-media sample travels with its image/video, separately
                // from the selected visit's fixed feeling footer.
                if let mediaDecoration {
                    mediaDecoration(media).allowsHitTesting(false)
                }
            }
        } else if case let .poi(place, _, _) = candidate.content {
            ZStack {
                Color(white: 0.12)
                VStack(spacing: 10) {
                    if candidate.kind == .poiLocationOnly {
                        // This visit legitimately has no image/video. Its
                        // feeling, comment and actions remain in the chrome.
                        EmptyView()
                    } else if mediaLoadFailures.contains(candidate.memoryID) {
                        Text("Media is unavailable right now")
                        Button("Try again") {
                            Task {
                                guard candidate.id == page.id, let store = environment.backend else { return }
                                do {
                                    _ = try await store.ensureMedia(for: [candidate.memoryID])
                                    mediaLoadFailures.remove(candidate.memoryID)
                                } catch { mediaLoadFailures.insert(candidate.memoryID) }
                            }
                        }
                    } else {
                        ProgressView().tint(.white)
                        Text("Loading this visit’s media…")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                if chromeRun?.contains(candidate.id) != true {
                    FriendStoryPOIChrome(place: place)
                }
            }
            .poiChromePageAnchor(id: candidate.id)
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            // The adjacent original card remains in the same native sequence.
            // Completing the boundary swipe selects it through the original
            // navigation binding, which also preserves map flight.
            content(for: candidate)
        }
    }

    @ViewBuilder
    private func content(for candidate: FriendStoryPage) -> some View {
        switch candidate.content {
        case let .reel(real):
            ExperienceDetailView(
                mode: .real(displayedReel(real), pagerUserProvider(candidate.authorID)),
                isExpanded: isExpanded,
                usesClassicPostPreview: feedPresentation == .posts,
                recordsActiveCompactViewportOnly: feedPresentation == .posts,
                onCollapsedTap: onExpand,
                onJourneyAvatarStackTap: { onJourney($0, candidate) },
                journeyProvider: journeyProvider,
                userProvider: userProvider
            )
            .overlay(alignment: .bottomTrailing) {
                if !candidate.isMediaReady {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading media")
                }
            }
        case let .poi(place, checkIn, media):
            Group {
                if !isExpanded, let media {
                    FriendStoryPOIPreview(place: place, media: media,
                        isPlaybackActive: playbackEnabled && candidate.id == page.id,
                        onMediaTap: allowsPOIMediaLightbox ? nil : onExpand)
                } else {
                    // Keep the original place page; feature this exact slice
                    // inside it without filtering other visitors or history.
                    ExperienceDetailView(
                        mode: .poi(Self.placeForCard(place, isExpanded: isExpanded, provider: placeProvider)),
                        isExpanded: isExpanded,
                        poiStorySelection: isExpanded ? nil : .init(checkIn: checkIn, media: media),
                        expandedPOIMedia: isExpanded ? media : nil,
                        onCollapsedTap: onExpand,
                        onJourneyAvatarStackTap: { onJourney($0, candidate) },
                        journeyProvider: journeyProvider,
                        userProvider: userProvider,
                        onPOIContributorViewed: { keys in keys.forEach(onReadReady) },
                        isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                    )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !candidate.isMediaReady {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading media")
                }
            }
        }
    }

    static func placeForCard(_ place: RatedPOI, isExpanded: Bool,
                             provider: (UUID) -> RatedPOI?) -> RatedPOI {
        guard isExpanded, let detail = provider(place.id), detail.id == place.id else { return place }
        return detail
    }

    private func displayedReel(_ source: RealPost) -> RealPost {
        // Another entry point (for example the author's profile) can edit the
        // same post while this story stays mounted behind it.
        guard let caption = environment.backend?.ownedMemories[source.id]?.caption else { return source }
        var real = source
        real.message = PostCaption.visibleText(caption)
        return real
    }

    private func noteReady(for id: String) {
        // A native pager can render a neighbor's first frame before selecting
        // it. Remember readiness, but only the active page's delayed task may
        // mark anything viewed (see canMarkViewed).
        guard !readyPageIDs.contains(id) else { return }
        readyPageIDs.insert(id)
    }

    private var hasReadableText: Bool {
        switch page.content {
        case let .reel(real):
            return !(real.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || real.attachments.contains { if case .emoji = $0.kind { return true }; return false }
        case .poi:
            return page.kind == .poiLocationOnly
        }
    }

    private var canMarkViewed: Bool {
        playbackEnabled && (readyPageIDs.contains(page.id) || hasReadableText)
    }

    private var readinessTaskID: String {
        "\(page.id):\(canMarkViewed)"
    }

}

/// Shared author/progress artwork; the containing browser owns navigation and profiles.
struct FriendStoryNavigationHeader: View {
    let author: User?
    let group: FriendStoryGroup
    let page: FriendStoryPage
    let pageIndex: Int
    let canNavigate: Bool
    let onAuthor: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onSelectPage: (Int) -> Void
    let onClose: () -> Void
    var trailingActions: AnyView? = nil
    var showsVisitExpression = false
    var showsPersonalVisitCount = false
    var personalVisitCountLabel: String? = nil
    var allowsLoadedVisitCountFallback = true
    var showsTimestamp = true
    var placeAuthors: [User] = []
    var showsProgress = true
#if DEBUG
    @Environment(\.poiVisitCountPreviewStyle) private var visitCountPreviewStyle
#endif

    private var usesQuietVisitSummary: Bool { showsPersonalVisitCount && !showsTimestamp }
    private var visitComment: String? {
        guard let comment = visitExpression?.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else { return nil }
        return comment
    }

    private var personalVisitTotal: Int? {
        guard showsPersonalVisitCount, case let .poi(place, visit, _) = page.content else { return nil }
        var visitIDs = Set(place.checkIns.filter { $0.userId == visit.userId }.map(\.id))
        visitIDs.insert(visit.id)
        return visitIDs.count
    }

    private var visitExpression: RatedPOI.CheckIn? {
        guard showsVisitExpression, case let .poi(_, visit, _) = page.content,
              visit.endorsement != nil || visit.customEmoji != nil
                || !(visit.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        else { return nil }
        return visit
    }

    var body: some View {
        let momentIndex = group.momentIndex(containing: pageIndex) ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                authorIdentity
                Spacer(minLength: 4)
                if let trailingActions { trailingActions }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: 44)
            .padding(.top, usesQuietVisitSummary ? 2 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("friend-story.author-navigation")
            .accessibilityValue(showsProgress ? "Stop \(momentIndex + 1) of \(group.moments.count)" : "")

            if showsProgress {
                FriendStoryProgressBars(count: group.moments.count,
                                        index: momentIndex, pageID: page.id,
                                        pageIndex: pageIndex, pageCount: group.pages.count,
                                        authorName: author?.handle ?? "Member",
                                        onSelect: { index in
                    guard canNavigate, group.moments.indices.contains(index) else { return }
                    onSelectPage(group.moments[index].pageRange.lowerBound)
                })
                    .frame(height: usesQuietVisitSummary ? 22 : 24)
                    .accessibilityHint("Tap the progress bar to choose an update")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onNextPage()
                        case .decrement: onPreviousPage()
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: "Previous update", onPreviousPage)
                    .accessibilityAction(named: "Next update", onNextPage)
                    .padding(.horizontal, 16)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-story.navigation")
        .accessibilityAction(.escape, onClose)
    }

    private var authorIdentity: some View {
        Button(action: onAuthor) {
            HStack(spacing: showsPersonalVisitCount ? 10 : 8) {
                if placeAuthors.count > 1, let author {
                    FriendStoryPlaceAuthors(author: author, people: placeAuthors)
                } else {
                    FriendStoryAvatar(user: author, diameter: 32)
                }
                if showsPersonalVisitCount {
                    friendVisitIdentity
                } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let visit = visitExpression {
                        HStack(spacing: 8) {
                            authorName
                            personalVisitCount
                            Spacer(minLength: 4)
                            timestamp
                        }
                        HStack(spacing: 5) {
                            if let feeling = visit.endorsement {
                                POIFeedbackIcon(endorsement: feeling, set: .emoji, size: 16)
                                    .fixedSize()
                                    .frame(width: 22, height: 20)
                                    .layoutPriority(1)
                                    .accessibilityLabel(feeling.rawValue)
                            } else if let emoji = visit.customEmoji {
                                POICustomFeelingIcon(emoji: emoji, size: 16)
                                    .frame(width: 22, height: 20)
                                    .layoutPriority(1)
                            }
                            if let comment = visit.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !comment.isEmpty {
                                Text(comment)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .accessibilityIdentifier("friend-story.visit-expression")
                    } else {
                        HStack(spacing: 8) {
                            authorName
                            personalVisitCount
                        }
                        timestamp
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44,
                   alignment: usesQuietVisitSummary ? .bottomLeading : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author == nil)
        .accessibilityIdentifier("friend-story.open-author")
        .accessibilityLabel("View profile")
        .accessibilityValue(author?.handle ?? "Member")
    }

    private var friendVisitIdentity: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: usesQuietVisitSummary ? 3 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    authorName
                    Spacer(minLength: 0)
                    timestamp.opacity(0.8)
                }
                if usesQuietVisitSummary {
                    if let visitComment {
                        visitCommentText(visitComment)
                            .accessibilityIdentifier("friend-story.visit-expression")
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        personalVisitCount
                        if let visitComment {
                            Text("·").foregroundStyle(.white.opacity(0.3))
                            visitCommentText(visitComment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("friend-story.visit-expression")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if usesQuietVisitSummary {
                personalVisitCount
                    .layoutPriority(1)
            }

            if let visit = visitExpression {
                if let feeling = visit.endorsement {
                    FriendStoryFeelingIcon(visitID: visit.id, endorsement: feeling)
                        .layoutPriority(1)
                        .accessibilityLabel(feeling.rawValue)
                        .accessibilityIdentifier("friend-story.visit-feeling")
                } else if let emoji = visit.customEmoji {
                    POICustomFeelingIcon(emoji: emoji, size: 32)
                        .frame(width: 40, height: 40)
                        .layoutPriority(1)
                        .accessibilityIdentifier("friend-story.visit-feeling")
                }
            }
        }
        .frame(height: usesQuietVisitSummary ? 40 : 44)
    }

    private func visitCommentText(_ comment: String) -> some View {
        Text(comment)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(usesQuietVisitSummary ? 0.82 : 0.95))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorName: some View {
        Text(author?.handle ?? "Member")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    @ViewBuilder
    private var timestamp: some View {
        if showsTimestamp {
            Text(page.publishedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .accessibilityIdentifier("friend-story.timestamp")
        }
    }

    @ViewBuilder
    private var personalVisitCount: some View {
        if showsPersonalVisitCount,
           let label = personalVisitCountLabel ?? (allowsLoadedVisitCountFallback
                ? personalVisitTotal.map({ $0 == 1 ? "1 visit" : "\($0) visits" }) : nil) {
            Group {
                if usesQuietVisitSummary, let number = label.split(separator: " ").first {
                    quietVisitCount(String(number))
                } else {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) to this place")
            .accessibilityIdentifier("friend-story.visit-count")
        }
    }

    @ViewBuilder
    private func quietVisitCount(_ number: String) -> some View {
#if DEBUG
        if let visitCountPreviewStyle {
            POIVisitCountPreviewMark(number: number, style: visitCountPreviewStyle)
        } else {
            currentVisitCountMark(number)
        }
#else
        currentVisitCountMark(number)
#endif
    }

    private func currentVisitCountMark(_ number: String) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
            Text(number)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 40)
    }
}

/// Only "Loved it" greets once per visit; all other feelings stay still.
struct FriendStoryFeelingIcon: View {
    let visitID: UUID
    let endorsement: RatedPOI.Endorsement
    var size: CGFloat = 32
    var emphasizesHype = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTrigger = false

    private struct Motion {
        var scale: CGFloat = 1
        var angle: Double = 0
        var lift: CGFloat = 0
    }

    private var motionID: String { "\(visitID)-\(endorsement.rawValue)-\(emphasizesHype)" }
    var body: some View {
        let allowsMotion = endorsement == .hype && !reduceMotion
        return POIFeedbackIcon(endorsement: endorsement, set: .emoji, size: size)
            .fixedSize()
            .keyframeAnimator(initialValue: Motion(), trigger: animationTrigger) { content, motion in
                content
                    .scaleEffect(allowsMotion ? motion.scale : 1)
                    .rotationEffect(.degrees(allowsMotion ? motion.angle : 0))
                    .offset(y: allowsMotion ? motion.lift : 0)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    if emphasizesHype {
                        CubicKeyframe(1.4, duration: 0.16)
                        LinearKeyframe(1.4, duration: 0.4)
                        CubicKeyframe(1, duration: 0.24)
                    } else {
                        CubicKeyframe(1.10, duration: 0.16)
                        CubicKeyframe(0.98, duration: 0.18)
                        CubicKeyframe(1, duration: 0.24)
                    }
                }
                KeyframeTrack(\.angle) {
                    if emphasizesHype {
                        LinearKeyframe(0, duration: 0.16)
                        CubicKeyframe(-12, duration: 0.1)
                        CubicKeyframe(12, duration: 0.1)
                        CubicKeyframe(-8, duration: 0.1)
                        CubicKeyframe(4, duration: 0.1)
                        CubicKeyframe(0, duration: 0.24)
                    } else {
                        CubicKeyframe(-10, duration: 0.16)
                        CubicKeyframe(5, duration: 0.18)
                        CubicKeyframe(0, duration: 0.24)
                    }
                }
                KeyframeTrack(\.lift) {
                    if emphasizesHype {
                        CubicKeyframe(-3, duration: 0.16)
                        LinearKeyframe(-3, duration: 0.4)
                        CubicKeyframe(0, duration: 0.24)
                    } else {
                        CubicKeyframe(-2, duration: 0.16)
                        CubicKeyframe(0, duration: 0.42)
                    }
                }
            }
            .frame(width: size + 8, height: size + 8)
            .task(id: motionID) {
                guard endorsement == .hype, !reduceMotion else { return }
                animationTrigger.toggle()
            }
    }
}

/// Position within this place, separate from the person's stops above. A small
/// window keeps long visits quiet without hiding the currently selected slice.
struct FriendStoryPlacePageDots: View {
    let count: Int
    let index: Int

    private var visibleRange: Range<Int> {
        let start = max(0, min(index - 3, count - 7))
        return start..<min(count, start + 7)
    }

    var body: some View {
        if count > 1 {
            HStack(spacing: 5) {
                ForEach(visibleRange, id: \.self) { page in
                    let isOverflowEdge = (page == visibleRange.lowerBound && page > 0)
                        || (page == visibleRange.upperBound - 1 && page < count - 1)
                    Circle()
                        .fill(.white.opacity(page == index ? 0.95 : 0.4))
                        .frame(width: 6, height: 6)
                        .scaleEffect(isOverflowEdge && page != index ? 0.65 : 1)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .animation(.easeOut(duration: 0.16), value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("At this place, item \(index + 1) of \(count)")
            .accessibilityIdentifier("friend-story.moment-position")
        }
    }
}

/// A compact POI is laid out at its own final size, not at the outgoing Post's
/// height. The native sheet may resize around it without recropping its media.
private struct FriendStoryCompactPOICanvas<Content: View>: View {
    @ObservedObject var motion: ProfileCardSheetMotion
    let includesBottomSafeArea: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let height = motion.maximumDetentHeight * ProfileCardPagingLayout.poiFraction
            + (includesBottomSafeArea ? motion.bottomSafeArea : 0)
        GeometryReader { geometry in
            content()
                .frame(width: geometry.size.width,
                       height: motion.maximumDetentHeight > 0 ? max(1, height) : geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipped()
        }
    }
}

/// Only the person's compact POI preview changes. Native sheet expansion,
/// the original place details and the outer post pager keep their ownership.
struct FriendStoryPOIPreview: View {
    let place: RatedPOI
    let media: RatedPOI.Media
    let isPlaybackActive: Bool
    var showsPlaceChrome = true
    var chromePageID: String? = nil
    var onMediaTap: (() -> Void)? = nil
    @State private var isLightboxPresented = false
    @State private var childPresentationID = UUID()
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @Environment(\.poiMediaLightboxEnabled) private var lightboxEnabled

    private var item: ExperienceDetailView.MediaDisplayItem {
        switch media.kind {
        case let .photo(url):
            return .init(id: media.id, content: .photo(url))
        case let .video(url, poster):
            return .init(id: media.id, content: .video(url: url, poster: poster, metadata: nil))
        }
    }

    var body: some View {
        ZStack {
            Group {
                if onMediaTap != nil || lightboxEnabled {
                    Button {
                        guard isPlaybackActive else { return }
                        if let onMediaTap { onMediaTap() }
                        else if lightboxEnabled { isLightboxPresented = true }
                    } label: {
                        mediaCanvas
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(onMediaTap == nil ? "Open check-in media" : "Expand check-in card")
                } else {
                    // Expanded instant browsing is already the media viewer.
                    // Do not expose an inert button or reopen the old lightbox.
                    mediaCanvas
                }
            }
            .accessibilityIdentifier("friend-story.poi.media.\(media.id.uuidString)")
            // A same-place media run draws one fixed layer outside its pager.
            // Standalone and neighboring places still own their own chrome.
            if showsPlaceChrome { FriendStoryPOIChrome(place: place) }
        }
        // Measure the full-bleed canvas, not its safe-area-constrained wrapper.
        // The fixed place controls must reach the same bottom edge as the media.
        .poiChromePageAnchor(id: chromePageID)
        .ignoresSafeArea(.container, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-story.poi.preview")
        .onChangeCompat(of: isLightboxPresented) { presented in
            childPresentationChanged?(childPresentationID, presented)
        }
        .onDisappear {
            if !isLightboxPresented { childPresentationChanged?(childPresentationID, false) }
        }
        .fullScreenCover(isPresented: $isLightboxPresented) {
            ExperienceDetailView.MediaLightbox(items: [item], selection: .constant(media.id),
                accentColor: place.poi.category.accentColor, isPresented: $isLightboxPresented)
                .environment(\.friendStoryPlaybackEnabled, true)
                .environment(\.friendStoryExpectedMedia, [])
                .environment(\.friendStoryOnMediaReady, nil)
                .environment(\.friendStoryChildPresentationChanged, nil)
        }
    }

    private var mediaCanvas: some View {
        GeometryReader { geometry in
            ExperienceDetailView.MediaCardView(item: item,
                accentColor: place.poi.category.accentColor, mode: .card,
                isPlaybackActive: isPlaybackActive && !isLightboxPresented,
                blendsWithBackground: true)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .contentShape(Rectangle())
    }
}

/// Place identity belongs to the containing card, not to each media slice.
struct FriendStoryPOIChrome: View {
    let place: RatedPOI
    @Environment(\.experiencePOIPlaybackActionsVisible) private var showsPlaybackActions
    @Environment(\.experiencePOIPlaceHeader) private var placeHeader

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                ExperienceDetailView.POIPlaceHeading(
                    info: .init(name: place.poi.name, category: place.poi.category,
                        endorsementBadges: ExperienceDetailView.poiEndorsementBadges(for: place),
                        placeID: place.id),
                    accentColor: place.poi.category.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .accessibilityIdentifier("friend-story.poi.place-name")
                    .allowsHitTesting(placeHeader != nil)
            }
            .overlay(alignment: .bottomTrailing) {
                if !showsPlaybackActions, placeHeader == nil {
                ExperienceDetailView.POIHeroStatsRow(model: .init(
                    checkIns: place.checkInPersonCount,
                    comments: place.comments.count,
                    favorites: place.favoritesCount,
                    endorsements: place.endorsements,
                    commentTarget: .place(place.id)),
                    directionsDestination: MapDirectionsDestination(name: place.poi.name,
                                                                     coordinate: place.poi.coordinate))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("friend-story.poi.stats")
                }
            }
    }
}

/// A static position indicator. Media playback never owns navigation.
private struct FriendStoryProgressBars: View {
    let count: Int
    let index: Int
    let pageID: String
    let pageIndex: Int
    let pageCount: Int
    let authorName: String
    let onSelect: (Int) -> Void

    var body: some View {
        StorySequenceProgressBar(count: count, index: index, onSelect: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Update \(pageIndex + 1) of \(pageCount)")
            .accessibilityValue(authorName)
            .accessibilityIdentifier("friend-story.page.\(pageID)")
    }
}

/// Shared visual and touch target; each browser owns its own sequence/cursor.
struct StorySequenceProgressBar: View {
    let count: Int
    let index: Int
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            Group {
                if count <= 12 {
                    HStack(spacing: 3) {
                        ForEach(0..<count, id: \.self) { segment in
                            bar(fraction: FriendStoryProgressSelection.fill(for: segment, index: index))
                        }
                    }
                } else {
                    bar(fraction: CGFloat(index + 1) / CGFloat(max(1, count)))
                }
            }
            .frame(height: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let target = FriendStoryProgressSelection.index(
                    at: location.x, width: geometry.size.width, count: count) {
                    onSelect(target)
                }
            }
        }
    }

    private func bar(fraction: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }
    }
}

/// Map-entry browsing keeps the current friend in front of the next people.
/// Only this small stack animates; the bar and card keep their existing geometry.
private struct FriendStoryPlaceAuthors: View {
    let author: User
    let people: [User]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var queue: [User] {
        guard let currentIndex = people.firstIndex(where: { $0.id == author.id }) else {
            return [author] + Array(people.prefix(2))
        }
        return Array((people[currentIndex...] + people[..<currentIndex]).prefix(3))
    }

    var body: some View {
        let visible = queue
        ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, person in
                FriendStoryAvatar(user: person, diameter: 32)
                    .overlay(Circle().strokeBorder(Color(white: 0.12), lineWidth: 1.5))
                    .scaleEffect(1 - CGFloat(index) * 0.12)
                    .opacity(index == 0 ? 1 : 0.85)
                    .offset(x: CGFloat(index) * 10, y: -CGFloat(index) * 2)
                    .zIndex(Double(visible.count - index))
                    .transition(.opacity)
            }
        }
        .frame(width: 32 + CGFloat(max(0, visible.count - 1)) * 10, height: 40, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: author.id)
        .accessibilityHidden(true)
    }
}

private struct FriendStoryAvatar: View {
    let user: User?
    let diameter: CGFloat

    var body: some View {
        Group {
            if let url = user?.avatarURL {
                MapImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: diameter, height: diameter)
        .background(Color.white, in: Circle())
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Text(String((user?.handle ?? "?").prefix(2)).uppercased())
            .font(.system(size: diameter * 0.27, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The cover and its tap target use the same page. Resume takes precedence
/// over feed reordering, without skipping text-only posts for a prettier cover.
enum MapTalkPostEntryPage {
    static func resolve(in groups: [FriendStoryGroup], resumePageID: String?) -> FriendStoryPage? {
        // Rendering the floating entry only needs one cover, not a sorted
        // copy of the entire history on every card/geometry update.
        var newest: FriendStoryPage?
        for group in groups {
            for page in group.pages {
                if page.id == resumePageID { return page }
                if newest.map({ FriendStoryPage.newestPostFirst(page, $0) }) ?? true {
                    newest = page
                }
            }
        }
        return newest
    }

    static func refreshTarget(in groups: [FriendStoryGroup], currentPageID: String?,
                              viewedKeys: Set<String>) -> FriendStoryPage? {
        let pages = groups.flatMap(\.pages).sorted { FriendStoryPage.newestPostFirst($0, $1) }
        let candidates: [FriendStoryPage]
        if let index = pages.firstIndex(where: { $0.id == currentPageID }) {
            // Continue around the feed, avoiding the current card. Once all
            // posts are read, repeated taps still move forward rather than
            // bouncing between the same two cards.
            candidates = Array(pages.dropFirst(index + 1)) + Array(pages.prefix(index))
        } else {
            candidates = pages
        }
        return candidates.first { !viewedKeys.contains($0.readKey) }
            ?? candidates.first ?? pages.first
    }
}

/// A movable postcard into Posts; its remembered position belongs to the map.
struct MapTalkPostCoverEntry: View {
    let post: RealPost?
    let isResuming: Bool
    let isVisible: Bool
    let isActive: Bool
    let isReturning: Bool
    let needsCardClearance: Bool
    let canvasSize: CGSize
    let idleBottomInset: CGFloat
    let bottomInset: CGFloat
    @Binding var position: CGPoint?
    var excludedFrame: CGRect = .null
    var topInset: CGFloat = 0
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mapTalkCardSources) private var sources
    @State private var isPressed = false
    @State private var drag = MapTalkPostEntryDrag()
    @GestureState private var isDragging = false
    @State private var suppressTapUntil = Date.distantPast
    @State private var floatMotion = MapTalkPostEntryFloat()

    private let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)

    private var mapCenter: CGPoint {
        MapTalkPostEntryGeometry.restingCenter(position, canvasSize: canvasSize,
            topInset: topInset, idleBottomInset: idleBottomInset)
    }

    private var restingCenter: CGPoint {
        // POI clearance is a temporary projection, never a saved drag. Posts
        // uses the map placement while hidden, so its native return has one
        // stable destination even after entering from the lifted POI button.
        MapTalkPostEntryGeometry.restingCenter(position, canvasSize: canvasSize,
            topInset: topInset, idleBottomInset: idleBottomInset,
            clearanceBottomInset: needsCardClearance && !isActive ? bottomInset : nil)
    }

    private var displayedCenter: CGPoint {
        guard let center = drag.center else { return restingCenter }
        // Direct manipulation follows the finger. Obstacle projection can
        // switch nearest edges mid-drag and teleport the entry across buttons.
        return MapTalkPostEntryGeometry.constrainedCenter(center, canvasSize: canvasSize,
            topInset: topInset, bottomInset: bottomInset)
    }

    private var canFloat: Bool {
        isVisible && !isActive && !reduceMotion && scenePhase == .active && !isPressed && !drag.isActive
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        MapTalkPostEntryGeometry.constrainedCenter(point, canvasSize: canvasSize,
            topInset: topInset, bottomInset: bottomInset, excludedFrame: excludedFrame)
    }

    private func floatingOffset(at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return floatMotion.offset(at: date)
    }

    private var coverURL: URL? {
        post?.attachments.compactMap { attachment -> URL? in
            switch attachment.kind {
            case let .photo(url): return url
            case let .video(_, poster): return poster
            case .emoji: return nil
            }
        }.first
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !canFloat || floatMotion.isSettled)) { context in
            coverButton
                .offset(y: floatingOffset(at: context.date))
                .onChangeCompat(of: floatMotion.isComplete(at: context.date)) { complete in
                    if complete { floatMotion.settle() }
                }
        }
        .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 3)
        // Only the postcard owns a drag. Its full-canvas positioning space
        // must remain available to the native map's pan and pinch gestures.
        .frame(width: MapTalkPostEntryGeometry.size.width,
               height: MapTalkPostEntryGeometry.size.height)
        .contentShape(shape)
        .highPriorityGesture(dragGesture, including: isActive ? .subviews : .all)
        .position(displayedCenter)
        .animation(reduceMotion || isActive ? nil : .easeOut(duration: 0.18), value: restingCenter)
        .transaction {
            if reduceMotion || drag.isActive || isActive {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .onAppear { floatMotion.setRunning(canFloat, at: .now) }
        .onDisappear { floatMotion.setRunning(false, at: .now) }
        .onChangeCompat(of: canFloat) { floatMotion.setRunning($0, at: .now) }
        .onChangeCompat(of: isDragging) { dragging in
            guard !dragging else { return }
            // GestureState can reset before onEnded delivers its final sample.
            // Normal release finishes immediately there; this is cancel-only
            // cleanup on the next run loop, not a delayed movement animation.
            DispatchQueue.main.async {
                guard !isDragging else { return }
                finishDrag()
            }
        }
        .onChangeCompat(of: canvasSize) { _ in
            guard let center = position else { return }
            // Rotation may change the available screen, not the source's
            // relationship to a sheet or to an animating toolbar.
            updateDragImmediately {
                position = MapTalkPostEntryGeometry.constrainedCenter(center,
                    canvasSize: canvasSize, topInset: topInset, bottomInset: 0)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                updateDragImmediately {
                    drag.update(startingAt: restingCenter, translation: value.translation)
                    suppressTapUntil = .now.addingTimeInterval(0.3)
                }
            }
            .onEnded { value in finishDrag(finalTranslation: value.translation) }
    }

    private func finishDrag(finalTranslation: CGSize? = nil) {
        guard drag.isActive else { return }
        updateDragImmediately {
            // Normal completion consumes the final gesture sample; cancellation
            // keeps the last displayed position. Both commit once and release.
            if let center = drag.finish(finalTranslation: finalTranslation) {
                position = constrained(center)
            }
            isPressed = false
            suppressTapUntil = .now.addingTimeInterval(0.2)
        }
    }

    private func updateDragImmediately(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    private var coverButton: some View {
        Button {
            // A returning entry is already visible and must accept a tap.
            // Queue the reopen without moving the ongoing zoom's destination.
            if isReturning {
                action()
                return
            }
            guard !isDragging, Date.now >= suppressTapUntil else { return }
            // Capture the map placement including its gentle float, not POI's
            // temporary lift. POI→Post replaces the already-mounted card;
            // its hidden source can return to the map placement immediately.
            let now = Date.now
            let center = CGPoint(x: mapCenter.x,
                                 y: mapCenter.y + floatingOffset(at: now))
            updateDragImmediately {
                position = center
                floatMotion = MapTalkPostEntryFloat(at: now)
            }
            action()
        } label: {
            coverFace
                // The real destination must exist beneath the shrinking
                // native snapshot, even before UIKit finishes its callback.
                // Keep geometry still during return; taps can queue a reopen.
                .opacity(isActive && !isReturning ? 0 : 1)
                .background {
                    if let sources {
                        MapTalkCardSourceAnchor(id: .posts, registry: sources)
                    }
                }
                .accessibilityHidden(true)
        }
        .buttonStyle(MapTalkPostCoverPressStyle { isPressed = $0 })
        .accessibilityLabel("Posts")
        .accessibilityValue(isActive && !isReturning ? "Open" : "Closed")
        .accessibilityHint(post == nil ? "Retry loading posts. Drag to move."
            : isActive && !isReturning ? "Refresh posts. Swipe down on the card to close."
            : isResuming ? "Continue where you left off. Drag to move."
            : "Browse posts. Drag to move.")
        .accessibilityIdentifier("maptalk.post-entry")
    }

    // Only the artwork hides; its live native geometry anchor stays mounted.
    private var coverFace: some View {
            Color(white: 0.22)
                .frame(width: MapTalkPostEntryGeometry.size.width,
                       height: MapTalkPostEntryGeometry.size.height)
                .overlay {
                    if let coverURL {
                        MapImage(url: coverURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                textCover
                            }
                        }
                    } else {
                        textCover
                    }
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: .black.opacity(0.12), location: 0.5),
                            .init(color: .black.opacity(0.72), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 3) {
                        Text("Posts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                        if isActive && !isReturning {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .padding(.bottom, 7)
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(0.92), lineWidth: 1.5) }
                .contentShape(shape)
    }

    private var textCover: some View {
        LinearGradient(colors: [Color(white: 0.33), Color(white: 0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topLeading) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(9)
            }
    }
}

/// Keep the gentle invitation, then rest instead of redrawing an idle map
/// accessory forever. Pauses keep the exact offset used by the zoom source.
struct MapTalkPostEntryFloat {
    static let duration: TimeInterval = 9.6
    private var startedAt: Date
    private var pausedAt: Date?
    private(set) var isSettled = false

    init(at date: Date = .now) {
        startedAt = date
        pausedAt = date
    }

    func offset(at date: Date) -> CGFloat {
        guard !isSettled, !isComplete(at: date) else { return 0 }
        let elapsed = max(0, (pausedAt ?? date).timeIntervalSince(startedAt))
        // Fade the final half-cycle with zero velocity at rest; do not snap
        // back to baseline when the TimelineView stops scheduling frames.
        let fade = min(1, (Self.duration - elapsed) / 2.4)
        let envelope = fade * fade * (3 - 2 * fade)
        return sin(elapsed * .pi / 2.4) * 2.5 * envelope
    }

    func isComplete(at date: Date) -> Bool {
        (pausedAt ?? date) >= startedAt.addingTimeInterval(Self.duration)
    }

    mutating func setRunning(_ running: Bool, at date: Date) {
        if running, let pausedAt {
            startedAt = startedAt.addingTimeInterval(date.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        } else if !running, pausedAt == nil {
            pausedAt = date
        }
    }

    mutating func settle() { isSettled = true }
}

/// Local gesture state only. Parent map placement is committed once on release,
/// so every finger update doesn't invalidate the entire map/feed hierarchy.
struct MapTalkPostEntryDrag {
    private var origin: CGPoint?
    private var translation = CGSize.zero

    var isActive: Bool { origin != nil }
    var center: CGPoint? {
        origin.map { CGPoint(x: $0.x + translation.width, y: $0.y + translation.height) }
    }

    mutating func update(startingAt point: CGPoint, translation: CGSize) {
        if origin == nil { origin = point }
        self.translation = translation
    }

    mutating func finish(finalTranslation: CGSize? = nil) -> CGPoint? {
        if let finalTranslation { translation = finalTranslation }
        let result = center
        origin = nil
        translation = .zero
        return result
    }
}

private struct MapTalkPostCoverPressStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChangeCompat(of: configuration.isPressed, onPressChanged)
    }
}

/// User placement and temporary card clearance are separate. Native Posts
/// return uses only the former, never the closing sheet's moving geometry.
enum MapTalkPostEntryGeometry {
    static let size = CGSize(width: 56, height: 66)
    private static let edgeInset: CGFloat = 22

    static func restingCenter(_ remembered: CGPoint?, canvasSize: CGSize,
                              topInset: CGFloat, idleBottomInset: CGFloat,
                              clearanceBottomInset: CGFloat? = nil) -> CGPoint {
        let baseline = remembered ?? constrainedCenter(
            center(canvasSize: canvasSize, bottomInset: idleBottomInset),
            canvasSize: canvasSize, topInset: topInset, bottomInset: idleBottomInset)
        guard let clearanceBottomInset else { return baseline }
        return constrainedCenter(baseline, canvasSize: canvasSize,
            topInset: topInset, bottomInset: clearanceBottomInset)
    }

    static func sheetClearance(mapFrame: CGRect, sheetFrame: CGRect,
                               baseBottomInset: CGFloat, accessoryHeight: CGFloat = 0) -> CGFloat {
        max(baseBottomInset, mapFrame.maxY - sheetFrame.minY + accessoryHeight + 12)
    }

    static func center(canvasSize: CGSize, bottomInset: CGFloat) -> CGPoint {
        CGPoint(x: min(canvasSize.width / 2, edgeInset + size.width / 2),
                y: max(min(canvasSize.height / 2, size.height / 2),
                       canvasSize.height - max(0, bottomInset) - size.height / 2))
    }

    static func constrainedCenter(_ point: CGPoint, canvasSize: CGSize,
                                  topInset: CGFloat, bottomInset: CGFloat,
                                  excludedFrame: CGRect = .null) -> CGPoint {
        let minX = min(canvasSize.width / 2, edgeInset + size.width / 2)
        let maxX = max(minX, canvasSize.width - edgeInset - size.width / 2)
        let maxY = max(size.height / 2, canvasSize.height - max(0, bottomInset) - size.height / 2)
        let minY = min(maxY, max(0, topInset) + edgeInset + size.height / 2)
        func clamp(_ candidate: CGPoint) -> CGPoint {
            CGPoint(x: min(maxX, max(minX, candidate.x)),
                    y: min(maxY, max(minY, candidate.y)))
        }
        let bounded = clamp(point)
        guard !excludedFrame.isNull, !excludedFrame.isEmpty else { return bounded }
        let obstacle = excludedFrame.insetBy(dx: -size.width / 2 - 12,
                                            dy: -size.height / 2 - 12)
        guard obstacle.contains(bounded) else { return bounded }
        // Move only far enough to clear the controls, not to a screen corner.
        let candidates = [
            CGPoint(x: obstacle.minX - 0.5, y: bounded.y),
            CGPoint(x: obstacle.maxX + 0.5, y: bounded.y),
            CGPoint(x: bounded.x, y: obstacle.minY - 0.5),
            CGPoint(x: bounded.x, y: obstacle.maxY + 0.5)
        ].map(clamp).filter { !obstacle.contains($0) }
        return candidates.min { lhs, rhs in
            hypot(lhs.x - bounded.x, lhs.y - bounded.y)
                < hypot(rhs.x - bounded.x, rhs.y - bounded.y)
        } ?? bounded
    }
}

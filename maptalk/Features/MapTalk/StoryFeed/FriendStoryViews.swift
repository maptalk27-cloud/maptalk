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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @Environment(\.postCardPalette) private var postCardPalette
    @Environment(\.profileCardSheetMotion) private var sheetMotion
    @State private var readyPageIDs: Set<String> = []
    @State private var selectedProfile: UserMapViewModel.Context?
    @State private var isKeyboardVisible = false
    @State private var activeChildPresentations: Set<UUID> = []

    private var author: User? { userProvider(group.authorID) ?? group.user }
    private var playbackEnabled: Bool {
        isPlaybackActive && scenePhase == .active
            && selectedProfile == nil && !isKeyboardVisible && activeChildPresentations.isEmpty
    }
    private var canNavigate: Bool {
        isPlaybackActive && selectedProfile == nil
            && !isKeyboardVisible && activeChildPresentations.isEmpty
    }

    private var showsFullBleedPOIPreview: Bool {
        guard !isExpanded, case let .poi(_, _, media) = page.content else { return false }
        return media != nil
    }

    var body: some View {
        postPager
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .overlay(alignment: .bottom) {
                if feedPresentation == .personStory, !isExpanded,
                   let momentIndex = group.momentIndex(containing: pageIndex),
                   group.moments[momentIndex].placeID != nil {
                    let range = group.moments[momentIndex].pageRange
                    FriendStoryPlacePageDots(count: range.count,
                        index: pageIndex - range.lowerBound)
                        .padding(.bottom, showsFullBleedPOIPreview ? 24 : 12)
                        .allowsHitTesting(false)
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
            isEnabled: feedPresentation == .personStory,
            isVisible: isPlaybackActive && selectedProfile == nil && activeChildPresentations.isEmpty
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
        let momentIndex = group.momentIndex(containing: pageIndex) ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                authorIdentity
                Spacer(minLength: 4)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("friend-story.author-navigation")
            .accessibilityValue("Stop \(momentIndex + 1) of \(group.moments.count)")

            FriendStoryProgressBars(count: group.moments.count,
                                    index: momentIndex, pageID: page.id,
                                    pageIndex: pageIndex, pageCount: group.pages.count,
                                    authorName: author?.handle ?? "Member",
                                    onSelect: { index in
                guard canNavigate, group.moments.indices.contains(index) else { return }
                onSelectPage(group.moments[index].pageRange.lowerBound)
            })
                .frame(height: 24)
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-story.navigation")
        .accessibilityAction(.escape, onClose)
    }

    private var authorIdentity: some View {
        Button {
            if let author { selectedProfile = .profileContext(for: author) }
        } label: {
            HStack(spacing: 8) {
                FriendStoryAvatar(user: author, diameter: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(author?.handle ?? "Member")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(page.publishedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .accessibilityIdentifier("friend-story.timestamp")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author == nil)
        .accessibilityIdentifier("friend-story.open-author")
        .accessibilityLabel("View profile")
        .accessibilityValue(author?.handle ?? "Member")
    }

    private var pageSelection: Binding<String> {
        Binding(get: { selectedPageID.wrappedValue }, set: { id in
            guard canNavigate, id != selectedPageID.wrappedValue,
                  pagerPages.contains(where: { $0.id == id }) else { return }
            selectedPageID.wrappedValue = id
        })
    }

    private var poiChromePages: [FriendStoryPOIChromePage] {
        pagerPages.map { candidate in
            let place: RatedPOI?
            if case let .poi(rated, _, media) = candidate.content, media != nil {
                place = rated
            } else { place = nil }
            return .init(id: candidate.id, place: place)
        }
    }

    @ViewBuilder
    private var postPager: some View {
        if feedPresentation == .posts, let sheetMotion {
            stablePostPager(motion: sheetMotion)
        } else if case let .poi(place, _, media) = page.content, let media {
            // A place is the container, not a different card for every visit.
            // Only the media belongs to the horizontal pager; the place shell
            // stays mounted while its exact selected slice changes.
            if isExpanded {
                ExperienceDetailView(
                    mode: .poi(Self.placeForCard(place, isExpanded: true, provider: placeProvider)),
                    isExpanded: true,
                    expandedPOIMedia: media,
                    expandedPOIMediaContent: AnyView(
                        nativePostPager(mediaOnly: true)
                            .aspectRatio(ExperienceDetailView.POIFeaturedMedia.viewportAspectRatio, contentMode: .fit)
                            .overlay(alignment: .bottom) {
                                placePageDots.padding(.bottom, 24)
                            }
                    ),
                    onJourneyAvatarStackTap: { onJourney($0, page) },
                    journeyProvider: journeyProvider,
                    userProvider: userProvider,
                    onPOIContributorViewed: { keys in keys.forEach(onReadReady) },
                    isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                )
                .id("story-place:\(page.authorID.uuidString):\(place.id.uuidString)")
                .environment(\.friendStoryPlaybackEnabled, playbackEnabled)
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
            .accessibilityIdentifier("friend-story.post-pager")
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
        let chromePages = mediaOnly && !isExpanded ? poiChromePages : []
        let chromeRun = FriendStoryPOIChromeRun(pages: chromePages, selectedID: page.id)
        return TabView(selection: pageSelection) {
            ForEach(pagerPages) { candidate in
                preparedPage(candidate, mediaOnly: mediaOnly, chromeRun: chromeRun)
                    .tag(candidate.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("friend-story.post-pager")
        .fixedPOIChrome(pages: chromePages, selectedID: page.id)
    }

    private func preparedPage(_ candidate: FriendStoryPage, mediaOnly: Bool,
                              chromeRun: FriendStoryPOIChromeRun? = nil) -> some View {
        Group {
            if mediaOnly { mediaPage(for: candidate, chromeRun: chromeRun) }
            else { content(for: candidate) }
        }
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
            if isExpanded {
                ExperienceDetailView.POIFeaturedMedia(media: media,
                    accentColor: place.poi.category.accentColor,
                    isPlaybackActive: playbackEnabled && candidate.id == page.id,
                    fillsContainer: true)
            } else {
                FriendStoryPOIPreview(place: place, media: media,
                    isPlaybackActive: playbackEnabled && candidate.id == page.id,
                    showsPlaceChrome: chromeRun?.contains(candidate.id) != true,
                    chromePageID: candidate.id)
            }
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
                        isPlaybackActive: playbackEnabled && candidate.id == page.id)
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
    @State private var isLightboxPresented = false
    @State private var childPresentationID = UUID()
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged

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
            Button {
                guard isPlaybackActive else { return }
                isLightboxPresented = true
            } label: {
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
            .buttonStyle(.plain)
            .accessibilityLabel("Open check-in media")
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
}

/// Place identity belongs to the containing card, not to each media slice.
struct FriendStoryPOIChrome: View {
    let place: RatedPOI

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                ExperienceDetailView.POIPlaceHeading(
                    info: .init(name: place.poi.name, category: place.poi.category,
                        endorsementBadges: ExperienceDetailView.poiEndorsementBadges(for: place)),
                    accentColor: place.poi.category.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .accessibilityIdentifier("friend-story.poi.place-name")
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
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
    @State private var floatStartedAt = Date.now
    @State private var floatPausedAt: Date?

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
        !isActive && !reduceMotion && scenePhase == .active && !isPressed && !drag.isActive
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        MapTalkPostEntryGeometry.constrainedCenter(point, canvasSize: canvasSize,
            topInset: topInset, bottomInset: bottomInset, excludedFrame: excludedFrame)
    }

    private func floatingOffset(at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let elapsed = (floatPausedAt ?? date).timeIntervalSince(floatStartedAt)
        return sin(elapsed * .pi / 2.4) * 2.5
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
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canFloat)) { context in
            coverButton.offset(y: floatingOffset(at: context.date))
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
        .onChangeCompat(of: canFloat) { enabled in
            let now = Date.now
            if enabled, let pausedAt = floatPausedAt {
                floatStartedAt = floatStartedAt.addingTimeInterval(now.timeIntervalSince(pausedAt))
                floatPausedAt = nil
            } else if !enabled, floatPausedAt == nil {
                floatPausedAt = now
            }
        }
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
                floatStartedAt = now
                floatPausedAt = now
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

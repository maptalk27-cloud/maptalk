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
    let alignTrigger: Int

    var body: some View {
        ScrollViewReader { proxy in
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
                                    FriendStoryAvatar(user: user, diameter: 60)
                                }
                                .frame(width: 70, height: 70)
                                .opacity(selected ? 1 : 0.82)

                                Text(user?.handle ?? "Member")
                                    .font(.caption2.weight(.thin))
                                    .foregroundStyle(.black)
                                    .lineLimit(1)
                                    .padding(.vertical, 2)
                            }
                            .frame(width: 72)
                            .scaleEffect(selected ? 1.08 : 1)
                            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.82), value: selected)
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
            .onChangeCompat(of: alignTrigger) { _ in
                guard let selectedAuthorID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(selectedAuthorID, anchor: .center)
                }
            }
        }
        .frame(height: Self.layoutHeight)
        .accessibilityIdentifier("maptalk.friend-story.rail")
    }
}

/// Owns only person-story navigation. The original Reel card continues to own
/// its image viewer, comments, author controls and Bubble interaction.
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
    let onJourney: (JourneyPost) -> Void
    let onReadReady: (String) -> Void
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let placeProvider: (UUID) -> RatedPOI?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
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
        VStack(spacing: 0) {
            postPager
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
        }
        .background(Color.black)
        // The pager itself must reach the sheet's bottom edge; a child cannot
        // fill the home-indicator inset while its parent clips above it.
        .ignoresSafeArea(.container, edges: showsFullBleedPOIPreview ? .bottom : [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-story.card")
        .accessibilityValue(isExpanded ? "Expanded" : "Compact")
        .background {
            FriendStoryFloatingAccessory(
                isVisible: isPlaybackActive && selectedProfile == nil
                    && activeChildPresentations.isEmpty
            ) {
                navigationHeader
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .environment(\.colorScheme, .dark)
                    .environment(\.appEnv, environment)
            }
        }
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
        let moment = group.moments.indices.contains(momentIndex) ? group.moments[momentIndex] : nil
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                authorIdentity
                Spacer(minLength: 4)
                if let moment, moment.pageRange.count > 1 {
                    Text("\(pageIndex - moment.pageRange.lowerBound + 1) / \(moment.pageRange.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                        .accessibilityLabel("At this place, item \(pageIndex - moment.pageRange.lowerBound + 1) of \(moment.pageRange.count)")
                        .accessibilityIdentifier("friend-story.moment-position")
                } else if group.moments.count > 12 {
                    Text("\(momentIndex + 1) / \(group.moments.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize()
                        .accessibilityHidden(true)
                }
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

    private var postPager: some View {
        // Keep one stable native sequence through person boundaries. Let the
        // pager manage its neighboring pages; replacing offscreen card bodies
        // during a swipe can disturb its interactive transition.
        TabView(selection: pageSelection) {
            ForEach(pagerPages) { candidate in
                content(for: candidate)
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
                    .tag(candidate.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func content(for candidate: FriendStoryPage) -> some View {
        switch candidate.content {
        case let .reel(real):
            ExperienceDetailView(
                mode: .real(displayedReel(real), pagerUserProvider(candidate.authorID)),
                isExpanded: isExpanded,
                onCollapsedTap: onExpand,
                onJourneyAvatarStackTap: onJourney,
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
                    // Expanding returns to the original shared place card,
                    // including other visitors, not a replacement timeline.
                    ExperienceDetailView(
                        mode: .poi(Self.placeForCard(place, isExpanded: isExpanded, provider: placeProvider)),
                        isExpanded: isExpanded,
                        poiStorySelection: isExpanded ? nil : .init(checkIn: checkIn, media: media),
                        onCollapsedTap: onExpand,
                        onJourneyAvatarStackTap: onJourney,
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

/// Only the person's compact POI preview changes. Native sheet expansion,
/// the original place details and the outer post pager keep their ownership.
private struct FriendStoryPOIPreview: View {
    let place: RatedPOI
    let media: RatedPOI.Media
    let isPlaybackActive: Bool
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
                        isPlaybackActive: isPlaybackActive && !isLightboxPresented)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.black.opacity(0.72), .clear],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 140)
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            ExperienceDetailView.POIPlaceHeading(
                                info: .init(name: place.poi.name, category: place.poi.category,
                                    endorsementBadges: ExperienceDetailView.poiEndorsementBadges(for: place)),
                                accentColor: place.poi.category.accentColor)
                                .padding(.horizontal, 20)
                                .padding(.top, 28)
                                .accessibilityIdentifier("friend-story.poi.place-name")
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 100)
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            ExperienceDetailView.POIHeroStatsRow(model: .init(
                                checkIns: place.checkInPersonCount,
                                comments: place.comments.count,
                                favorites: place.favoritesCount,
                                endorsements: place.endorsements,
                                commentTarget: .place(place.id)))
                                .padding(.horizontal, 20)
                                .padding(.bottom, 32)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("friend-story.poi.stats")
                                .allowsHitTesting(false)
                        }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open check-in media")
            .accessibilityIdentifier("friend-story.poi.media.\(media.id.uuidString)")
        }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Update \(pageIndex + 1) of \(pageCount)")
        .accessibilityValue(authorName)
        .accessibilityIdentifier("friend-story.page.\(pageID)")
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
        .background(Color.white.opacity(0.72), in: Circle())
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

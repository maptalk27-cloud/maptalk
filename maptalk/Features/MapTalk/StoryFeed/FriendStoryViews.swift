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
                        .accessibilityLabel("\(user?.handle ?? "Member"), \(group.pages.count) updates")
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
    let isExpanded: Bool
    let isPlaybackActive: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onPreviousAuthor: () -> Void
    let onNextAuthor: () -> Void
    let onExpand: () -> Void
    let onClose: () -> Void
    let onLocation: (UUID) -> Void
    let onJourney: (JourneyPost) -> Void
    let onReadReady: (String) -> Void
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @State private var readyPageID: String?
    @State private var isEditing = false
    @State private var selectedProfile: UserMapViewModel.Context?
    @State private var isKeyboardVisible = false
    @State private var activeChildPresentations: Set<UUID> = []
    @State private var authorSwipeIntent: AuthorSwipeIntent?
    @GestureState private var isAuthorDragging = false

    private enum AuthorSwipeIntent { case horizontal, vertical }

    private var author: User? { userProvider(group.authorID) ?? group.user }
    private var playbackEnabled: Bool {
        isPlaybackActive && scenePhase == .active && !isEditing
            && selectedProfile == nil && !isKeyboardVisible && activeChildPresentations.isEmpty
    }
    private var canSwitchAuthor: Bool {
        isPlaybackActive && !isEditing && selectedProfile == nil
            && !isKeyboardVisible && activeChildPresentations.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader
            content
                .id(page.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
        }
        .background(Color.black)
        .environment(\.friendStoryPlaybackEnabled, playbackEnabled)
        .environment(\.friendStoryOnMediaReady, { noteReady(for: page.id) })
        .environment(\.friendStoryExpectedMedia, page.expectedMedia)
        .environment(\.friendStoryChildPresentationChanged, { id, presented in
            if presented { activeChildPresentations.insert(id) }
            else { activeChildPresentations.remove(id) }
        })
        .simultaneousGesture(authorSwipeGesture)
        .onChangeCompat(of: page.id) { _ in
            isEditing = false
            activeChildPresentations.removeAll()
            authorSwipeIntent = nil
        }
        .onChangeCompat(of: isAuthorDragging) { dragging in
            if !dragging { authorSwipeIntent = nil }
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

    private var authorSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .updating($isAuthorDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard canSwitchAuthor else { authorSwipeIntent = .vertical; return }
                // A native vertical sheet pull can run simultaneously, but
                // must never turn into another person midway through it.
                if authorSwipeIntent == nil {
                    authorSwipeIntent = abs(value.translation.width) > abs(value.translation.height) * 1.45
                        ? .horizontal : .vertical
                }
            }
            .onEnded { value in
                let intent = authorSwipeIntent
                authorSwipeIntent = nil
                guard canSwitchAuthor, intent == .horizontal else { return }
                let horizontal = value.translation.width
                let projected = value.predictedEndTranslation.width
                guard abs(horizontal) > 54 || (abs(horizontal) > 20 && abs(projected) > 130) else { return }
                if horizontal < 0 { onNextAuthor() } else { onPreviousAuthor() }
            }
    }

    private var navigationHeader: some View {
        VStack(spacing: 0) {
            progress
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Update \(pageIndex + 1) of \(group.pages.count)")
                .accessibilityIdentifier("friend-story.page.\(page.id)")
                .accessibilityAction(named: "Previous update", onPreviousPage)
                .accessibilityAction(named: "Next update", onNextPage)
                .accessibilityAction(named: "Previous person", onPreviousAuthor)
                .accessibilityAction(named: "Next person", onNextAuthor)
                .padding(.horizontal, 16)
                .padding(.top, 5)
            HStack(spacing: 8) {
                Button {
                    if let author { selectedProfile = .profileContext(for: author) }
                } label: {
                    HStack(spacing: 8) {
                        FriendStoryAvatar(user: author, diameter: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(author?.handle ?? "Member")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .accessibilityIdentifier("friend-story.current-author")
                            Text(page.publishedAt, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(author == nil)
                .accessibilityIdentifier("friend-story.open-author")
                .accessibilityLabel("View profile")
                .accessibilityValue(author?.handle ?? "Member")
                Spacer(minLength: 0)
                navigationButton("chevron.left", label: "Previous update", enabled: pageIndex > 0, action: onPreviousPage)
                    .accessibilityIdentifier("friend-story.previous-page")
                navigationButton("chevron.right", label: "Next update", enabled: pageIndex + 1 < group.pages.count, action: onNextPage)
                    .accessibilityIdentifier("friend-story.next-page")
                navigationButton("xmark", label: "Close stories", enabled: true, action: onClose)
                    .accessibilityIdentifier("friend-story.close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 48)
        }
        .background(Color.black.opacity(0.94))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-story.navigation")
    }

    @ViewBuilder
    private var progress: some View {
        if group.pages.count <= 12 {
            HStack(spacing: 3) {
                ForEach(group.pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(index <= pageIndex ? 0.88 : 0.22))
                        .frame(height: 2)
                }
            }
            .frame(height: 6)
        } else {
            HStack {
                Text("\(pageIndex + 1) / \(group.pages.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
            }
            .frame(height: 12)
        }
    }

    private func navigationButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.23))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch page.content {
        case let .reel(real):
            ExperienceDetailView(
                mode: .real(real, author),
                isExpanded: isExpanded,
                onCollapsedTap: onExpand,
                onJourneyAvatarStackTap: onJourney,
                journeyProvider: journeyProvider,
                userProvider: userProvider
            )
            .overlay(alignment: .bottomTrailing) {
                if !page.isMediaReady {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading media")
                }
            }
        case let .poi(place, _, media):
            poiContent(place: place, media: media)
        }
    }

    private func poiContent(place: RatedPOI, media: RatedPOI.Media?) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    poiMedia(place: place, media: media)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        // Aspect-fill pixels can extend outside the stage's
                        // layout bounds even after clipping. Media is visual;
                        // only the bounded tap zones below own interaction.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    // These zones only cover the plain POI stage, never Reel
                    // images, menus, place links, comments or Bubble controls.
                    HStack(spacing: 0) {
                        stageTapZone(action: onPreviousPage)
                            .frame(width: geometry.size.width * 0.22)
                        stageTapZone(action: { if !isExpanded { onExpand() } })
                        stageTapZone(action: onNextPage)
                            .frame(width: geometry.size.width * 0.22)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(author?.handle ?? "Member") at \(place.poi.name)")
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Expand update", onExpand)
            .accessibilityIdentifier("friend-story.poi-stage")

            HStack(spacing: 8) {
                Button { onLocation(place.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: place.poi.category.symbolName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(place.poi.category.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.poi.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("View place · Discussion")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(place.poi.name) and place discussion")
                .accessibilityIdentifier("friend-story.open-place")

                if let backend = environment.backend {
                    BackendContentSafetyMenu(
                        store: backend,
                        posts: [.init(id: page.memoryID, ownerID: page.authorID, title: "Check-in")],
                        onEditorVisibilityChanged: { isEditing = $0 }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 62)
            .background(Color.black)
        }
    }

    private func stageTapZone(action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func poiMedia(place: RatedPOI, media: RatedPOI.Media?) -> some View {
        if let media {
            switch media.kind {
            case let .photo(url):
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: isExpanded ? .fit : .fill)
                            .onAppear { noteReady(for: page.id) }
                    case .empty:
                        ProgressView().tint(.white)
                    default:
                        unavailableMedia
                    }
                }
                .background(Color.black)
            case let .video(url, poster):
                ExperienceDetailView.AutoPlayVideoView(
                    url: url,
                    poster: poster,
                    accentColor: place.poi.category.accentColor,
                    mode: isExpanded ? .lightbox : .card,
                    usesAspectFit: isExpanded,
                    isMuted: !isExpanded,
                    isPlaybackActive: playbackEnabled,
                    onReady: { noteReady(for: page.id) }
                )
            }
        } else if page.kind == .poiLocationOnly {
            VStack(spacing: 12) {
                Image(systemName: place.poi.category.symbolName)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(place.poi.category.accentColor)
                Text(place.poi.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Checked in")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.08))
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
                .accessibilityLabel("Loading media")
        }
    }

    private var unavailableMedia: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.title2.weight(.light))
            Text("Media unavailable")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.65))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private func noteReady(for id: String) {
        guard id == page.id else { return }
        readyPageID = id
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
        playbackEnabled && (readyPageID == page.id || hasReadableText)
    }

    private var readinessTaskID: String {
        "\(page.id):\(canMarkViewed)"
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

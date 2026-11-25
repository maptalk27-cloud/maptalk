import Combine
import MapKit
import SwiftUI
import UIKit

enum MapTalkFeedPresentation: Hashable {
    case personStory
    case posts
}

enum MapTalkCardTransitionID: Hashable {
    case posts
    case poi(MapTalkPOITransitionID)
    case map
}

struct MapTalkCardContentIdentity: Hashable {
    let flow: MapTalkFeedPresentation
    let revision: Int
}

/// Identifies the actual control that opened a POI, not its card's content.
enum MapTalkPOITransitionID: Hashable {
    case author(UUID)
    case story(UUID)
    case place(UUID)
    case reel(UUID)
    case footprint(String)
}

struct MapTalkPOITransitionSource: ViewModifier {
    let id: MapTalkPOITransitionID
    let namespace: Namespace.ID?
    var keepsSourceVisible = false
    @Environment(\.mapTalkCardSources) private var sources

    @ViewBuilder
    func body(content: Content) -> some View {
        if let sources {
            content.background(MapTalkCardSourceAnchor(id: .poi(id), registry: sources))
        } else if let namespace {
            if keepsSourceVisible {
                // Native zoom hides its source while presented. Keep a visual
                // copy beneath it so the people rail never loses an avatar.
                ZStack {
                    content.allowsHitTesting(false).accessibilityHidden(true)
                    content.matchedTransitionSource(id: MapTalkCardTransitionID.poi(id), in: namespace)
                }
            } else {
                content.matchedTransitionSource(id: MapTalkCardTransitionID.poi(id), in: namespace)
            }
        } else {
            content
        }
    }
}

enum FriendStoryLayout {
    static let headerHeight: CGFloat = 68
    static let headerGap: CGFloat = 12
    static var floatingHeight: CGFloat { headerHeight + headerGap }

    static func accessoryFrame(above card: CGRect) -> CGRect {
        CGRect(x: card.minX + 10, y: card.minY - floatingHeight,
               width: max(0, card.width - 20), height: headerHeight)
    }

    static func accessoryOpacity(cardTop: CGFloat, containerBottom: CGFloat) -> CGFloat {
        min(1, max(0, (containerBottom - cardTop) / floatingHeight))
    }
}

/// Visual styling only. The home presenter owns native size and transition.
struct FriendStorySheetChrome: ViewModifier {
    @ObservedObject var presentation: MapExperiencePresentation
    @ObservedObject var navigation: FriendStoryNavigation
    @ObservedObject var motion: ProfileCardSheetMotion
    var feedPresentation: MapTalkFeedPresentation = .personStory
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white
    @Environment(\.colorScheme) private var inheritedColorScheme

    func body(content: Content) -> some View {
        let isPost = feedPresentation == .posts && navigation.routes.isEmpty
        content
            .environment(\.profileCardSheetMotion, motion)
            .environment(\.postCardPalette, isPost ? palette : .white)
            .environment(\.colorScheme, isPost ? palette.colorScheme : inheritedColorScheme)
            .background(isPost ? AnyShapeStyle(palette.background) : AnyShapeStyle(.thinMaterial))
            .onChangeCompat(of: navigation.routes.last?.id) { _ in motion.isPaging = false }
            .onChangeCompat(of: MapTalkCardContentIdentity(
                flow: feedPresentation, revision: presentation.contentRevision)) { _ in
                motion.isPaging = false
            }
    }
}

enum FriendStoryProgressSelection {
    /// Static sequence position, independent of elapsed time or video playback.
    static func fill(for segment: Int, index: Int) -> CGFloat {
        segment >= 0 && index >= segment ? 1 : 0
    }

    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width.isFinite, width > 0, x.isFinite else { return nil }
        let fraction = min(max(x / width, 0), 1)
        return min(Int(fraction * CGFloat(count)), count - 1)
    }
}

enum FriendStoryPageSelection {
    /// Progress controls resolve within the displayed person's sequence.
    static func index(for pageID: String, in group: FriendStoryGroup) -> Int? {
        group.pages.firstIndex { $0.id == pageID }
    }

    /// Keep native pager tags and positions stable while crossing authors.
    /// The session is already frozen; selecting an author must not replace
    /// its page window while UIKit is finishing the horizontal gesture.
    static func pagerPages(in session: FriendStorySession, chronologicalPosts: Bool = false) -> [FriendStoryPage] {
        chronologicalPosts ? session.pagesInPostOrder : session.pagesInStoryOrder
    }

    /// A map pin chooses an entry cursor, never a new order or membership.
    /// Keep the first source-media slice when one visit has several pages.
    static func latestPlacePage(placeID: UUID, in groups: [FriendStoryGroup]) -> FriendStoryPage? {
        groups.lazy.flatMap(\.pages).reduce(nil as FriendStoryPage?) { latest, page in
            guard case let .poi(place, _, _) = page.content, place.id == placeID else { return latest }
            guard let latest else { return page }
            if page.publishedAt != latest.publishedAt {
                return page.publishedAt > latest.publishedAt ? page : latest
            }
            return page.memoryID.uuidString > latest.memoryID.uuidString ? page : latest
        }
    }
}

/// A local browsing session, never the selection/pager owned by the public map.
@MainActor
final class FriendStoryNavigation: ObservableObject {
    struct MapSnapshot {
        let camera: MapCamera?
        let region: MKCoordinateRegion?
    }

    struct Route: Identifiable {
        enum Content {
            case place(RatedPOI)
            case reel(RealPost)
            case bubble(MapJourneyScope)
        }

        let id = UUID()
        var content: Content
        var selectedID: UUID?
        let returnCamera: MapSnapshot
        let returnDetent: PresentationDetent
        var returnPageID: String? = nil
    }

    @Published var session: FriendStorySession?
    @Published var routes: [Route] = []
    var origin: MapSnapshot?
    var lastLocationKey: String?
    var lastViewportSize: CGSize?
    var lastFocusedAuthorID: UUID?

    var isActive: Bool { session != nil }
    var isPlaceScoped: Bool { session?.scopedPlaceID != nil }
    var isBrowsingBubble: Bool {
        if case .bubble? = routes.last?.content { return true }
        return false
    }

    var bubbleCompactFraction: CGFloat? {
        guard let route = routes.last, case let .bubble(scope) = route.content else { return nil }
        let items = scope.sequenceItems
        guard let item = items.first(where: { $0.id == route.selectedID }) ?? items.first else {
            return ProfileCardPagingLayout.poiFraction
        }
        return ProfileCardPagingLayout.fraction(for: item.mode)
    }

    func needsMapFocus(locationKey: String, viewportSize: CGSize, authorID: UUID? = nil) -> Bool {
        lastLocationKey != locationKey || lastViewportSize != viewportSize
            || (!isPlaceScoped && authorID != nil && lastFocusedAuthorID != authorID)
    }

    func begin(groups: [FriendStoryGroup], authorID: UUID, viewedKeys: Set<String>, origin: MapSnapshot) {
        guard groups.contains(where: { $0.authorID == authorID && !$0.pages.isEmpty })
            || (!isPlaceScoped && session?.groups.contains(where: { $0.authorID == authorID }) == true) else { return }
        if self.origin == nil { self.origin = origin }
        // A deliberate avatar tap is a safe boundary to include newly public
        // posts. Background reconciliation still freezes the mounted pager.
        if let refreshed = FriendStorySession(groups: groups, authorID: authorID,
            viewedKeys: viewedKeys, resuming: isPlaceScoped ? [:] : session?.resumePageIDs ?? [:]) {
            session = refreshed
        } else {
            session?.selectAuthor(id: authorID, viewedKeys: viewedKeys)
        }
        routes.removeAll()
    }

    /// Only the map entry uses a place-limited, latest-visit-first session.
    /// Every surviving page keeps that initial position during refreshes.
    @discardableResult
    func beginPlace(groups: [FriendStoryGroup], placeID: UUID, entryPageID: String,
                    origin: MapSnapshot) -> Bool {
        guard let entry = groups.flatMap(\.pages).first(where: { $0.id == entryPageID }),
              var next = FriendStorySession(groups: groups, authorID: entry.authorID,
                                            scopedPlaceID: placeID) else { return false }
        next.selectPage(id: entryPageID)
        self.origin = origin
        session = next
        routes.removeAll()
        lastLocationKey = nil
        lastViewportSize = nil
        lastFocusedAuthorID = nil
        return true
    }

    /// A native swipe commits exactly one neighboring page from the render
    /// that started it. Late callbacks must not overwrite a newer cursor.
    /// The lower card pager may cross an author boundary only from its edge,
    /// landing on the exact adjacent card rather than an unread/resume cursor.
    /// Explicit author selection keeps its existing resume/unread entry rules.
    @discardableResult
    func selectPagerPage(id: String, fromAuthorID: UUID, fromPageID: String,
                         chronologicalPosts: Bool = false) -> Bool {
        guard routes.isEmpty, var session,
              session.selectedAuthorID == fromAuthorID,
              session.currentPage?.id == fromPageID else { return false }
        if chronologicalPosts || session.scopedPlaceID != nil {
            let pages = FriendStoryPageSelection.pagerPages(in: session,
                chronologicalPosts: chronologicalPosts)
            guard let sourceIndex = pages.firstIndex(where: { $0.id == fromPageID }),
                  let destinationIndex = pages.firstIndex(where: { $0.id == id }),
                  abs(destinationIndex - sourceIndex) == 1 else { return false }
            let destination = pages[destinationIndex]
            if destination.authorID != session.selectedAuthorID {
                guard session.selectAuthor(id: destination.authorID) else { return false }
            }
            session.selectPage(id: destination.id)
            self.session = session
            return true
        }
        guard let group = session.currentGroup,
              let pageIndex = session.currentPageIndex,
              let authorIndex = session.groups.firstIndex(where: { $0.authorID == fromAuthorID }) else {
            return false
        }
        if let destinationIndex = group.pages.firstIndex(where: { $0.id == id }) {
            guard abs(destinationIndex - pageIndex) == 1 else { return false }
            guard session.selectPage(id: id) else { return false }
        } else {
            let next = session.groups.indices.contains(authorIndex + 1)
                ? session.groups[authorIndex + 1].pages.first : nil
            let previous = authorIndex > 0 ? session.groups[authorIndex - 1].pages.last : nil
            let destination: FriendStoryPage?
            if pageIndex == group.pages.count - 1, next?.id == id {
                destination = next
            } else if pageIndex == 0, previous?.id == id {
                destination = previous
            } else {
                destination = nil
            }
            guard let destination,
                  session.selectAuthor(id: destination.authorID) else { return false }
            // Author entry can restore an old cursor. A sequential swipe must
            // override it even when every destination page was already read.
            session.selectPage(id: destination.id)
        }
        self.session = session
        return true
    }

    /// A child belongs to the card that was tapped, which can be the incoming
    /// page of a swipe whose idle callback hasn't committed yet.
    @discardableResult
    func push(_ route: Route, from page: FriendStoryPage? = nil) -> Bool {
        var route = route
        if routes.isEmpty {
            if let page, !restoreRootPage(id: page.id) { return false }
            route.returnPageID = session?.currentPage?.id
        }
        routes.append(route)
        return true
    }

    @discardableResult
    func popRoute() -> Route? {
        guard let route = routes.last else { return nil }
        // Restore before revealing the retained root pager. Resolve against
        // live content, never a saved Post payload that may have been removed.
        if routes.count == 1, let id = route.returnPageID {
            restoreRootPage(id: id)
        }
        routes.removeLast()
        return route
    }

    @discardableResult
    private func restoreRootPage(id: String) -> Bool {
        guard var session, !session.isEnded,
              let page = session.pagesInStoryOrder.first(where: { $0.id == id }) else { return false }
        guard session.currentPage?.id != id else { return true }
        session.selectAuthor(id: page.authorID)
        session.selectPage(id: id)
        self.session = session
        return true
    }

    func clear() {
        session = nil
        routes = []
        origin = nil
        lastLocationKey = nil
        lastViewportSize = nil
        lastFocusedAuthorID = nil
    }
}

/// Keeps parent cards mounted while visiting a place or Bubble, so returning
/// does not reconstruct the author's current page or restart its video.
struct FriendStoryFlow: View {
    @ObservedObject var navigation: FriendStoryNavigation
    @Binding var detent: PresentationDetent
    let compactDetent: PresentationDetent
    let viewedKeys: Set<String>
    let userProvider: (UUID) -> User?
    let journeyProvider: (UUID) -> JourneyPost?
    let placeProvider: (UUID) -> RatedPOI?
    let captureCamera: () -> FriendStoryNavigation.MapSnapshot
    let restoreCamera: (FriendStoryNavigation.MapSnapshot) -> Void
    let focusPage: (FriendStoryPage) -> Void
    let focusContent: (ExperienceDetailView.Mode) -> Void
    let onRead: (String) -> Void
    let onClose: () -> Void
    var allowsPlayback = true
    var feedPresentation: MapTalkFeedPresentation = .personStory
    var showsPlaceAuthors = false
    var cumulativeVisitDayCount: (UUID, UUID) -> Int? = { _, _ in nil }
    var showsBubbleProgress = false
    var hasMorePosts = false
    var isLoadingPosts = false
    var postFeedIssue: String? = nil
    var onRetryPosts: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @Environment(\.colorScheme) private var inheritedRouteColorScheme
    @State private var placeHistoryStatus: [UUID: PlaceHistoryStatus] = [:]
    @State private var placeHistoryRetry: [UUID: Int] = [:]
    @State private var placeHistoryPages: [UUID: BackendStore.PlaceHistoryPage] = [:]
    @State private var placeHistoryLoadFailed: Set<UUID> = []
    @State private var authoritativeVisitCounts: [BackendPOIVisitCountKey: Int] = [:]
    @State private var visitCountRevision = 0

    private enum PlaceHistoryStatus { case loading, loadingMore, loaded, unavailable }

    private var isExpanded: Bool { detent == .large }

    static func shouldFocusPlace(isCurrentPlace: Bool, isExpanded: Bool) -> Bool {
        // Preserve the current compact-place camera. An expanded place route
        // explicitly requests its own framing, even for the same location.
        !isCurrentPlace || isExpanded
    }

    var body: some View {
        ZStack {
            if let session = navigation.session,
               let group = session.currentGroup,
               let page = session.currentPage {
                FriendStoryContentView(
                    group: group,
                    page: page,
                    pageIndex: session.currentPageIndex ?? 0,
                    pagerPages: FriendStoryPageSelection.pagerPages(in: session,
                        chronologicalPosts: feedPresentation == .posts),
                    pagerUserProvider: { id in
                        userProvider(id) ?? session.groups.first(where: { $0.authorID == id })?.user
                    },
                    selectedPageID: Binding(
                        // UIKit may read this binding again before SwiftUI
                        // redraws. Always return the live cursor, not `page`'s
                        // previous-render snapshot after a progress-bar tap.
                        get: { navigation.session?.currentPage?.id ?? page.id },
                        set: { selectPagerPage($0, fromAuthorID: group.authorID, fromPageID: page.id) }
                    ),
                    viewedKeys: viewedKeys,
                    isExpanded: isExpanded,
                    isPlaybackActive: allowsPlayback && scenePhase == .active && navigation.routes.isEmpty,
                    onPreviousPage: { movePage(-1) },
                    onNextPage: { movePage(1) },
                    onSelectPage: { index in
                        guard group.pages.indices.contains(index) else { return }
                        selectPage(group.pages[index].id, authorID: group.authorID)
                    },
                    onExpand: {
                        withAnimation(.easeInOut(duration: 0.24)) { detent = .large }
                    },
                    onClose: onClose,
                    onJourney: { bubble, sourcePage in openBubble(bubble, from: sourcePage) },
                    onReadReady: onRead,
                    journeyProvider: journeyProvider,
                    userProvider: userProvider,
                    placeProvider: placeProvider,
                    feedPresentation: feedPresentation,
                    showsVisitExpression: feedPresentation == .personStory,
                    showsPersonalVisitCount: feedPresentation == .personStory,
                    personalVisitCountLabel: cumulativeVisitLabel(for: page),
                    allowsLoadedVisitCountFallback: false,
                    showsHeaderTimestamp: feedPresentation != .personStory,
                    placeAuthors: currentPlaceAuthors,
                    allowsPOIMediaLightbox: feedPresentation != .personStory
                )
                .environment(\.experiencePOIHistoryVisible, feedPresentation != .personStory)
                // The story root already hydrates its one selected visit.
                // Hidden place history must not prepare every historical video
                // merely because the current media card was expanded.
                .environment(\.experienceLiveMediaHydrationEnabled, feedPresentation != .personStory)
                .environment(\.experiencePOIRecentSharersVisible, feedPresentation != .personStory)
                .environment(\.experiencePOIPlaceHeader, instantPlaceHeader(for: page))
                .environment(\.experiencePOIPlaybackActions, instantPlaybackFooter(for: page))
                .task(id: "\(page.id):\(visitCountRevision)") {
                    guard feedPresentation == .personStory, allowsPlayback,
                          case let .poi(place, _, _) = page.content,
                          let store = environment.backend else { return }
                    let authors = navigation.isPlaceScoped ? session.groups.map(\.authorID) : [page.authorID]
                    await store.ensurePOIVisitDayCounts(placeID: place.id, ownerIDs: authors)
                }
                .opacity(navigation.routes.isEmpty ? 1 : 0)
                .allowsHitTesting(navigation.routes.isEmpty)
                .accessibilityHidden(!navigation.routes.isEmpty)
            }

            ForEach(navigation.routes) { route in
                routeContent(route)
                    .opacity(navigation.routes.last?.id == route.id ? 1 : 0)
                    .allowsHitTesting(navigation.routes.last?.id == route.id)
                    .accessibilityHidden(navigation.routes.last?.id != route.id)
            }
        }
        .overlay(alignment: .bottom) {
            if feedPresentation == .posts, navigation.routes.isEmpty,
               let session = navigation.session,
               FriendStoryPageSelection.pagerPages(in: session, chronologicalPosts: true).last?.id
                    == session.currentPage?.id {
                if isLoadingPosts {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 4)
                        .accessibilityLabel("Loading older posts")
                } else if hasMorePosts {
                    Button(postFeedIssue == nil ? "Load older posts" : "Couldn't load more · Retry",
                           action: onRetryPosts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 4)
                }
            }
        }
        .onReceive(environment.backend?.$poiVisitDayCounts.eraseToAnyPublisher()
            ?? Just([BackendPOIVisitCountKey: Int]()).eraseToAnyPublisher()) { counts in
            authoritativeVisitCounts = counts
        }
        .onReceive(environment.backend?.$poiVisitCountRevision.eraseToAnyPublisher()
            ?? Just(0).eraseToAnyPublisher()) { visitCountRevision = $0 }
        .onChangeCompat(of: isExpanded) { expanded in
            guard !expanded else { return }
            returnFromPlaceAfterCollapse()
        }
    }

    private func movePage(_ offset: Int) {
        if feedPresentation == .posts || navigation.isPlaceScoped {
            guard let session = navigation.session, let page = session.currentPage else { return }
            let pages = FriendStoryPageSelection.pagerPages(in: session,
                chronologicalPosts: feedPresentation == .posts)
            guard let current = pages.firstIndex(where: { $0.id == page.id }) else { return }
            let (target, overflow) = current.addingReportingOverflow(offset)
            guard !overflow, pages.indices.contains(target) else {
                if navigation.isPlaceScoped, offset > 0 { onClose() }
                return
            }
            selectPagerPage(pages[target].id, fromAuthorID: page.authorID, fromPageID: page.id)
            return
        }
        guard navigation.routes.isEmpty, navigation.session?.currentPage != nil else { return }
        let moved = navigation.session?.movePage(by: offset) == true
        // Like Stories, a forward tap at the end continues to the next person.
        // The final person's final update closes POI browsing, never opens Posts.
        if !moved {
            if offset < 0 {
                // Back from a person's first update returns to the previous
                // person's last one, not their forward/unread entry cursor.
                guard navigation.session?.moveAuthor(by: -1, viewedKeys: viewedKeys) == true,
                      let lastPage = navigation.session?.currentGroup?.pages.last else { return }
                navigation.session?.selectPage(id: lastPage.id)
            } else if offset > 0 {
                guard navigation.session?.moveAuthor(by: 1, viewedKeys: viewedKeys) == true else {
                    onClose()
                    return
                }
            } else {
                return
            }
        }
        guard let page = navigation.session?.currentPage else { return }
        focusPage(page)
    }

    private func selectPage(_ id: String, authorID: UUID) {
        // A delayed native-pager callback from the previous person's card
        // must never move the new person's cursor. Absolute IDs are idempotent.
        guard navigation.session?.selectedAuthorID == authorID,
              navigation.session?.selectPage(id: id) == true,
              let page = navigation.session?.currentPage else { return }
        focusPage(page)
    }

    private func selectPagerPage(_ id: String, fromAuthorID: UUID, fromPageID: String) {
        guard navigation.selectPagerPage(id: id, fromAuthorID: fromAuthorID, fromPageID: fromPageID,
            chronologicalPosts: feedPresentation == .posts),
              let page = navigation.session?.currentPage else { return }
        focusPage(page)
    }

    private func routeColorScheme(_ route: FriendStoryNavigation.Route) -> ColorScheme {
        if case .place = route.content { return .dark }
        return inheritedRouteColorScheme
    }

    private func cumulativeVisitLabel(for page: FriendStoryPage) -> String? {
        guard feedPresentation == .personStory, case let .poi(place, _, _) = page.content else { return nil }
        let count: Int?
        if environment.backend != nil {
            count = authoritativeVisitCounts[.init(placeId: place.id, ownerId: page.authorID)]
        } else {
            let fullPlace = placeProvider(place.id) ?? place
            count = cumulativeVisitDayCount(place.id, page.authorID)
                ?? fullPlace.checkInPeople().first { $0.userID == page.authorID }?.visitDayCount
        }
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 visit" : "\(count) visits"
    }

    /// The avatar stack describes this place; it does not own the pager.
    private var currentPlaceAuthors: [User] {
        guard showsPlaceAuthors, feedPresentation == .personStory, let session = navigation.session,
              let current = session.currentPage,
              case let .poi(currentPlace, _, _) = current.content else { return [] }
        var seen = Set<UUID>()
        return session.pagesInStoryOrder.compactMap { page in
            guard case let .poi(place, _, _) = page.content, place.id == currentPlace.id,
                  seen.insert(page.authorID).inserted else { return nil }
            return userProvider(page.authorID) ?? session.groups.first { $0.authorID == page.authorID }?.user
        }
    }

    private func instantPlaceHeader(for page: FriendStoryPage) -> ((UUID) -> AnyView?)? {
        guard feedPresentation == .personStory, case .poi = page.content else { return nil }
        let pages = navigation.session?.pagesInStoryOrder ?? []
        return { id in
            let place = placeProvider(id) ?? pages.compactMap { candidate -> RatedPOI? in
                guard case let .poi(place, _, _) = candidate.content, place.id == id else { return nil }
                return place
            }.first
            guard let place else { return nil }
            // Instant browsing stays in its own queue. Historical visitor
            // avatars keep their separate viewer; this heading is display-only.
            return AnyView(POIStoryPlaceHeading(place: place,
                trailingAction: AnyView(POIStorySaveButton(place: place))))
        }
    }

    private func instantPlaybackFooter(for page: FriendStoryPage) -> AnyView? {
        guard feedPresentation == .personStory, case let .poi(place, visit, _) = page.content else { return nil }
        return AnyView(POIStoryPlaybackFooter(place: place, publishedAt: page.publishedAt,
            trailingActions: AnyView(POIStoryMediaActions(visit: visit, mediaID: page.mediaID).id(page.id))))
    }

    private func openPlace(_ id: UUID, from sourcePage: FriendStoryPage) {
        guard navigation.routes.isEmpty, allowsPlayback,
              navigation.session?.currentPage?.id == sourcePage.id,
              case let .poi(sourcePlace, _, _) = sourcePage.content,
              sourcePlace.id == id else { return }
        let place = placeProvider(id) ?? sourcePlace
        let isCurrentPlace: Bool
        if case let .poi(current, _, _)? = navigation.session?.currentPage?.content {
            isCurrentPlace = navigation.routes.isEmpty && current.id == id
        } else { isCurrentPlace = false }
        guard navigation.push(.init(
            content: .place(place),
            returnCamera: captureCamera(),
            returnDetent: detent
        ), from: sourcePage) else { return }
        if Self.shouldFocusPlace(isCurrentPlace: isCurrentPlace, isExpanded: isExpanded) {
            focusContent(.poi(place))
        }
        withAnimation(.easeInOut(duration: 0.24)) { detent = .large }
    }

    private func openBubble(_ bubble: JourneyPost, from sourcePage: FriendStoryPage? = nil) {
        // Returning to an ancestor is a pop, not a cycle of identical pages.
        if let index = navigation.routes.firstIndex(where: { route in
            if case let .bubble(scope) = route.content { return scope.journey.id == bubble.id }
            return false
        }) {
            navigation.routes = Array(navigation.routes.prefix(index + 1))
            focusContent(.journey(bubble))
            return
        }
        let scope = MapJourneyScope(journey: bubble, userProvider: userProvider)
        guard navigation.push(.init(
            content: .bubble(scope),
            selectedID: scope.firstStoryItem?.id,
            returnCamera: captureCamera(),
            returnDetent: detent
        ), from: sourcePage) else { return }
        focusContent(.journey(bubble))
    }

    @ViewBuilder
    private func routeContent(_ route: FriendStoryNavigation.Route) -> some View {
        VStack(spacing: 0) {
            if !showsBubbleProgress || !isBubbleRoute(route) {
                HStack {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to story")
                    .accessibilityIdentifier("maptalk.friend-story.back")
                    Spacer()
                    Text(routeTitle(route)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close story")
                    .accessibilityIdentifier("maptalk.friend-story.close")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .background(.regularMaterial)
            }

            switch route.content {
            case let .place(place):
                if environment.backend == nil || (placeHistoryPages[route.id] != nil
                    && placeHistoryStatus[route.id] != .unavailable) {
                    ExperienceDetailView(
                        ratedPOI: place,
                        isExpanded: isExpanded,
                        usesUpdatedPOIStyle: true,
                        onCollapsedTap: { detent = .large },
                        userProvider: userProvider,
                        onPOIContributorViewed: { $0.forEach(onRead) },
                        isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                    )
                    if environment.backend != nil {
                        if placeHistoryStatus[route.id] == .loading || placeHistoryStatus[route.id] == .loadingMore {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .accessibilityLabel("Loading visits")
                        } else if placeHistoryPages[route.id]?.nextCursor != nil {
                            Button(placeHistoryLoadFailed.contains(route.id) ? "Retry earlier visits" : "Load earlier visits") {
                                placeHistoryStatus[route.id] = nil
                                placeHistoryRetry[route.id, default: 0] += 1
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("maptalk.friend-story.earlier-visits")
                        }
                    }
                } else if placeHistoryStatus[route.id] == .unavailable {
                    VStack(spacing: 14) {
                        Image(systemName: "mappin.slash").font(.title2)
                        Text("This place isn't available right now.").font(.subheadline)
                        Button("Try again") {
                            placeHistoryStatus[route.id] = nil
                            placeHistoryRetry[route.id, default: 0] += 1
                        }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case let .reel(reel):
                ExperienceDetailView(
                    mode: .real(reel, userProvider(reel.userId)),
                    isExpanded: isExpanded,
                    onCollapsedTap: { detent = .large },
                    onJourneyAvatarStackTap: { openBubble($0) },
                    journeyProvider: journeyProvider,
                    userProvider: userProvider
                )
            case let .bubble(scope):
                if showsBubbleProgress {
                    HomeBubbleContentView(
                        scope: scope,
                        selection: Binding(
                            get: { navigation.routes.first(where: { $0.id == route.id })?.selectedID },
                            set: { id in
                                guard navigation.routes.last?.id == route.id,
                                      let id,
                                      let item = scope.sequenceItems.first(where: { $0.id == id }),
                                      let index = navigation.routes.firstIndex(where: { $0.id == route.id }),
                                      navigation.routes[index].selectedID != id else { return }
                                navigation.routes[index].selectedID = id
                                focusContent(item.mode)
                            }
                        ),
                        isExpanded: isExpanded,
                        isActive: allowsPlayback && navigation.routes.last?.id == route.id,
                        onExpand: { detent = .large },
                        onBack: goBack,
                        onClose: onClose,
                        onJourney: { openBubble($0) },
                        journeyProvider: journeyProvider,
                        userProvider: userProvider,
                        onRead: onRead,
                        viewedKeys: viewedKeys
                    )
                } else if let selectedID = route.selectedID {
                    MapExperienceCapsule(
                        pager: .init(items: scope.sequenceItems),
                        selection: Binding(
                            get: { navigation.routes.first(where: { $0.id == route.id })?.selectedID ?? selectedID },
                            set: { id in
                                guard let index = navigation.routes.firstIndex(where: { $0.id == route.id }) else { return }
                                navigation.routes[index].selectedID = id
                                if let item = scope.sequenceItems.first(where: { $0.id == id }) { focusContent(item.mode) }
                            }
                        ),
                        isExpanded: isExpanded,
                        onCollapsedTap: { detent = .large },
                        journeyProvider: journeyProvider,
                        userProvider: userProvider,
                        onJourneyAvatarStackTap: { openBubble($0) },
                        onPOIContributorViewed: { $0.forEach(onRead) },
                        isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                    )
                    .environment(\.experienceLiveMediaHydrationEnabled, false)
                } else {
                    MapJourneyEmptyCapsule()
                }
            }
        }
        .environment(\.colorScheme, routeColorScheme(route))
        .environment(\.friendStoryPlaybackEnabled, allowsPlayback && scenePhase == .active && navigation.routes.last?.id == route.id)
        .task(id: allowsPlayback && scenePhase == .active && navigation.routes.last?.id == route.id ? route.id : nil) {
            guard allowsPlayback, scenePhase == .active, navigation.routes.last?.id == route.id,
                  case let .bubble(scope) = route.content, scope.journey.isPublishedSnapshot,
                  let backend = environment.backend else { return }
            let parentID = scope.journey.id
            do {
                // Opening the Bubble can cancel its parent Post's task. Its
                // visible root owns the same parent-authorized download now;
                // never resolve frozen members through their live record IDs.
                try await backend.ensureMedia(for: [parentID])
                guard !Task.isCancelled, navigation.routes.last?.id == route.id,
                      let refreshed = backend.journey(for: parentID, publicOnly: true),
                      let index = navigation.routes.firstIndex(where: { $0.id == route.id }),
                      case let .bubble(current) = navigation.routes[index].content,
                      current.journey.id == parentID else { return }
                // Replace bytes in the existing route, not its identity,
                // selected member, camera or return position. Both the Home
                // progress view and the fallback capsule observe this scope.
                navigation.routes[index].content = .bubble(MapJourneyScope(journey: refreshed,
                                                                           userProvider: userProvider))
            } catch { }
        }
        .task(id: placeHistoryRetry[route.id, default: 0]) {
            guard case let .place(place) = route.content,
                  let backend = environment.backend,
                  placeHistoryStatus[route.id] == nil else { return }
            let previous = placeHistoryPages[route.id]
            placeHistoryStatus[route.id] = previous == nil ? .loading : .loadingMore
            placeHistoryLoadFailed.remove(route.id)
            let requestRevision = backend.publicContentRevision
            var hasVerifiedMetadata = previous?.revision == requestRevision
            do {
                let loaded = try await backend.loadPlaceHistory(placeID: place.id, after: previous) { updated in
                    guard let updatedPlace = updated.place,
                          let index = navigation.routes.firstIndex(where: { $0.id == route.id }) else { return }
                    hasVerifiedMetadata = true
                    placeHistoryPages[route.id] = updated
                    navigation.routes[index].content = .place(updatedPlace)
                }
                guard !Task.isCancelled else { return }
                guard let loadedPlace = loaded.place,
                      let index = navigation.routes.firstIndex(where: { $0.id == route.id }) else {
                    placeHistoryPages.removeValue(forKey: route.id)
                    placeHistoryStatus[route.id] = .unavailable
                    return
                }
                placeHistoryPages[route.id] = loaded
                navigation.routes[index].content = .place(loadedPlace)
                placeHistoryStatus[route.id] = .loaded
            } catch {
                guard !Task.isCancelled,
                      navigation.routes.contains(where: { $0.id == route.id }) else { return }
                if BackendStore.canRetainVerifiedPlaceHistory(after: error,
                    hasVerifiedMetadata: hasVerifiedMetadata, requestRevision: requestRevision,
                    currentRevision: backend.publicContentRevision, isActive: backend.isActive) {
                    // A failed next page keeps verified earlier pages visible.
                    // A failed asset likewise does not hide its authorized page.
                    placeHistoryStatus[route.id] = .loaded
                    if placeHistoryPages[route.id]?.nextCursor == previous?.nextCursor, previous != nil {
                        placeHistoryLoadFailed.insert(route.id)
                    }
                    return
                }
                // A revision cancellation can occur while this route remains
                // mounted. Show Retry instead of leaving it spinning forever.
                // Missing/auth-denied places never fall back to stale history.
                placeHistoryPages.removeValue(forKey: route.id)
                placeHistoryStatus[route.id] = .unavailable
            }
        }
        .onReceive(environment.backend?.publicContentChanges.eraseToAnyPublisher()
            ?? Empty<Set<UUID>, Never>().eraseToAnyPublisher()) { _ in
            guard case .place = route.content else { return }
            // Every accumulated page belongs to one access revision. Never
            // append a new revision to old history, even on a hidden child.
            placeHistoryPages.removeValue(forKey: route.id)
            placeHistoryStatus[route.id] = .unavailable
            placeHistoryRetry[route.id, default: 0] += 1
        }
    }

    private func routeTitle(_ route: FriendStoryNavigation.Route) -> String {
        switch route.content {
        case let .place(place): return place.poi.name
        case let .reel(reel): return userProvider(reel.userId)?.handle ?? "Reel"
        case let .bubble(scope): return scope.journey.title
        }
    }

    private func isBubbleRoute(_ route: FriendStoryNavigation.Route) -> Bool {
        if case .bubble = route.content { return true }
        return false
    }

    private func returnFromPlaceAfterCollapse() {
        guard feedPresentation == .personStory, detent == compactDetent,
              navigation.routes.count == 1, let route = navigation.routes.last,
              case let .place(place) = route.content, let pageID = route.returnPageID,
              let page = navigation.session?.pagesInStoryOrder.first(where: { $0.id == pageID }),
              case let .poi(sourcePlace, _, _) = page.content,
              sourcePlace.id == place.id,
              navigation.popRoute() != nil else { return }
        // UIKit has already collapsed. Reveal the retained story at that size,
        // without restoring its former large detent or reflying the same place.
        restoreCamera(route.returnCamera)
    }

    private func goBack() {
        guard let route = navigation.popRoute() else { return }
        detent = route.returnDetent == .large ? .large : compactDetent
        restoreCamera(route.returnCamera)
        if navigation.routes.isEmpty, let page = navigation.session?.currentPage {
            // Usually a no-op: preserve the exact manually adjusted parent
            // camera. A resized viewport needs fresh occlusion framing.
            focusPage(page)
        }
    }
}

/// One native surface, two independent browsing/detent owners. Switching
/// content keeps the surface mounted. During native opening/closing, only the
/// latest entry request waits for that transition to finish.
@MainActor
final class MapTalkCardPresentation: ObservableObject {
    let poi: MapExperiencePresentation
    let posts: MapExperiencePresentation
    let motion = ProfileCardSheetMotion()
    let sources = MapTalkCardSourceRegistry()

    @Published private(set) var activeFlow: MapTalkFeedPresentation = .personStory
    @Published private(set) var isPresented = false
    // The model closes before UIKit finishes zooming back to the source.
    @Published private(set) var isMounted = false
    // The departing card still owns its source until UIKit finishes or cancels.
    // New entry taps wait until this physical transition completes.
    @Published private(set) var closingContent: MapTalkCardContentIdentity?

    var mountedFlow: MapTalkFeedPresentation? {
        isMounted ? (closingContent?.flow ?? activeFlow) : nil
    }

    var current: MapExperiencePresentation { owner(for: activeFlow) }

    private var isReplacingContent = false
    private var isNativeTransitioning = false
    private var pendingPresentation: (flow: MapTalkFeedPresentation, action: () -> Void)?
    // UIKit sets isBeingDismissed before its appearance/delegate callbacks.
    // Inspect that real state at tap time so this first-frame gap can't mutate
    // the departing card's shared navigation.
    var deferSelectionForNativeTransition: (() -> Bool)?
    private var subscriptions = Set<AnyCancellable>()

    init(poiCompactFraction: Double, postCompactFraction: Double) {
        poi = MapExperiencePresentation(compactDetent: .fraction(poiCompactFraction),
                                       keepsSheetMountedOnSelection: true)
        posts = MapExperiencePresentation(compactDetent: .fraction(postCompactFraction),
                                         keepsSheetMountedOnSelection: true)
        observe(poi, flow: .personStory)
        observe(posts, flow: .posts)
    }

    func perform(in flow: MapTalkFeedPresentation, action: @escaping () -> Void) {
        // The outgoing card observes the same navigation model. Don't change
        // its live content while it is shrinking/growing. Keep the latest tap
        // and apply it at the real native completion, never on a timer.
        let nativeIsTransitioning = deferSelectionForNativeTransition?() ?? false
        guard !isNativeTransitioning && !nativeIsTransitioning else {
            pendingPresentation = (flow, action)
            return
        }
        if flow == activeFlow {
            action()
            return
        }
        let previousFlow = activeFlow
        let previous = current
        isReplacingContent = true
        activeFlow = flow
        action()
        if current.isPresented {
            previous.dismiss(preservingDetent: true)
        } else if previous.isPresented {
            // A guarded/invalid request must not close the card already open.
            activeFlow = previousFlow
        }
        isReplacingContent = false
    }

    func nativePresentationChanged(_ presented: Bool) {
        guard !presented, isPresented else { return }
        current.dismiss(preservingDetent: true)
    }

    /// An explicit close is the latest intent, unlike native completion of an
    /// older card. It cancels any earlier tap waiting behind an animation.
    func dismiss(preservingDetent: Bool = true) {
        discardPendingPresentation()
        current.dismiss(preservingDetent: preservingDetent)
    }

    func nativeDismissalBegan(of content: MapTalkCardContentIdentity) {
        isNativeTransitioning = true
        if closingContent == nil { closingContent = content }
    }

    func nativePresentationBegan() {
        isNativeTransitioning = true
    }

    func nativeTransitionEnded() {
        isNativeTransitioning = false
        if closingContent != nil { closingContent = nil }
    }

    @discardableResult
    func resumePendingPresentation() -> Bool {
        guard !isNativeTransitioning, let pending = pendingPresentation else { return false }
        pendingPresentation = nil
        perform(in: pending.flow, action: pending.action)
        return true
    }

    func discardPendingPresentation() {
        pendingPresentation = nil
    }

    /// True means the host must leave navigation/selection intact. Only a
    /// genuine close of the current flow returns false for host cleanup.
    @discardableResult
    func didDismiss(_ flow: MapTalkFeedPresentation) -> Bool {
        guard flow == activeFlow, !isPresented else { return true }
        _ = current.didDismiss()
        isMounted = false
        return false
    }

    private func owner(for flow: MapTalkFeedPresentation) -> MapExperiencePresentation {
        flow == .posts ? posts : poi
    }

    private func observe(_ owner: MapExperiencePresentation, flow: MapTalkFeedPresentation) {
        owner.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        owner.$isPresented.removeDuplicates().sink { [weak self] presented in
            guard let self, self.activeFlow == flow else { return }
            if presented {
                self.isMounted = true
                self.isPresented = true
            } else if self.isPresented && !self.isReplacingContent {
                self.isPresented = false
            }
        }.store(in: &subscriptions)
    }

}

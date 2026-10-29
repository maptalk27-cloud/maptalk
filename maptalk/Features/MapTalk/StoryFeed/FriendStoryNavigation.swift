import Combine
import MapKit
import SwiftUI

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

/// Leave real map pixels above the native sheet for its detached identity.
/// The model still uses `.large`, so existing media and return routes retain
/// their expanded behavior without replacing the native pan recognizer.
private struct FriendStoryExpandedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        max(1, context.maxDetentValue - FriendStoryLayout.floatingHeight)
    }
}

struct FriendStorySheetChrome: ViewModifier {
    @ObservedObject var presentation: MapExperiencePresentation
    @ObservedObject var navigation: FriendStoryNavigation

    func body(content: Content) -> some View {
        if navigation.isActive {
            let expanded = PresentationDetent.custom(FriendStoryExpandedDetent.self)
            content
                .mapExperienceSheetChrome(compactDetent: presentation.compactDetent,
                                          expandedDetent: expanded, selection: Binding(
                    get: { presentation.isExpanded ? expanded : presentation.compactDetent },
                    set: { presentation.detent = $0 == expanded ? .large : presentation.compactDetent }
                ))
        } else {
            // Direct map cards keep the original native detents and binding.
            // Person-story navigation must not translate their presentation.
            content.mapExperienceSheetChrome(compactDetent: presentation.compactDetent,
                                             selection: $presentation.detent)
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
    static func pagerPages(in session: FriendStorySession) -> [FriendStoryPage] {
        session.groups.flatMap(\.pages)
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
    }

    @Published var session: FriendStorySession?
    @Published var routes: [Route] = []
    var origin: MapSnapshot?
    var lastLocationKey: String?
    var lastViewportSize: CGSize?
    var lastFocusedAuthorID: UUID?

    var isActive: Bool { session != nil }

    func needsMapFocus(locationKey: String, viewportSize: CGSize, authorID: UUID? = nil) -> Bool {
        lastLocationKey != locationKey || lastViewportSize != viewportSize
            || (authorID != nil && lastFocusedAuthorID != authorID)
    }

    func begin(groups: [FriendStoryGroup], authorID: UUID, viewedKeys: Set<String>, origin: MapSnapshot) {
        guard groups.contains(where: { $0.authorID == authorID && !$0.pages.isEmpty })
            || session?.groups.contains(where: { $0.authorID == authorID }) == true else { return }
        if self.origin == nil { self.origin = origin }
        if session?.groups.contains(where: { $0.authorID == authorID }) == true {
            session?.selectAuthor(id: authorID, viewedKeys: viewedKeys)
        } else {
            session = FriendStorySession(groups: groups, authorID: authorID, viewedKeys: viewedKeys)
        }
        routes.removeAll()
    }

    /// The lower card pager may cross an author boundary only from its edge,
    /// landing on the exact adjacent card rather than an unread/resume cursor.
    /// Explicit author selection keeps its existing resume/unread entry rules.
    @discardableResult
    func selectPagerPage(id: String, fromAuthorID: UUID) -> Bool {
        guard routes.isEmpty, var session,
              session.selectedAuthorID == fromAuthorID,
              let group = session.currentGroup,
              let pageIndex = session.currentPageIndex,
              let authorIndex = session.groups.firstIndex(where: { $0.authorID == fromAuthorID }) else {
            return false
        }
        if group.pages.contains(where: { $0.id == id }) {
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @State private var placeHistoryStatus: [UUID: PlaceHistoryStatus] = [:]
    @State private var placeHistoryRetry: [UUID: Int] = [:]
    @State private var placeHistoryPages: [UUID: BackendStore.PlaceHistoryPage] = [:]
    @State private var placeHistoryLoadFailed: Set<UUID> = []

    private enum PlaceHistoryStatus { case loading, loadingMore, loaded, unavailable }

    private var isExpanded: Bool { detent == .large }

    static func shouldFocusPlace(isCurrentPlace: Bool, isExpanded: Bool) -> Bool {
        // Expanded stories defer map movement. Even the current place can
        // therefore be different from the camera behind the full-screen card.
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
                    pagerPages: FriendStoryPageSelection.pagerPages(in: session),
                    pagerUserProvider: { id in
                        userProvider(id) ?? session.groups.first(where: { $0.authorID == id })?.user
                    },
                    selectedPageID: Binding(
                        // UIKit may read this binding again before SwiftUI
                        // redraws. Always return the live cursor, not `page`'s
                        // previous-render snapshot after a progress-bar tap.
                        get: { navigation.session?.currentPage?.id ?? page.id },
                        set: { selectPagerPage($0, fromAuthorID: group.authorID) }
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
                    onJourney: openBubble,
                    onReadReady: onRead,
                    journeyProvider: journeyProvider,
                    userProvider: userProvider,
                    placeProvider: placeProvider
                )
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
    }

    private func movePage(_ offset: Int) {
        guard navigation.session?.movePage(by: offset) == true,
              let page = navigation.session?.currentPage else { return }
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

    private func selectPagerPage(_ id: String, fromAuthorID: UUID) {
        guard navigation.selectPagerPage(id: id, fromAuthorID: fromAuthorID),
              let page = navigation.session?.currentPage else { return }
        focusPage(page)
    }

    private func openPlace(_ id: UUID) {
        guard let place = placeProvider(id) else { return }
        let isCurrentPlace: Bool
        if case let .poi(current, _, _)? = navigation.session?.currentPage?.content {
            isCurrentPlace = navigation.routes.isEmpty && current.id == id
        } else { isCurrentPlace = false }
        navigation.routes.append(.init(
            content: .place(place),
            returnCamera: captureCamera(),
            returnDetent: detent
        ))
        if Self.shouldFocusPlace(isCurrentPlace: isCurrentPlace, isExpanded: isExpanded) {
            focusContent(.poi(place))
        }
    }

    private func openBubble(_ bubble: JourneyPost) {
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
        navigation.routes.append(.init(
            content: .bubble(scope),
            selectedID: scope.firstStoryItem?.id,
            returnCamera: captureCamera(),
            returnDetent: detent
        ))
        focusContent(.journey(bubble))
    }

    @ViewBuilder
    private func routeContent(_ route: FriendStoryNavigation.Route) -> some View {
        VStack(spacing: 0) {
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

            switch route.content {
            case let .place(place):
                if environment.backend == nil || (placeHistoryPages[route.id] != nil
                    && placeHistoryStatus[route.id] != .unavailable) {
                    ExperienceDetailView(
                        ratedPOI: place,
                        isExpanded: isExpanded,
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
                    onJourneyAvatarStackTap: openBubble,
                    journeyProvider: journeyProvider,
                    userProvider: userProvider
                )
            case let .bubble(scope):
                if let selectedID = route.selectedID {
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
                        onJourneyAvatarStackTap: openBubble,
                        onPOIContributorViewed: { $0.forEach(onRead) },
                        isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                    )
                } else {
                    MapJourneyEmptyCapsule()
                }
            }
        }
        .environment(\.friendStoryPlaybackEnabled, allowsPlayback && scenePhase == .active && navigation.routes.last?.id == route.id)
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

    private func goBack() {
        guard let route = navigation.routes.popLast() else { return }
        detent = route.returnDetent == .large ? .large : compactDetent
        restoreCamera(route.returnCamera)
        if navigation.routes.isEmpty, let page = navigation.session?.currentPage {
            // Usually a no-op: preserve the exact manually adjusted parent
            // camera. A resized viewport needs fresh occlusion framing.
            focusPage(page)
        }
    }
}

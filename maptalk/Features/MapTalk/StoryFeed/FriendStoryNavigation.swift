import Combine
import MapKit
import SwiftUI

enum FriendStoryLayout {
    // The original card keeps its full compact height underneath the author
    // controls; this is not a new media layout or a third presentation stop.
    static let navigationAllowance: CGFloat = 72

    static func compactFraction(base: CGFloat, availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return base }
        return min(0.55, base + navigationAllowance / availableHeight)
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

    var isActive: Bool { session != nil }

    func needsMapFocus(locationKey: String, viewportSize: CGSize) -> Bool {
        lastLocationKey != locationKey || lastViewportSize != viewportSize
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

    func clear() {
        session = nil
        routes = []
        origin = nil
        lastLocationKey = nil
        lastViewportSize = nil
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
                    isExpanded: isExpanded,
                    isPlaybackActive: allowsPlayback && scenePhase == .active && navigation.routes.isEmpty,
                    onPreviousPage: { movePage(-1) },
                    onNextPage: { movePage(1) },
                    onPreviousAuthor: { moveAuthor(-1) },
                    onNextAuthor: { moveAuthor(1) },
                    onExpand: {
                        withAnimation(.easeInOut(duration: 0.24)) { detent = .large }
                    },
                    onClose: onClose,
                    onLocation: openPlace,
                    onJourney: openBubble,
                    onReadReady: onRead,
                    journeyProvider: journeyProvider,
                    userProvider: userProvider
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

    private func moveAuthor(_ offset: Int) {
        guard navigation.session?.moveAuthor(by: offset, viewedKeys: viewedKeys) == true,
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

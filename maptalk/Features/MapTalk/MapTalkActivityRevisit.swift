import SwiftUI

/// A notification owns one content snapshot, independently of the live feed.
struct MapTalkActivityRoute: Identifiable, Hashable {
    enum Content {
        case reel(RealPost)
        case place(RatedPOI)
        case bubble(JourneyPost)
    }

    let content: Content
    var commentID: UUID? = nil

    var contentID: UUID {
        switch content {
        case let .reel(reel): return reel.id
        case let .place(place): return place.id
        case let .bubble(bubble): return bubble.id
        }
    }

    var kind: String {
        switch content {
        case .reel: return "reel"
        case .place: return "place"
        case .bubble: return "bubble"
        }
    }

    var identifier: String { "maptalk.activity.detail.\(kind).\(contentID.uuidString)" }
    var id: String { identifier }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identifier == rhs.identifier && lhs.commentID == rhs.commentID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
        hasher.combine(commentID)
    }

    static func resolve(
        _ event: MapTalkActivityEvent,
        reals: [RealPost],
        places: [RatedPOI],
        journeyProvider: (UUID) -> JourneyPost?
    ) -> Self? {
        let content: Content
        switch event.target.destination {
        case let .reel(id):
            guard let reel = reals.first(where: { $0.id == id }) else { return nil }
            content = .reel(reel)
        case let .place(id):
            guard let place = places.first(where: { $0.id == id }) else { return nil }
            content = .place(place)
        case let .bubble(id):
            guard let bubble = journeyProvider(id) else { return nil }
            content = .bubble(bubble)
        }
        return Self(content: content, commentID: event.commentID)
    }

    func mode(userProvider: (UUID) -> User?) -> ExperienceDetailView.Mode {
        switch content {
        case let .reel(reel): return .real(reel, userProvider(reel.userId))
        case let .place(place): return .poi(place)
        case let .bubble(bubble): return .journey(bubble)
        }
    }
}

/// Keep Activity mounted underneath the same native sheet used by map cards.
/// Only the initial detent and dismissal destination differ from map browsing.
struct MapTalkActivityFlow: View {
    let events: [MapTalkActivityEvent]
    let reals: [RealPost]
    let places: [RatedPOI]
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool
    let onVisible: () -> Void

    @State private var selectedRoute: MapTalkActivityRoute?
    @State private var showsUnavailablePost = false

    var body: some View {
        MapTalkActivityView(events: events, onVisible: onVisible) { event in
            guard let route = MapTalkActivityRoute.resolve(
                event, reals: reals, places: places, journeyProvider: journeyProvider
            ) else {
                showsUnavailablePost = true
                return
            }
            selectedRoute = route
        }
        .sheet(item: $selectedRoute) { route in
            MapTalkActivityCapsule(
                route: route,
                journeyProvider: journeyProvider,
                userProvider: userProvider,
                onPOIContributorViewed: onPOIContributorViewed,
                isPOIContributorUnseen: isPOIContributorUnseen
            )
            // Passing .large as both detents leaves one native expanded stop.
            // Pulling down dismisses to Activity, never to a compact feed card.
            .mapExperienceSheetChrome(compactDetent: .large, selection: .constant(.large))
            .presentationBackgroundInteraction(.disabled)
            .presentationDragIndicator(.visible)
        }
        .alert("This post is no longer available", isPresented: $showsUnavailablePost) {
            Button("OK", role: .cancel) { }
        }
    }
}

/// Presentation controls only; all post, media and capsule rendering is shared.
private struct MapTalkActivityCapsule: View {
    let route: MapTalkActivityRoute
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var scrolledCommentID: UUID?
    @State private var journeyStack: [JourneySelection] = []

    private struct JourneySelection {
        let scope: MapJourneyScope
        var selectedID: UUID?
    }

    var body: some View {
        Group {
            if let journey = journeyStack.last {
                journeyCapsule(journey)
            } else {
                postCapsule
            }
        }
        .environment(\.backendSafetyMenuTrailingInset, 60)
        .overlay(alignment: .topLeading) {
            if journeyStack.isEmpty == false {
                presentationButton(
                    symbol: "chevron.left",
                    label: "Back to post",
                    identifier: "maptalk.activity.capsule.back"
                ) {
                    journeyStack.removeLast()
                    if journeyStack.isEmpty { scrolledCommentID = nil }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            presentationButton(
                symbol: "xmark",
                label: "Back to Activity",
                identifier: "maptalk.activity.detail.close"
            ) { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(route.identifier)
    }

    private var postCapsule: some View {
        ScrollViewReader { scrollProxy in
            ExperienceDetailView(
                mode: route.mode(userProvider: userProvider),
                onJourneyAvatarStackTap: openJourney,
                journeyProvider: journeyProvider,
                userProvider: userProvider,
                onPOIContributorViewed: onPOIContributorViewed,
                isPOIContributorUnseen: isPOIContributorUnseen
            )
            .onPreferenceChange(ExperienceCommentAnchorPreferenceKey.self) { ids in
                guard let commentID = route.commentID,
                      scrolledCommentID != commentID,
                      ids.contains(commentID) else { return }
                scrolledCommentID = commentID
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(commentID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func journeyCapsule(_ journey: JourneySelection) -> some View {
        if let selectedID = journey.selectedID {
            MapExperienceCapsule(
                pager: .init(items: journey.scope.sequenceItems),
                selection: Binding(
                    get: { journeyStack.last?.selectedID ?? selectedID },
                    set: { id in
                        guard journeyStack.isEmpty == false else { return }
                        journeyStack[journeyStack.count - 1].selectedID = id
                    }
                ),
                isExpanded: true,
                journeyProvider: journeyProvider,
                userProvider: userProvider,
                onJourneyAvatarStackTap: openJourney,
                onPOIContributorViewed: onPOIContributorViewed,
                isPOIContributorUnseen: isPOIContributorUnseen
            )
            .id(journey.scope.journey.id)
        } else {
            MapJourneyEmptyCapsule()
        }
    }

    private func openJourney(_ journey: JourneyPost) {
        if let index = journeyStack.firstIndex(where: { $0.scope.journey.id == journey.id }) {
            journeyStack = Array(journeyStack.prefix(index + 1))
            return
        }
        let scope = MapJourneyScope(journey: journey, userProvider: userProvider)
        journeyStack.append(.init(scope: scope, selectedID: scope.firstStoryItem?.id))
    }

    private func presentationButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.45), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

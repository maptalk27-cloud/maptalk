import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

enum ProfileMapBrowsingMode {
    case posts
    case allMemories
}

struct MapTalkView: View {
    @StateObject private var viewModel: MapTalkViewModel
    @Environment(\.appEnv) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("maptalk.map-layer") private var mapLayer: MapTalkMapLayer = .standard
    @AppStorage(MapTalkMapAppearance.storageKey) private var mapAppearance: MapTalkMapAppearance = .system
    private var mapColorScheme: ColorScheme { mapAppearance.resolved(using: colorScheme) }
    private var usesLightMapChrome: Bool { mapLayer == .satellite || mapColorScheme == .dark }
    @StateObject private var flightController = MapFlightController()
    @StateObject private var cameraPositionStore = MapCameraPositionStore()
    private var cameraPosition: MapCameraPosition {
        get { cameraPositionStore.position }
        nonmutating set { cameraPositionStore.setCommand(newValue) }
    }
    @State private var selectedRealId: UUID?
    @State private var selectedStoryId: UUID?
    @State private var poiOverviewID: UUID?
    @State private var selectedFriendFootprintID: String?
    @State private var activeExperience: ActiveExperience?
    @State private var profilePlacePreview: ProfilePlacePreview?
    @StateObject private var cardPresentation = MapTalkCardPresentation(
        poiCompactFraction: ControlsLayout.previewFraction,
        postCompactFraction: ControlsLayout.postPreviewFraction
    )
    @StateObject private var profileCardMotion = ProfileCardSheetMotion()
    private var experiencePresentation: MapExperiencePresentation { cardPresentation.current }
    @State private var currentRegion: MKCoordinateRegion?
    @State private var currentCamera: MapCamera?
    @State private var settledFriendFootprintRegion: MKCoordinateRegion?
    @State private var friendFootprintLayoutRegion: MKCoordinateRegion?
    @State private var friendFootprintVisibility: FriendFootprintScreenVisibility?
    @StateObject private var friendFootprintLayoutScheduler = FriendFootprintLayoutScheduler()
    @State private var mapControlsFrame: CGRect = .zero
    @StateObject private var friendFootprintInteractionGate =
        FriendFootprintMapInteractionGate()
    @State private var pendingRegionCause: RegionChangeCause = .initial
    @State private var reelAlignTrigger: Int = 0
    @State private var controlsBottomPadding: CGFloat = 0
    @State private var focusedJourneyHeader: JourneyPost?
    @State private var journeyEntry: JourneyEntry?
    @State private var journeyStack: [JourneyPost] = []
    @State private var suppressJourneySelectionUpdate: Bool = false
    @State private var didApplyInitialStorySelection: Bool = false
    @StateObject private var storyReadStore = StoryReadStore()
    @StateObject private var friendStoryNavigation = FriendStoryNavigation()
    @State private var pendingViewedStoryKey: String?
    @State private var publishDestination: MapTalkPublishDestination?
    @State private var queuedPublishDestination: MapTalkPublishDestination?
    @State private var publishAcknowledgement: String?
    @State private var publishAcknowledgementID = UUID()
    @State private var isActivityPresented = false
    @State private var isActivityOverExperiencePresented = false
    @State private var viewedActivityIDs = Set<String>()
    @State private var isBrowsingPostPreview = false
    @State private var postPreviewResumePageID: String?
    @State private var postEntryPosition: CGPoint?
    @State private var previewStoryResumePageIDs: [UUID: String] = [:]
    @Namespace private var heroNamespace
    @Namespace private var cardEntryTransitionNamespace
    @State private var poiTransitionSourceID: MapTalkPOITransitionID?
    private let initialStoryId: UUID?
    private let isTabActive: Bool
    private let profileBrowsingMode: ProfileMapBrowsingMode

    private var mapWorkEnabled: Bool { isTabActive && scenePhase == .active }

    init(viewModel: @autoclosure @escaping () -> MapTalkViewModel,
         initialStoryId: UUID? = nil, isTabActive: Bool = true,
         profileBrowsingMode: ProfileMapBrowsingMode = .posts) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.initialStoryId = initialStoryId
        self.isTabActive = isTabActive
        self.profileBrowsingMode = profileBrowsingMode
    }

    var body: some View {
        GeometryReader { geometry in
            let journeyNamespace = focusedJourneyHeader != nil ? heroNamespace : nil
            let journeyStoryItems: (JourneyPost) -> [RealStoriesRow.StoryItem] = { journey in
                MapJourneyScope(
                    journey: journey,
                    userProvider: viewModel.user(for:)
                )
                .storyItems
            }

            // The rail is a stable public feed snapshot. Map search results
            // live in `ratedPOIs` and never decide membership here.
            let allProfileStoryItems = viewModel.activeFeedItems
            let baseStoryItems = rootStoryItems
            let allFriendGroups = usesFriendStories ? friendStoryGroups : []
            let friendGroups = showsSocialFeedPreview
                ? previewGroups(allFriendGroups, posts: false) : allFriendGroups
            let postGroups = showsSocialFeedPreview ? postFeedGroups : []
            let previewPage = postPreviewPage(in: postGroups)
            let previewPost: RealPost? = {
                guard let page = previewPage, case let .reel(post) = page.content else { return nil }
                return post
            }()
            let postSurfaceMounted = cardPresentation.mountedFlow == .posts
            let postSurfaceReturning = cardPresentation.closingContent?.flow == .posts
            let hasPostPreviewEntry = showsSocialFeedPreview && (postSurfaceMounted
                || previewPage != nil || viewModel.postFeedIssue != nil || viewModel.isLoadingPosts)
            let showsPostPreviewEntry = hasPostPreviewEntry && mapWorkEnabled
                && (!postSurfaceMounted || postSurfaceReturning)
                && (!experiencePresentation.isExpanded || postSurfaceReturning)
                && !experiencePresentation.isResettingPresentation && focusedJourneyHeader == nil
                && publishDestination == nil && !isActivityPresented
                && !isActivityOverExperiencePresented

            let focusedStoryItems = focusedJourneyHeader.map(journeyStoryItems) ?? []
            let nestedStoryJourney: JourneyPost? = {
                guard case let .bubble(scope)? = friendStoryNavigation.routes.last?.content else { return nil }
                return scope.journey
            }()
            let renderedJourney = focusedJourneyHeader ?? nestedStoryJourney

            let storyItems = focusedJourneyHeader == nil ? baseStoryItems : focusedStoryItems
            let mapRatedPOIs = viewModel.mapRenderPOIs(
                retaining: selectedStoryId,
                selectedMapPOI: selectedStandalonePOI
            )
            // Home Posts have their own feed entry, not a second set of map
            // markers. Profile maps and an explicitly opened Bubble keep theirs.
            let mapReels = viewModel.isUserScope ? viewModel.mapRenderReels(
                retaining: selectedStoryId,
                selectedMapReel: selectedStandaloneReel
            ) : []
            let friendFootprintTopExclusion = MapTalkTopChromeLayout.height(
                safeAreaTop: geometry.safeAreaInsets.top,
                showsStories: usesFriendStories && focusedJourneyHeader == nil
                    ? !friendGroups.isEmpty : !storyItems.isEmpty
            )
            let friendFootprintLayoutRevision = viewModel.friendFootprints.map { footprint in
                MapMarkerLayoutRevision(
                    id: footprint.id,
                    latitude: footprint.coordinate.latitude,
                    longitude: footprint.coordinate.longitude,
                    weight: footprint.friendIDs.count
                )
            }
            let currentLocationLayoutRevision = viewModel.userCoordinate.map { coordinate in
                [
                    MapMarkerLayoutRevision(
                        id: "current-location",
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        weight: 0
                    )
                ]
            } ?? []
            let primaryMarkerLayoutRevision = mapReels.map { real in
                MapMarkerLayoutRevision(
                    id: "reel-\(real.id)",
                    latitude: real.center.latitude,
                    longitude: real.center.longitude,
                    weight: 0
                )
            } + mapRatedPOIs.map { rated in
                MapMarkerLayoutRevision(
                    id: "poi-\(rated.id)",
                    latitude: rated.poi.coordinate.latitude,
                    longitude: rated.poi.coordinate.longitude,
                    weight: 0
                )
            } + currentLocationLayoutRevision

            let activityEvents = MapTalkActivityFeed.events(
                reals: viewModel.activityReels,
                ratedPOIs: viewModel.activityPOIs,
                bubbles: environment.myMapArchive.publicBubbleCatalog
                    + environment.myMapArchive.legacyJourneyCatalog,
                currentUserID: environment.myMapArchive.currentUserID,
                userProvider: viewModel.user(for:)
            )
            let unreadActivityCount = activityEvents.reduce(into: 0) { count, event in
                if viewedActivityIDs.contains(event.id) == false {
                    count += 1
                }
            }

            let storyItemIds = storyItems.map(\.id)
            // Map/profile selection still uses this pager. Home story swipes
            // must not merge every place's history for an unused legacy pager.
            let makeSequenceItems = {
                storyItems.map { item -> ExperienceDetailView.SequencePager.Item in
                    switch item.source {
                    case let .real(real):
                        return ExperienceDetailView.SequencePager.Item(
                            id: real.id,
                            mode: .real(real, viewModel.user(for: real.userId))
                        )
                    case let .poi(group):
                        return ExperienceDetailView.SequencePager.Item(
                            id: group.id,
                            mode: .poi(focusedJourneyHeader == nil
                                ? viewModel.publicPlaceDetails(id: group.id) ?? group.ratedPOI
                                : group.ratedPOI)
                        )
                    case let .journey(journey):
                        return ExperienceDetailView.SequencePager.Item(
                            id: journey.id,
                            mode: .journey(journey)
                        )
                    }
                }
            }
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            // Both floating controls use the same card edge and breathing
            // room. Neither should reserve the tab bar's height twice.
            let previewControlsPadding: CGFloat = {
                let accessoryHeight = friendStoryNavigation.isActive
                    && (!isBrowsingPostPreview || friendStoryNavigation.isBrowsingBubble)
                    ? FriendStoryLayout.floatingHeight : 0
                guard showsSocialFeedPreview else {
                    return ControlsLayout.previewPadding(for: geometry,
                        fraction: activePreviewFraction) + accessoryHeight
                }
                // Both root systems share one dock. No native-frame feedback,
                // estimated→measured corrections, or chasing the resizing card.
                let headerFraction = FriendStoryLayout.floatingHeight / max(1, geometry.size.height)
                let fraction = friendStoryNavigation.isBrowsingBubble
                    ? ControlsLayout.postPreviewFraction + headerFraction
                    : max(ControlsLayout.postPreviewFraction,
                          ControlsLayout.previewFraction + headerFraction)
                return max(baseControlsPadding,
                    ControlsLayout.previewPadding(for: geometry, fraction: fraction)
                    - geometry.safeAreaInsets.bottom * (1 - fraction) + 12)
            }()
            let collapseDetent = {
                experiencePresentation.collapseToCompact()
            }
            let storyItemForReal: (RealPost) -> RealStoriesRow.StoryItem? = { real in
                storyItems.first { item in
                    if case let .real(candidate) = item.source {
                        return candidate.id == real.id
                    }
                    return false
                }
            }
            let storyItemForPOI: (RatedPOI) -> RealStoriesRow.StoryItem? = { rated in
                storyItems.first { item in
                    if case let .poi(group) = item.source {
                        return group.ratedPOI.id == rated.id
                    }
                    return false
                }
            }
            let storyItemForId: (UUID) -> RealStoriesRow.StoryItem? = { id in
                if let match = storyItems.first(where: { $0.id == id }) {
                    return match
                }
                return nil
            }
            let isStoryUnseen: (RealStoriesRow.StoryItem) -> Bool = { item in
                if case let .poi(group) = item.source {
                    return group.unreadCandidateKeys.contains { storyReadStore.isViewed($0) == false }
                }
                return item.isFresh && storyReadStore.isViewed(item.readKey) == false
            }
            let markStoryReadKeyViewed: (String) -> Void = { key in
                withAnimation(.easeOut(duration: 0.14)) {
                    storyReadStore.markViewed(key)
                }
            }
            let markStoryReadKeysViewed: ([String]) -> Void = { keys in
                withAnimation(.easeOut(duration: 0.14)) {
                    storyReadStore.markViewed(keys)
                }
            }
            let isPOIContributorUnseen: ([String]) -> Bool = { keys in
                keys.contains { storyReadStore.isViewed($0) == false }
            }
            let activityContent = MapTalkActivityFlow(
                events: activityEvents,
                reals: viewModel.activityReels,
                places: viewModel.activityPOIs,
                journeyProvider: viewModel.journey(for:),
                userProvider: viewModel.user(for:),
                onPOIContributorViewed: markStoryReadKeysViewed,
                isPOIContributorUnseen: isPOIContributorUnseen
            ) {
                viewedActivityIDs.formUnion(activityEvents.map(\.id))
            }
            let flushPendingViewedStory: (String?) -> Void = { excludingKey in
                guard let pendingKey = pendingViewedStoryKey,
                      pendingKey != excludingKey else {
                    return
                }
                pendingViewedStoryKey = nil
                markStoryReadKeyViewed(pendingKey)
            }
            let isRealUnseen: (RealPost) -> Bool = { real in
                guard let item = storyItemForReal(real) else { return false }
                return isStoryUnseen(item)
            }
            let isPOIUnseen: (RatedPOI) -> Bool = { rated in
                guard let item = storyItemForPOI(rated) else { return false }
                return isStoryUnseen(item)
            }

            let presentSequenceIfNeeded: (Bool) -> Void = { shouldPresent in
                guard storyItems.isEmpty == false else { return }
                let wasActive = experiencePresentation.isPresented
                guard shouldPresent || wasActive else { return }
                let nonce = (shouldPresent || activeExperience?.sequenceNonce == nil)
                    ? UUID()
                    : (activeExperience?.sequenceNonce ?? UUID())
                activeExperience = .sequence(nonce: nonce)
                configureProfileCardHeight()
                if shouldPresent {
                    experiencePresentation.presentNewContent()
                }
            }

            let selectStoryItem: (RealStoriesRow.StoryItem, Bool, Bool, RegionChangeCause?) -> Void = { item, shouldPresent, shouldFocus, overrideCause in
                if isProfilePostBrowsing, focusedJourneyHeader == nil {
                    if case let .poi(group) = item.source {
                        flushPendingViewedStory(nil)
                        openProfilePlace(group.ratedPOI, focus: shouldFocus)
                        return
                    }
                    // An explicit Post selection replaces a temporary peek;
                    // its later dismissal must not restore an older Post.
                    profilePlacePreview = nil
                }
                viewModel.cancelPendingLocationFocus()
                poiOverviewID = nil
                flushPendingViewedStory(item.readKey)
                viewModel.retainActiveFeedItem(id: item.id)
                selectedFriendFootprintID = nil
                selectedStoryId = item.id
                if shouldPresent || experiencePresentation.isPresented {
                    if case .poi = item.source {
                        pendingViewedStoryKey = nil
                    } else {
                        pendingViewedStoryKey = item.isFresh ? item.readKey : nil
                    }
                }
                switch item.source {
                case let .real(real):
                    let previousSelection = selectedRealId
                    selectedRealId = real.id
                    if let overrideCause {
                        pendingRegionCause = overrideCause
                    } else if previousSelection == real.id {
                        pendingRegionCause = .other
                    } else if previousSelection == nil && pendingRegionCause == .initial {
                        pendingRegionCause = .initial
                    } else {
                        pendingRegionCause = .real
                    }
                    if shouldFocus {
                        viewModel.focus(on: real)
                    }
                case let .poi(group):
                    if let overrideCause {
                        pendingRegionCause = overrideCause
                    } else if pendingRegionCause == .initial {
                        pendingRegionCause = .initial
                    } else {
                        pendingRegionCause = .poi
                    }
                    selectedRealId = nil
                    if shouldFocus {
                        viewModel.focus(on: group.ratedPOI)
                    }
                case let .journey(journey):
                    if let overrideCause {
                        pendingRegionCause = overrideCause
                    } else if pendingRegionCause == .initial {
                        pendingRegionCause = .initial
                    } else {
                        pendingRegionCause = .journey
                    }
                    selectedRealId = nil
                    if shouldFocus {
                        viewModel.focus(on: journey)
                    }
                }
                presentSequenceIfNeeded(shouldPresent)
            }

            let handleJourneyTap: (JourneyPost, Bool, JourneyPost?) -> Void = { journey, presentSheet, parent in
                profilePlacePreview = nil
                viewModel.cancelPendingLocationFocus()
                poiOverviewID = nil
                selectedFriendFootprintID = nil
                let isTappingCurrentFocusedJourney = (focusedJourneyHeader?.id == journey.id)
                if experiencePresentation.isPresented,
                   experiencePresentation.isExpanded,
                   isTappingCurrentFocusedJourney == false {
                    experiencePresentation.collapseToCompact()
                    if case .sequence = activeExperience {
                        activeExperience = .sequence(nonce: activeExperience?.sequenceNonce ?? UUID())
                    }
                }
                if focusedJourneyHeader == nil {
                    switch activeExperience {
                    case let .real(real, _):
                        journeyEntry = .reel(real)
                    case let .poi(rated, _):
                        journeyEntry = .poi(rated)
                    default:
                        if let identifier = selectedStoryId ?? selectedRealId {
                            journeyEntry = .feedItem(identifier)
                        } else {
                            journeyEntry = nil
                        }
                    }
                }
                if let parent, parent.id != journey.id {
                    journeyStack.append(parent)
                }
                focusedJourneyHeader = journey
                selectedStoryId = journeyStoryItems(journey).first?.id
                if presentSheet,
                   let firstItem = journeyStoryItems(journey).first {
                    flushPendingViewedStory(firstItem.readKey)
                    pendingViewedStoryKey = firstItem.isFresh ? firstItem.readKey : nil
                }
                suppressJourneySelectionUpdate = true
                reelAlignTrigger &+= 1
                if let target = journeyBoundingTarget(
                    for: journey,
                    size: geometry.size,
                    safeAreaBottom: geometry.safeAreaInsets.bottom
                ) {
                    pendingRegionCause = .journey
                    flightController.cancelActiveTransition()
                    withAnimation(.easeInOut(duration: 0.35)) {
                        cameraPosition = .camera(
                            MapCamera(
                                centerCoordinate: target.region.center,
                                distance: target.distance,
                                heading: 0,
                                pitch: 0
                            )
                        )
                    }
                    currentRegion = target.region
                } else {
                    viewModel.focus(on: journey)
                }
                if presentSheet {
                    if isTappingCurrentFocusedJourney,
                       experiencePresentation.isPresented,
                       experiencePresentation.isExpanded {
                        // Already on this journey in large sheet: refresh data but keep detent.
                        activeExperience = .sequence(nonce: activeExperience?.sequenceNonce ?? UUID())
                    } else {
                        activeExperience = .sequence(nonce: UUID())
                        configureProfileCardHeight()
                        experiencePresentation.presentNewContent()
                    }
                }

            }

            let focusJourneyFromBreadcrumb: (JourneyPost) -> Void = { journey in
                if let index = journeyStack.firstIndex(where: { $0.id == journey.id }) {
                    journeyStack = Array(journeyStack.prefix(upTo: index))
                }
                handleJourneyTap(journey, true, nil)
            }

            let ensureSelectionIfNeeded: () -> Void = {
                if viewModel.isUserScope, case .poi = activeExperience { return }
                if storyItems.isEmpty {
                    selectedStoryId = nil
                    selectedRealId = nil
                    return
                }
                if let currentId = selectedStoryId,
                   let currentItem = storyItemForId(currentId) {
                    if case let .real(real) = currentItem.source {
                        selectedRealId = real.id
                    } else {
                        selectedRealId = nil
                    }
                } else {
                    selectedStoryId = nil
                    selectedRealId = nil
                }
            }

            let applyInitialStorySelectionIfNeeded: () -> Void = {
                guard didApplyInitialStorySelection == false,
                      let initialStoryId,
                      let item = storyItemForId(initialStoryId)
                        ?? (viewModel.isUserScope ? allProfileStoryItems.first { $0.id == initialStoryId } : nil) else {
                    return
                }
                didApplyInitialStorySelection = true
                selectStoryItem(item, true, true, .initial)
                reelAlignTrigger &+= 1
            }

            // A stable native surface contains replaceable content. Each flow
            // still owns its detent/callback revision, not the other's state.
            let experienceSheet: (MapTalkFeedPresentation, MapExperiencePresentation) -> AnyView = { flow, presentation in
                let revision = presentation.contentRevision
                let contentIdentity = MapTalkCardContentIdentity(flow: flow, revision: revision)
                let isCurrent: () -> Bool = {
                    cardPresentation.activeFlow == flow
                        && presentation.contentRevision == revision
                }
                let isExpanded = presentation.isExpanded
                let shouldAnimateSelection = isExpanded == false

                let content: AnyView = {
                    if friendStoryNavigation.isActive {
                        return AnyView(FriendStoryFlow(
                            navigation: friendStoryNavigation,
                            detent: Binding(get: { presentation.detent }, set: { presentation.detent = $0 }),
                            compactDetent: presentation.compactDetent,
                            viewedKeys: storyReadStore.viewedKeys,
                            userProvider: viewModel.user(for:),
                            journeyProvider: viewModel.journey(for:),
                            placeProvider: friendStoryPlace,
                            captureCamera: friendStoryMapSnapshot,
                            restoreCamera: restoreFriendStoryCamera,
                            focusPage: { page in
                                guard isCurrent() else { return }
                                focusFriendStoryPage(page, geometry: geometry)
                            },
                            focusContent: { mode in
                                guard isCurrent() else { return }
                                focusFriendStoryContent(mode, geometry: geometry)
                            },
                            onRead: { storyReadStore.markViewed($0) },
                            onClose: {
                                guard isCurrent() else { return }
                                // Keep the current card mounted until native
                                // dismissal completes, then restore the map.
                                cardPresentation.dismiss(preservingDetent: true)
                            },
                            allowsPlayback: mapWorkEnabled && isCurrent() && !isActivityOverExperiencePresented,
                            feedPresentation: flow,
                            showsBubbleProgress: !viewModel.isUserScope,
                            hasMorePosts: viewModel.hasMorePosts,
                            isLoadingPosts: viewModel.isLoadingPosts,
                            postFeedIssue: viewModel.postFeedIssue,
                            onRetryPosts: viewModel.loadMorePosts
                        ))
                    }
                    switch activeExperience {
                    case let .sequence(nonce):
                        let sequenceItems = makeSequenceItems()
                        if sequenceItems.isEmpty == false {
                            let pager = ExperienceDetailView.SequencePager(items: sequenceItems)
                            let selectionBinding: Binding<UUID>
                            if focusedJourneyHeader != nil {
                            selectionBinding = Binding<UUID>(
                                get: {
                                    if let current = selectedStoryId,
                                       sequenceItems.contains(where: { $0.id == current }) {
                                        return current
                                    }
                                    return sequenceItems.first!.id
                                },
                                set: { newValue in
                                    guard isCurrent() else { return }
                                    if suppressJourneySelectionUpdate {
                                        suppressJourneySelectionUpdate = false
                                        return
                                    }
                                    guard newValue != selectedStoryId else { return }
                                    selectedStoryId = newValue
                                    if let item = storyItemForId(newValue) {
                                        selectStoryItem(item, false, true, nil)
                                    }
                                    reelAlignTrigger += 1
                                }
                            )
                        } else {
                                selectionBinding = Binding<UUID>(
                                    get: {
                                        if let current = selectedStoryId,
                                           sequenceItems.contains(where: { $0.id == current }) {
                                            return current
                                        }
                                        return sequenceItems.first!.id
                                    },
                                    set: { newValue in
                                        guard isCurrent() else { return }
                                        guard newValue != selectedStoryId else { return }
                                        guard let item = storyItemForId(newValue) else { return }
                                        if shouldAnimateSelection {
                                            selectStoryItem(item, false, true, nil)
                                        } else {
                                            selectStoryItem(item, false, false, .other)
                                            if let region = region(for: item) {
                                                currentRegion = region
                                                cameraPosition = .region(region)
                                            }
                                        }
                                        reelAlignTrigger += 1
                                    }
                                )
                            }

                            return AnyView(
                                MapExperienceCapsule(
                                    pager: pager,
                                    selection: selectionBinding,
                                    isExpanded: isExpanded,
                                    usesClassicPostPreview: viewModel.isUserScope,
                                    poiBrowsingUserID: viewModel.scopedUser?.id,
                                    poiOverviewID: poiOverviewID,
                                    onCollapsedTap: presentation.expand,
                                    journeyProvider: viewModel.journey(for:),
                                    userProvider: viewModel.user(for:),
                                    onJourneyAvatarStackTap: { journey in
                                        handleJourneyTap(journey, true, focusedJourneyHeader)
                                    },
                                    onPOIContributorViewed: markStoryReadKeysViewed,
                                    isPOIContributorUnseen: isPOIContributorUnseen
                                )
                                .id(nonce)
                            )
                        } else {
                            return AnyView(EmptyView())
                        }
                    case let .poi(rated: rated, nonce: nonce):
                        return AnyView(
                            ExperienceDetailView(
                                ratedPOI: rated,
                                isExpanded: isExpanded,
                                onCollapsedTap: presentation.expand,
                                userProvider: viewModel.user(for:),
                                onPOIContributorViewed: markStoryReadKeysViewed,
                                isPOIContributorUnseen: isPOIContributorUnseen
                            )
                            .id("\(rated.id)-\(nonce)")
                        )
                    case let .real(real: real, nonce: nonce):
                        let pager = ExperienceDetailView.SequencePager(
                            items: [
                                .init(
                                    id: real.id,
                                    mode: .real(real, viewModel.user(for: real.userId))
                                )
                            ]
                        )
                        return AnyView(
                            ExperienceDetailView(
                                sequencePager: pager,
                                selection: .constant(real.id),
                                isExpanded: isExpanded,
                                usesClassicPostPreview: viewModel.isUserScope,
                                onCollapsedTap: presentation.expand,
                                onJourneyAvatarStackTap: { journey in
                                    handleJourneyTap(journey, true, focusedJourneyHeader)
                                },
                                journeyProvider: viewModel.journey(for:),
                                userProvider: viewModel.user(for:)
                            )
                            .id("\(real.id)-\(nonce)")
                        )
                    case let .friendPlace(rated: rated, sourceID: sourceID, nonce: nonce):
                        return AnyView(
                            ExperienceDetailView(
                                ratedPOI: rated,
                                isExpanded: isExpanded,
                                onCollapsedTap: presentation.expand,
                                userProvider: viewModel.user(for:),
                                onPOIContributorViewed: markStoryReadKeysViewed,
                                isPOIContributorUnseen: isPOIContributorUnseen
                            )
                            .accessibilityIdentifier("maptalk.friend-place-preview")
                            .id("\(sourceID)-\(nonce)")
                        )
                    default:
                        return AnyView(EmptyView())
                    }
                }()

                return AnyView(content
                    .id(contentIdentity)
                    .environment(\.canControlCardMotion, isCurrent)
                    .environment(\.friendStoryPlaybackEnabled, mapWorkEnabled)
                    .environment(\.backendSafetyMenuTrailingInset, profilePlacePreview == nil ? 16 : 66)
                    .modifier(MapTalkScopedSheetChrome(isProfile: viewModel.isUserScope,
                                                     profileMotion: profileCardMotion,
                                                     homeMotion: cardPresentation.motion,
                                                     presentation: presentation,
                                                     navigation: friendStoryNavigation,
                                                     feedPresentation: flow))
                    .modifier(ProfileMapCardBackground(isEnabled: viewModel.isUserScope,
                                                       isPost: profileShowsPostCard))
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isUserScope, profilePlacePreview != nil {
                            Button {
                                if !restoreProfilePostAfterPlace() {
                                    cardPresentation.dismiss(preservingDetent: true)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 30, height: 30)
                                    .background(.regularMaterial, in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                            .accessibilityLabel(profilePlacePreview?.returnPostID == nil
                                ? "Back to map" : "Back to post")
                            .accessibilityIdentifier("profile.place.close")
                        }
                    }
                    .fullScreenCover(isPresented: $isActivityOverExperiencePresented) {
                        activityContent
                            .presentationBackground(Color(.systemBackground))
                    })
            }

            let finishExperienceSheet: (MapTalkFeedPresentation) -> Void = { flow in
                guard cardPresentation.didDismiss(flow) == false else { return }
                if viewModel.isUserScope {
                    if restoreProfilePostAfterPlace() { return }
                    activeExperience = nil
                    poiOverviewID = nil
                }
                // Closing a feed leaves the map at the last browsed location.
                // Only returning from a nested detail restores its parent camera.
                if friendStoryNavigation.isActive { finishFriendStory(restoreMap: false) }
                flushPendingViewedStory(nil)
                selectedRealId = nil
                selectedStoryId = focusedJourneyHeader != nil ? storyItems.first?.id : nil
                selectedFriendFootprintID = nil
                viewModel.releaseRetainedActiveFeedItem()

                if flow == .personStory { poiTransitionSourceID = nil }
                presentQueuedPublisherIfNeeded()
            }

            ZStack(alignment: .top) {
                MapReader { mapProxy in
                    let selectFriendFootprint: (MapTalkFriendFootprint) -> Void = { tapped in
                        cardPresentation.perform(in: .personStory) {
                            poiTransitionSourceID = .footprint(tapped.id)
                            finishFriendStory(restoreMap: false)
                            viewModel.cancelPendingLocationFocus()
                            let nextID = FriendFootprintTapSelectionPolicy.nextID(
                                tappedID: tapped.id,
                                selectedID: selectedFriendFootprintID,
                                visibleFootprints: viewModel.friendFootprints
                            )
                            let footprint = viewModel.friendFootprints.first {
                                $0.id == nextID
                            } ?? tapped

                            flushPendingViewedStory(nil)
                            viewModel.releaseRetainedActiveFeedItem()
                            selectedRealId = nil
                            selectedStoryId = nil
                            let feedback = UISelectionFeedbackGenerator()
                            feedback.prepare()
                            feedback.selectionChanged()
                            withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                                selectedFriendFootprintID = footprint.id
                            }
                            keepFriendFootprintVisible(
                                footprint: footprint,
                                projectedPoint: mapProxy.convert(
                                    footprint.coordinate,
                                    to: .local
                                ),
                                using: mapProxy,
                                canvasSize: geometry.size,
                                topChromeBottom: friendFootprintTopExclusion
                            )
                            activeExperience = .friendPlace(
                                rated: footprint.ratedPOI,
                                sourceID: footprint.id,
                                nonce: UUID()
                            )
                            experiencePresentation.presentNewContent()
                        }
                    }

                    Map(position: Binding(get: { cameraPosition }, set: { position in
                        // A fresh native binding write identifies an actual
                        // map gesture. Reading positionedByUser later in camera
                        // callbacks can instead describe a much earlier pan.
                        if position.positionedByUser {
                            flightController.cancelActiveTransition()
                        }
                        cameraPositionStore.observeNativePosition(position)
                    }), interactionModes: .all) {
                        if renderedJourney == nil,
                           viewModel.isUserScope == false,
                           let friendFootprintVisibility {
                            FriendFootprintOverlay(
                                footprints: viewModel.friendFootprints,
                                selectedID: selectedFriendFootprintID,
                                visibility: friendFootprintVisibility,
                                allowsCompactActivation: {
                                    friendFootprintInteractionGate.allowsCompactTap()
                                },
                                onTap: selectFriendFootprint,
                                poiTransitionNamespace: cardEntryTransitionNamespace
                            )
                        }

                        MapOverlays(
                            ratedPOIs: renderedJourney?.pois ?? mapRatedPOIs,
                            reals: renderedJourney?.reels ?? mapReels,
                            journeys: [],
                            userCoordinate: renderedJourney == nil ? viewModel.userCoordinate : nil,
                            heroNamespace: journeyNamespace,
                            useTimelineStyle: renderedJourney != nil,
                            displayMode: viewModel.isUserScope ? .content : .people,
                            selectedStoryId: friendStoryMapSelection ?? selectedStoryId,
                            userProvider: viewModel.user(for:),
                            isRealUnseen: isRealUnseen,
                            isPOIUnseen: isPOIUnseen,
                            onTapReal: { real in
                                cardPresentation.perform(in: .personStory) {
                                    if isProfilePostBrowsing, focusedJourneyHeader == nil {
                                        profilePlacePreview = nil
                                    }
                                    poiTransitionSourceID = .reel(real.id)
                                    finishFriendStory(restoreMap: false)
                                    viewModel.cancelPendingLocationFocus()
                                    if let item = storyItemForReal(real) {
                                        selectStoryItem(item, true, false, nil)
                                        reelAlignTrigger &+= 1
                                        return
                                    }

                                    flushPendingViewedStory(nil)
                                    viewModel.releaseRetainedActiveFeedItem()
                                    selectedFriendFootprintID = nil
                                    selectedRealId = real.id
                                    selectedStoryId = real.id
                                    activeExperience = .real(real: real, nonce: UUID())
                                    configureProfileCardHeight()
                                    experiencePresentation.presentNewContent()
                                }
                            },
                            onTapPOI: { rated in
                                cardPresentation.perform(in: .personStory) {
                                    if isProfilePostBrowsing, focusedJourneyHeader == nil {
                                        flushPendingViewedStory(nil)
                                        openProfilePlace(rated, focus: false)
                                        return
                                    }
                                    poiTransitionSourceID = .place(rated.id)
                                    finishFriendStory(restoreMap: false)
                                    viewModel.cancelPendingLocationFocus()
                                    if let item = storyItemForPOI(rated) {
                                        selectStoryItem(item, true, false, nil)
                                        // A map pin asks about the place, while the
                                        // profile rail and pager browse its owner's visits.
                                        if viewModel.isUserScope {
                                            poiOverviewID = rated.id
                                        }
                                        reelAlignTrigger &+= 1
                                        return
                                    }

                                    // The map keeps older public places visible even
                                    // after they leave the 24-hour story shelf. They
                                    // still open as places; they just do not join the
                                    // horizontal story sequence again.
                                    flushPendingViewedStory(nil)
                                    viewModel.releaseRetainedActiveFeedItem()
                                    pendingViewedStoryKey = nil
                                    selectedFriendFootprintID = nil
                                    selectedRealId = nil
                                    selectedStoryId = rated.id
                                    activeExperience = .poi(rated: rated, nonce: UUID())
                                    configureProfileCardHeight()
                                    experiencePresentation.presentNewContent()
                                }
                            },
                            showsSelectedReelRangeOnly: usesFriendStories && focusedJourneyHeader == nil,
                            poiTransitionNamespace: cardEntryTransitionNamespace
                        )
                    }
                    .mapStyle(mapLayer.mapStyle)
                    .environment(\.colorScheme, mapColorScheme)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("maptalk.map-canvas")
                    .accessibilityValue(currentCamera.map {
                        "\($0.centerCoordinate.latitude),\($0.centerCoordinate.longitude)"
                    } ?? "")
                    .onAppear {
                        refreshFriendFootprintVisibility(
                            using: mapProxy, canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: mapWorkEnabled) { active in
                        if active {
                            refreshFriendFootprintVisibility(
                                using: mapProxy, canvasSize: geometry.size,
                                topChromeBottom: friendFootprintTopExclusion,
                                region: currentRegion ?? viewModel.region
                            )
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        guard mapWorkEnabled else { return }
                        flightController.observeCamera(region: context.region, camera: context.camera)
                        friendFootprintInteractionGate.noteCameraMotion()
                        friendFootprintLayoutScheduler.noteCameraMotion(region: context.region)
                        if cameraPosition.positionedByUser {
                            viewModel.cancelPendingLocationFocus()
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        guard mapWorkEnabled else { return }
                        flightController.observeCamera(region: context.region, camera: context.camera)
                        flightController.observeCameraEnd()
                        friendFootprintLayoutScheduler.noteCameraMotion(region: context.region)
                        // A replaced flight can emit an old onEnd during the
                        // next flight. Do not rebuild around its temporary frame.
                        guard !flightController.isTransitionInProgress else { return }
                        friendFootprintInteractionGate.noteCameraMotion()
                        // Browsing still tracks the visible camera for normal map
                        // behavior. Publishing deliberately ignores this value
                        // and always uses the device's live location instead.
                        currentRegion = context.region
                        currentCamera = context.camera
                        viewModel.rememberVisibleRegion(context.region)
                        settledFriendFootprintRegion = context.region
                        if focusedJourneyHeader == nil {
                            viewModel.searchMap(in: context.region)
                        }
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: context.region
                        )
                    }
                    .onChangeCompat(of: friendFootprintTopExclusion) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: geometry.size) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: mapControlsFrame) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: friendFootprintLayoutRevision) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: selectedFriendFootprintID) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region
                        )
                    }
                    .onChangeCompat(of: primaryMarkerLayoutRevision) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region
                        )
                    }
                }

                VStack(spacing: MapTalkTopChromeLayout.storySpacing) {
                    if focusedJourneyHeader == nil {
                        ZStack {
                            Group {
                                if let scopedUser = viewModel.scopedUser {
                                    ProfileMapIdentityBadge(user: scopedUser)
                                        .environment(\.colorScheme, usesLightMapChrome ? .dark : .light)
                                } else {
                                    MapTalkHandwrittenBadge(usesLightInk: usesLightMapChrome)
                                }
                            }
                            .allowsHitTesting(false)

                            if viewModel.scopedUser == nil {
                                HStack {
                                    PostPublishButton(action: {
                                        requestPublish(.reel)
                                    }, usesLightInk: usesLightMapChrome)
                                    Spacer()
                                    MapTalkActivityButton(
                                        unreadCount: unreadActivityCount,
                                        usesDarkMaterial: usesLightMapChrome
                                    ) {
                                        requestActivity()
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: MapTalkTopChromeLayout.titleHeight)
                    }

                    if let journeyHeader = focusedJourneyHeader {
                        let journeyPath = journeyStack + [journeyHeader]
                        MapJourneyNavigationHeader(
                            path: journeyPath,
                            selectedJourneyId: journeyHeader.id,
                            onSelect: { journey in
                                focusJourneyFromBreadcrumb(journey)
                            },
                            onExit: {
                                exitJourneyFocus(
                                    size: geometry.size,
                                    safeAreaBottom: geometry.safeAreaInsets.bottom
                                )
                            }
                        )
                        .padding(.horizontal, 16)
                    }

                    if usesFriendStories && focusedJourneyHeader == nil {
                        if !friendGroups.isEmpty {
                            FriendStoriesRow(
                                groups: isBrowsingPostPreview ? friendGroups
                                    : friendStoryNavigation.session?.groups ?? friendGroups,
                                selectedAuthorID: isBrowsingPostPreview ? nil
                                    : friendStoryNavigation.session?.currentGroup?.authorID,
                                userProvider: viewModel.user(for:),
                                isUnseen: { group in group.poiReadKeys.contains { !storyReadStore.isViewed($0) } },
                                onSelect: { authorID in
                                    openFriendStory(authorID: authorID, groups: friendGroups, geometry: geometry)
                                },
                                usesLightLabels: usesLightMapChrome,
                                transitionNamespace: cardEntryTransitionNamespace
                            )
                        }
                    } else if storyItems.isEmpty == false {
                        RealStoriesRow(
                            items: storyItems,
                            selectedId: selectedStoryId,
                            onSelectReal: { real in
                                guard let item = storyItemForReal(real) else { return }
                                cardPresentation.perform(in: .personStory) {
                                    poiTransitionSourceID = .story(item.id)
                                    finishFriendStory(restoreMap: false)
                                    selectStoryItem(item, true, true, nil)
                                }
                            },
                            onSelectPOIGroup: { group in
#if DEBUG
                                let userHandle = group.primarySharers.first?.user?.handle ?? "unknown"
                                print("[MapTalkView] Row tap poi=\(group.poiName) id=\(group.ratedPOI.id) topSharer=\(userHandle) hasRecent=\(group.ratedPOI.hasRecentPhotoShare)")
#endif
                                if let item = storyItemForPOI(group.ratedPOI) {
                                    cardPresentation.perform(in: .personStory) {
                                        poiTransitionSourceID = .story(item.id)
                                        finishFriendStory(restoreMap: false)
                                        selectStoryItem(item, true, true, nil)
                                    }
                                }
                            },
                            onSelectJourney: { _ in },
                            userProvider: viewModel.user(for:),
                            alignTrigger: reelAlignTrigger,
                            displayMode: viewModel.isUserScope ? .content : .people,
                            usesPostMediaCollage: viewModel.isUserScope,
                            isUnseen: isStoryUnseen,
                            usesLightLabels: usesLightMapChrome,
                            transitionNamespace: cardEntryTransitionNamespace
                        )
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, geometry.safeAreaInsets.top + MapTalkTopChromeLayout.topPadding)
                .padding(.bottom, MapTalkTopChromeLayout.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .top)
                .background {
                    // Satellite imagery stays unobscured. Contrast belongs to
                    // the labels and local controls, not a map-wide white veil.
                    if mapLayer == .standard {
                        Rectangle()
                            .fill(.ultraThinMaterial.opacity(0.65))
                            .overlay(Color.white.opacity(0.06))
                            .mask {
                                LinearGradient(
                                    colors: [.white, .white, .white.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .allowsHitTesting(false)
                    }
                }
                .environment(\.colorScheme, mapColorScheme)
                .ignoresSafeArea(edges: .top)
                .opacity(publishDestination == nil && !(friendStoryNavigation.isActive && experiencePresentation.isExpanded && !isBrowsingPostPreview) ? 1 : 0)
                .allowsHitTesting(publishDestination == nil && !(friendStoryNavigation.isActive && experiencePresentation.isExpanded && !isBrowsingPostPreview))
                .animation(.easeOut(duration: 0.16), value: publishDestination)
                .animation(.easeOut(duration: 0.16), value: experiencePresentation.isExpanded)

                // Keep the draggable entry's state while the sheet is open.
                if hasPostPreviewEntry {
                    MapTalkPostCoverEntry(post: previewPost,
                        isResuming: postPreviewResumePageID != nil,
                        isActive: postSurfaceMounted,
                        isReturning: postSurfaceReturning,
                        needsCardClearance: cardPresentation.mountedFlow == .personStory
                            && cardPresentation.closingContent == nil,
                        canvasSize: geometry.size,
                        idleBottomInset: baseControlsPadding,
                        bottomInset: controlsBottomPadding,
                        position: $postEntryPosition,
                        excludedFrame: mapControlsFrame.isEmpty ? .null : mapControlsFrame.offsetBy(
                            dx: -geometry.frame(in: .global).minX,
                            dy: -geometry.frame(in: .global).minY),
                        topInset: friendFootprintTopExclusion) {
                            if let page = previewPage {
                                resumePostPreview(pageID: page.id, geometry: geometry)
                            } else {
                                viewModel.refreshPosts()
                            }
                    }
                    // Keep its placement/float state and zoom anchor alive when
                    // covered by an expanded POI, a publisher or another modal.
                    .opacity(showsPostPreviewEntry || postSurfaceMounted ? 1 : 0)
                    .allowsHitTesting(showsPostPreviewEntry)
                    .accessibilityHidden(!showsPostPreviewEntry)
                    .zIndex(1)
                }

                if focusedJourneyHeader == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MapTalkControls(
                                mapLayer: $mapLayer,
                                onTapLocate: {
                                    profilePlacePreview = nil
                                    // Keep the departing card's live content
                                    // intact until native dismissal completes.
                                    if !cardPresentation.isMounted {
                                        finishFriendStory(restoreMap: false)
                                        selectedRealId = nil
                                        selectedStoryId = nil
                                        activeExperience = nil
                                        flushPendingViewedStory(nil)
                                        viewModel.releaseRetainedActiveFeedItem()
                                    }
                                    flightController.cancelActiveTransition()
                                    if let region = currentRegion,
                                       let coordinate = viewModel.userCoordinate,
                                       region.center.distance(to: coordinate) < 500 {
                                        pendingRegionCause = .other
                                    } else {
                                        pendingRegionCause = .user
                                    }
                                    cardPresentation.dismiss()
                                    viewModel.centerOnUser()
                                },
                                onTapPlace: {
                                    requestPublish(.place)
                                },
                                showsPublishActions: viewModel.isUserScope == false,
                                usesPostPreviewLayout: showsSocialFeedPreview
                            )
                            .environment(\.colorScheme, mapColorScheme)
                            .onGeometryChange(for: CGRect.self) { controlsGeometry in
                                controlsGeometry.frame(in: .global)
                            } action: { frame in
                                mapControlsFrame = frame
                            }
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, controlsBottomPadding)
                        .opacity(publishDestination == nil ? 1 : 0)
                        .allowsHitTesting(publishDestination == nil)
                        .animation(.easeOut(duration: 0.16), value: publishDestination)
                    }
                }
            }
            .environment(\.mapTalkCardSources, viewModel.isUserScope ? nil : cardPresentation.sources)
            .modifier(MapTalkExperienceSheetHost(isProfile: viewModel.isUserScope,
                presentation: cardPresentation,
                compactFraction: activePreviewFraction,
                expandedTopInset: friendStoryNavigation.isActive
                    && ((cardPresentation.activeFlow == .personStory && friendStoryNavigation.routes.isEmpty)
                        || friendStoryNavigation.isBrowsingBubble)
                    ? FriendStoryLayout.floatingHeight : 0,
                selectedSource: cardPresentation.activeFlow == .posts
                    ? .posts : poiTransitionSourceID.map(MapTalkCardTransitionID.poi),
                usesPostBackdrop: cardPresentation.activeFlow == .posts
                    && friendStoryNavigation.routes.isEmpty,
                sheetContent: experienceSheet(cardPresentation.activeFlow, cardPresentation.current),
                onDismiss: { finishExperienceSheet(cardPresentation.activeFlow) }))
            .overlay(alignment: .top) {
                if let publishAcknowledgement {
                    Label(publishAcknowledgement, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.9), in: Capsule())
                        .padding(.top, 70)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("maptalk.publish.saved")
                }
            }
            .task(id: publishAcknowledgementID) {
                guard publishAcknowledgement != nil else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                publishAcknowledgement = nil
            }
            .sheet(item: $publishDestination) { destination in
                MapTalkPublishComposer(
                    destination: destination,
                    nearbyPlaces: viewModel.publishableLiveLocation.map {
                        viewModel.nearbyPlaceOptions(near: $0)
                    } ?? [],
                    isLoadingNearbyPlaces: viewModel.isLoadingNearbyPlaces,
                    nearbyPlaceIssue: viewModel.nearbyPlaceIssue,
                    postLocationChoices: viewModel.publishableLiveLocation.map {
                        viewModel.postLocationChoices(near: $0)
                    } ?? [],
                    liveLocationKey: viewModel.publishableLiveLocation.map {
                        String(format: "%.3f,%.3f", $0.coordinate.latitude, $0.coordinate.longitude)
                    } ?? "unavailable",
                    liveLocation: viewModel.publishableLiveLocation,
                    folders: environment.myMapArchive.journeyFolders,
                    myMapRecords: myMapBubbleRecords,
                    currentUserID: environment.myMapArchive.currentUserID,
                    userProvider: viewModel.user(for:),
                    hasLiveLocation: viewModel.publishableLiveLocation != nil,
                    locationAuthorization: viewModel.locationAuthorization,
                    onCancel: {
                        publishDestination = nil
                    },
                    onPublish: { draft, audience, requestID in
                        try await completePublishing(
                            draft,
                            audience: audience,
                            destination: destination,
                            requestID: requestID
                        )
                    },
                    onSearchNearbyPlaces: searchNearbyPlaces,
                    onRetryNearbyPlaces: { viewModel.refreshNearbyPlaces() },
                    onSearchPostLocations: viewModel.searchPostLocations
                )
                .presentationDetents([.fraction(0.84)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
                .presentationBackground(Color.white)
                .presentationCompactAdaptation(.sheet)
                .interactiveDismissDisabled()
            }
            .fullScreenCover(isPresented: $isActivityPresented) {
                activityContent
                    .presentationBackground(Color(.systemBackground))
            }
            .onChange(of: activityEvents.map(\.id)) { _, identifiers in
                guard isActivityPresented || isActivityOverExperiencePresented else { return }
                viewedActivityIDs.formUnion(identifiers)
            }
            .onAppear {
                updateMapActivity()
                storyReadStore.configure(
                    accountID: environment.currentUser.id,
                    server: environment.backend?.api.baseURL.absoluteString ?? "preview"
                )
                if currentRegion == nil {
                    let initialRegion = viewModel.region
                    cameraPosition = .region(initialRegion)
                    currentRegion = initialRegion
                    settledFriendFootprintRegion = initialRegion
                    pendingRegionCause = .initial
                }
                controlsBottomPadding = baseControlsPadding
                if mapWorkEnabled {
                    viewModel.onAppear()
                    ensureSelectionIfNeeded()
                    applyInitialStorySelectionIfNeeded()
                }
            }
            .onReceive(viewModel.$region.dropFirst()) { newRegion in
                guard mapWorkEnabled else { return }
                let cause = pendingRegionCause
                pendingRegionCause = .other
                if (cause == .initial || cause == .user),
                   (currentRegion?.span.latitudeDelta ?? 0) >= 90 {
                    // Startup should settle at the person's city, not preserve
                    // the temporary world zoom or fly from a demo city.
                    flightController.cancelActiveTransition()
                    cameraPosition = .region(newRegion)
                    currentRegion = newRegion
                    return
                }
                flightController.handleRegionChange(
                    currentRegion: currentRegion,
                    targetRegion: newRegion,
                    cause: cause,
                    cameraPosition: cameraPositionStore.commandBinding
                ) { updated in
                    currentRegion = updated
                }
            }
            .onChangeCompat(of: storyItemIds) { ids in
                guard !friendStoryNavigation.isActive else { return }
                // Feed membership belongs to the sequence pager. A standalone
                // map-search preview has its own selected snapshot and must not
                // lose that selection when the public feed refreshes or expires.
                switch activeExperience {
                case .real, .poi, .friendPlace:
                    return
                default:
                    break
                }

                if ids.isEmpty {
                    selectedRealId = nil
                    selectedStoryId = nil
                    if case .sequence = activeExperience {
                        activeExperience = nil
                        cardPresentation.dismiss()
                    }
                    flushPendingViewedStory(nil)
                    return
                }
                if let currentId = selectedStoryId {
                    if ids.contains(currentId) == false {
                        flushPendingViewedStory(nil)
                        selectedStoryId = nil
                        selectedRealId = nil
                    }
                } else {
                    flushPendingViewedStory(nil)
                    selectedStoryId = nil
                    selectedRealId = nil
                }
                applyInitialStorySelectionIfNeeded()
            }
            .onChangeCompat(of: allProfileStoryItems.map(\.id)) { _ in
                // A saved POI link may arrive without any Posts. Its source
                // still exists even though it is no longer in the Post pager.
                guard viewModel.isUserScope else { return }
                applyInitialStorySelectionIfNeeded()
            }
            .onChangeCompat(of: scenePhase) { phase in
                updateMapActivity()
                if phase == .active && isTabActive {
                    ensureSelectionIfNeeded()
                    applyInitialStorySelectionIfNeeded()
                    reconcileFriendStories(geometry: geometry)
                }
            }
            .onDisappear { friendFootprintLayoutScheduler.cancel() }
            .onChangeCompat(of: isTabActive) { active in
                updateMapActivity()
                if active && scenePhase == .active {
                    ensureSelectionIfNeeded()
                    applyInitialStorySelectionIfNeeded()
                    reconcileFriendStories(geometry: geometry)
                }
            }
            .onChange(of: friendStoryRevision(allFriendGroups)) { _, _ in
                guard mapWorkEnabled, !isBrowsingPostPreview else { return }
                reconcileFriendStories(geometry: geometry)
            }
            .onChange(of: friendStoryRevision(postGroups)) { _, _ in
                guard mapWorkEnabled, isBrowsingPostPreview else { return }
                reconcileFriendStories(geometry: geometry)
            }
            .onChange(of: environment.currentUser.id) { _, accountID in
                profilePlacePreview = nil
                if friendStoryNavigation.isActive {
                    finishFriendStory(restoreMap: false)
                    cardPresentation.dismiss()
                }
                postPreviewResumePageID = nil
                postEntryPosition = nil
                previewStoryResumePageIDs = [:]
                storyReadStore.configure(accountID: accountID,
                    server: environment.backend?.api.baseURL.absoluteString ?? "preview")
            }
            .onReceive(viewModel.$ratedPOIs) { places in
                updateStandalonePlacePreview(from: places)
            }
            .onReceive(viewModel.$friendFootprints) { footprints in
                updateStandalonePlacePreview(from: footprints.map(\.ratedPOI))
            }
            .onChangeCompat(of: viewModel.withdrawnPublicMemoryIDs) { ids in
                if friendStoryNavigation.isActive {
                    reconcileFriendStories(geometry: geometry)
                }
                if case let .reel(parent) = journeyEntry, ids.contains(parent.id) {
                    journeyEntry = nil
                    focusedJourneyHeader = nil
                    journeyStack = []
                    dismissWithdrawnPreview()
                    return
                }
                // A standalone preview is deliberately independent of feed
                // paging, but never independent of an actual withdrawal.
                switch activeExperience {
                case let .real(real, _):
                    guard ids.contains(real.id) else { return }
                case let .poi(rated, nonce):
                    guard rated.checkIns.contains(where: { ids.contains($0.id) }) else { return }
                    if let remaining = viewModel.removingWithdrawnVisits(from: rated) {
                        activeExperience = .poi(rated: remaining, nonce: nonce)
                        return
                    }
                case let .friendPlace(rated, sourceID, nonce):
                    guard rated.checkIns.contains(where: { ids.contains($0.id) }) else { return }
                    if let remaining = viewModel.removingWithdrawnVisits(from: rated) {
                        activeExperience = .friendPlace(rated: remaining, sourceID: sourceID, nonce: nonce)
                        return
                    }
                default:
                    return
                }
                dismissWithdrawnPreview()
            }
            .onChangeCompat(of: focusedJourneyHeader?.id) { identifier in
                if identifier != nil {
                    return
                }
                guard let entry = journeyEntry else { return }
                journeyEntry = nil

                switch entry {
                case let .feedItem(identifier):
                    if let item = storyItemForId(identifier) {
                        selectStoryItem(item, true, true, nil)
                    } else {
                        selectedStoryId = nil
                        selectedRealId = nil
                        activeExperience = nil
                        cardPresentation.dismiss()
                    }
                case let .reel(real):
                    guard !viewModel.withdrawnPublicMemoryIDs.contains(real.id) else {
                        dismissWithdrawnPreview()
                        return
                    }
                    selectedFriendFootprintID = nil
                    selectedStoryId = real.id
                    selectedRealId = real.id
                    pendingRegionCause = .real
                    viewModel.focus(on: real)
                    activeExperience = .real(real: real, nonce: UUID())
                    configureProfileCardHeight()
                    experiencePresentation.presentNewContent()
                case let .poi(rated):
                    guard let rated = viewModel.removingWithdrawnVisits(from: rated) else {
                        dismissWithdrawnPreview()
                        return
                    }
                    selectedFriendFootprintID = nil
                    selectedStoryId = rated.id
                    selectedRealId = nil
                    pendingRegionCause = .poi
                    viewModel.focus(on: rated)
                    activeExperience = .poi(rated: rated, nonce: UUID())
                    configureProfileCardHeight()
                    experiencePresentation.presentNewContent()
                }
            }
            .onChangeCompat(of: experiencePresentation.isPresented) { isActive in
                if isActive == false {
                    flushPendingViewedStory(nil)
                }
                let target = isActive ? previewControlsPadding : baseControlsPadding
                setControlsPaddingForPresentation(target)
            }
            .onChangeCompat(of: cardPresentation.closingContent != nil) { isClosing in
                // Move the dock with the start of a native return, not a
                // second time after its completion. A cancelled pull restores
                // clearance for the card that remains on screen.
                setControlsPaddingForPresentation(isClosing || !cardPresentation.isPresented
                    ? baseControlsPadding : previewControlsPadding)
            }
            .onChangeCompat(of: experiencePresentation.detent) { detent in
                if friendStoryNavigation.isActive,
                   detent == experiencePresentation.compactDetent,
                   let page = friendStoryNavigation.session?.currentPage,
                   friendStoryNavigation.routes.isEmpty {
                    focusFriendStoryPage(page, geometry: geometry)
                }
                if detent == experiencePresentation.compactDetent, experiencePresentation.isPresented {
                    setControlsPaddingForPresentation(previewControlsPadding)
                } else if experiencePresentation.isPresented == false {
                    setControlsPaddingForPresentation(baseControlsPadding)
                }
            }
            .onChangeCompat(of: geometry.size) { _ in
                controlsBottomPadding = experiencePresentation.isPresented
                    ? previewControlsPadding : baseControlsPadding
                if friendStoryNavigation.isActive, friendStoryNavigation.routes.isEmpty,
                   let page = friendStoryNavigation.session?.currentPage {
                    focusFriendStoryPage(page, geometry: geometry)
                }
            }
            .onChangeCompat(of: activePreviewFraction) { _ in
                configureProfileCardHeight()
            }
            .onChangeCompat(of: baseControlsPadding) { newValue in
                guard experiencePresentation.isPresented == false else { return }
                controlsBottomPadding = newValue
            }
            .onChangeCompat(of: previewControlsPadding) { newValue in
                guard experiencePresentation.isPresented,
                      cardPresentation.closingContent == nil else { return }
                setControlsPaddingForPresentation(newValue)
            }
            .onChangeCompat(of: viewModel.mode) { _ in
                collapseDetent()
            }
        }
    }
}

private extension MapTalkView {
    var isProfilePostBrowsing: Bool {
        viewModel.isUserScope && profileBrowsingMode == .posts
    }

    /// View Map explores all public memories; a Post row stays in Post history.
    /// The rail, pager and compact-card height resolve from the same scope.
    var rootStoryItems: [RealStoriesRow.StoryItem] {
        guard isProfilePostBrowsing else { return viewModel.activeFeedItems }
        return viewModel.activeFeedItems.filter {
            if case .real = $0.source { return true }
            return false
        }
    }

    var profileShowsPostCard: Bool {
        guard viewModel.isUserScope else { return false }
        switch activeExperience {
        case .real:
            return true
        case .sequence:
            let items = focusedJourneyHeader.map {
                MapJourneyScope(journey: $0, userProvider: viewModel.user(for:)).storyItems
            } ?? rootStoryItems
            guard let item = items.first(where: { $0.id == selectedStoryId }) ?? items.first else {
                return false
            }
            if case .real = item.source { return true }
            return false
        default:
            return false
        }
    }

    func configureProfileCardHeight() {
        guard viewModel.isUserScope else { return }
        // The stable paging stage owns in-flight height interpolation. The
        // navigation model only commits a compact height once a page lands.
        if !profileCardMotion.isPaging {
            profileCardMotion.setCompactFraction(activePreviewFraction,
                animated: cardPresentation.poi.isPresented)
        }
        cardPresentation.poi.configureCompactDetent(.fraction(activePreviewFraction))
    }

    var activePreviewFraction: CGFloat {
        if viewModel.isUserScope {
            return profileShowsPostCard ? ControlsLayout.postPreviewFraction : ControlsLayout.previewFraction
        }
        if let fraction = friendStoryNavigation.bubbleCompactFraction { return fraction }
        // Outside a Bubble, the two home feeds retain their independent sizes.
        return cardPresentation.activeFlow == .posts
            ? ControlsLayout.postPreviewFraction : ControlsLayout.previewFraction
    }

    func setControlsPaddingForPresentation(_ padding: CGFloat) {
        guard abs(controlsBottomPadding - padding) >= 1 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            controlsBottomPadding = padding
        }
    }

    func updateMapActivity() {
        viewModel.setMapActivity(mapWorkEnabled)
        guard !mapWorkEnabled else { return }
        friendFootprintLayoutScheduler.cancel()
        // Finish at the selected post while offscreen, without animating or
        // leaving a queued flight to fight the newly selected tab.
        let landing = flightController.pendingLandingRegion
        flightController.cancelActiveTransition()
        if let landing {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { cameraPosition = .region(landing) }
            currentRegion = landing
            settledFriendFootprintRegion = landing
            currentCamera = nil
            viewModel.rememberVisibleRegion(landing)
        }
    }

    var usesFriendStories: Bool {
        guard !viewModel.isUserScope else { return false }
#if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("--legacy-stories")
#else
        return true
#endif
    }

    var showsSocialFeedPreview: Bool {
        // The presentation works with the active environment's feed. Mock
        // data remains an explicit launch option, never a UI requirement.
        !viewModel.isUserScope
    }

    // Split the existing feed for presentation without changing membership
    // or publication visibility on the server.
    func previewGroups(_ groups: [FriendStoryGroup], posts: Bool) -> [FriendStoryGroup] {
        groups.compactMap { group in
            let pages = group.pages.filter { page in
                if case .reel = page.content { return posts }
                return !posts
            }
            guard !pages.isEmpty else { return nil }
            return FriendStoryGroup(authorID: group.authorID, user: group.user,
                pages: pages, viewedKeys: storyReadStore.viewedKeys)
        }
    }

    func postPreviewPage(in groups: [FriendStoryGroup]) -> FriendStoryPage? {
        MapTalkPostEntryPage.resolve(in: groups, resumePageID: postPreviewResumePageID)
    }

    @discardableResult
    func resumePostPreview(pageID: String, geometry: GeometryProxy) -> Bool {
        guard showsSocialFeedPreview, mapWorkEnabled,
              publishDestination == nil, queuedPublishDestination == nil,
              !isActivityPresented, !isActivityOverExperiencePresented else { return false }
        let groups = postFeedGroups
        guard let page = MapTalkPostEntryPage.resolve(in: groups, resumePageID: pageID) else {
            return false
        }
        // Fly from the visible map. The original return camera stays stored
        // in navigation; restoring it here would teleport before the flight.
        openFriendStory(authorID: page.authorID, groups: groups,
            geometry: geometry, postPreviewPageID: page.id)
        return true
    }

    func refreshPostPreview(groups: [FriendStoryGroup], geometry: GeometryProxy) {
        guard showsSocialFeedPreview,
              let page = MapTalkPostEntryPage.refreshTarget(in: groups,
                currentPageID: friendStoryNavigation.session?.currentPage?.id,
                viewedKeys: storyReadStore.viewedKeys) else { return }
        // A deliberate refresh adopts the latest mock feed snapshot, while
        // keeping the native card open and the POI/map browsing state separate.
        openFriendStory(authorID: page.authorID, groups: groups,
            geometry: geometry, postPreviewPageID: page.id)
    }

    func rememberPreviewCursor() {
        guard showsSocialFeedPreview, let session = friendStoryNavigation.session else { return }
        if isBrowsingPostPreview {
            postPreviewResumePageID = session.currentPage?.id ?? postPreviewResumePageID
        } else {
            previewStoryResumePageIDs.merge(session.resumePageIDs) { _, latest in latest }
        }
    }

    var friendStoryGroups: [FriendStoryGroup] {
        FriendStoryFeed.groups(
            reals: viewModel.activityReels,
            ratedPOIs: viewModel.activityPOIs,
            backendRecords: viewModel.friendStoryRecords,
            viewedKeys: storyReadStore.viewedKeys,
            userProvider: viewModel.user(for:)
        )
    }

    var postFeedGroups: [FriendStoryGroup] {
        FriendStoryFeed.postGroups(
            reals: viewModel.postFeedRecords == nil ? viewModel.activityReels : viewModel.postFeedReels,
            backendRecords: viewModel.postFeedRecords,
            viewedKeys: storyReadStore.viewedKeys,
            userProvider: viewModel.user(for:)
        )
    }

    /// Compare payload changes too: RealPost equality intentionally only compares
    /// identity, which otherwise hides progressive media and caption updates.
    func friendStoryRevision(_ groups: [FriendStoryGroup]) -> [String] {
        groups.flatMap { group in
            [group.id.uuidString, group.user?.handle ?? "", group.user?.avatarURL?.absoluteString ?? ""] + group.pages.map { page in
                var hash = Hasher()
                hash.combine(page.id)
                hash.combine(page.publishedAt)
                hash.combine(page.expiresAt)
                hash.combine(page.readKey)
                hash.combine(page.locationKey)
                hash.combine(page.coordinate?.latitude)
                hash.combine(page.coordinate?.longitude)
                hash.combine(page.expectedMedia)
                switch page.content {
                case let .reel(reel):
                    hash.combine(reel.message)
                    hash.combine(reel.attachments)
                    hash.combine(reel.capsuleId)
                case let .poi(place, checkIn, media):
                    hash.combine(place.id)
                    hash.combine(place.poi.name)
                    hash.combine(place.poi.category)
                    hash.combine(checkIn)
                    hash.combine(media)
                }
                return String(hash.finalize())
            }
        }
    }

    func friendStoryMapSnapshot() -> FriendStoryNavigation.MapSnapshot {
        if let landing = flightController.pendingLandingRegion {
            return .init(camera: nil, region: landing)
        }
        return .init(camera: currentCamera, region: currentRegion)
    }

    func restoreFriendStoryCamera(_ snapshot: FriendStoryNavigation.MapSnapshot) {
        flightController.cancelActiveTransition()
        pendingRegionCause = .other
        if let camera = snapshot.camera { cameraPosition = .camera(camera) }
        else if let region = snapshot.region { cameraPosition = .region(region) }
        currentRegion = snapshot.region
        currentCamera = snapshot.camera
    }

    /// Profile places are a temporary map detail, not another page in the
    /// author's Post history. Repeated pin taps keep the first return point.
    func openProfilePlace(_ rated: RatedPOI, focus: Bool) {
        guard isProfilePostBrowsing, focusedJourneyHeader == nil,
              let place = viewModel.publicPlaceDetails(id: rated.id, latestPublicPlace: rated) else { return }
        if profilePlacePreview == nil {
            let postID = experiencePresentation.isPresented && profileShowsPostCard
                ? selectedRealId : nil
            profilePlacePreview = ProfilePlacePreview(
                returnPostID: postID,
                returnWasExpanded: experiencePresentation.isExpanded,
                returnCamera: friendStoryMapSnapshot()
            )
        }
        viewModel.cancelPendingLocationFocus()
        flightController.cancelActiveTransition()
        poiTransitionSourceID = .place(place.id)
        poiOverviewID = place.id
        pendingViewedStoryKey = nil
        selectedFriendFootprintID = nil
        selectedRealId = nil
        selectedStoryId = place.id
        activeExperience = .poi(rated: place, nonce: UUID())
        profileCardMotion.isPaging = false
        configureProfileCardHeight()
        if focus {
            pendingRegionCause = .poi
            viewModel.focus(on: place)
        }
        experiencePresentation.presentNewContent()
    }

    /// Both the close button and native swipe dismissal return to the same
    /// still-public Post. Never resurrect an old selection from a closed card.
    @discardableResult
    func restoreProfilePostAfterPlace() -> Bool {
        guard let preview = profilePlacePreview else { return false }
        profilePlacePreview = nil
        guard isProfilePostBrowsing, focusedJourneyHeader == nil,
              let postID = preview.returnPostID,
              !viewModel.withdrawnPublicMemoryIDs.contains(postID),
              let post = viewModel.mapRenderReels(retaining: nil).first(where: { $0.id == postID }) else {
            return false
        }
        viewModel.cancelPendingLocationFocus()
        poiOverviewID = nil
        poiTransitionSourceID = nil
        selectedFriendFootprintID = nil
        selectedStoryId = postID
        selectedRealId = postID
        if let item = viewModel.activeFeedItems.first(where: { $0.id == postID }),
           case .real = item.source {
            viewModel.retainActiveFeedItem(id: postID)
            pendingViewedStoryKey = item.isFresh ? item.readKey : nil
            activeExperience = .sequence(nonce: UUID())
        } else {
            viewModel.releaseRetainedActiveFeedItem()
            pendingViewedStoryKey = nil
            activeExperience = .real(real: post, nonce: UUID())
        }
        profileCardMotion.isPaging = false
        configureProfileCardHeight()
        restoreFriendStoryCamera(preview.returnCamera)
        if preview.returnWasExpanded {
            experiencePresentation.presentExpandedContent()
        } else {
            experiencePresentation.presentNewContent()
        }
        reelAlignTrigger &+= 1
        return true
    }

    func openFriendStory(authorID: UUID, groups: [FriendStoryGroup], geometry: GeometryProxy,
                         postPreviewPageID: String? = nil) {
        let flow: MapTalkFeedPresentation = showsSocialFeedPreview && postPreviewPageID != nil
            ? .posts : .personStory
        cardPresentation.perform(in: flow) {
            guard mapWorkEnabled, publishDestination == nil, queuedPublishDestination == nil else { return }
            if flow == .personStory { poiTransitionSourceID = .author(authorID) }
            showFriendStory(authorID: authorID, groups: groups, geometry: geometry,
                            postPreviewPageID: postPreviewPageID)
        }
    }

    /// A root selection replaces content inside the existing card surface.
    func showFriendStory(authorID: UUID, groups: [FriendStoryGroup], geometry: GeometryProxy,
                         postPreviewPageID: String?) {
        rememberPreviewCursor()
        isBrowsingPostPreview = showsSocialFeedPreview && postPreviewPageID != nil
        viewModel.cancelPendingLocationFocus()
        pendingViewedStoryKey = nil
        // Choosing a new root isn't Back, even within the same feed. Fly
        // directly from the visible child; don't restore its parent first.
        if !friendStoryNavigation.routes.isEmpty {
            friendStoryNavigation.lastLocationKey = nil
            friendStoryNavigation.lastViewportSize = nil
            friendStoryNavigation.lastFocusedAuthorID = nil
        }
        friendStoryNavigation.begin(groups: groups, authorID: authorID,
            viewedKeys: storyReadStore.viewedKeys, origin: friendStoryMapSnapshot())
        if showsSocialFeedPreview,
           let pageID = postPreviewPageID ?? previewStoryResumePageIDs[authorID] {
            friendStoryNavigation.session?.selectPage(id: pageID)
        }
        guard let page = friendStoryNavigation.session?.currentPage else { return }
        activeExperience = nil
        focusedJourneyHeader = nil
        journeyEntry = nil
        journeyStack = []
        selectedFriendFootprintID = nil
        // An explicit root tap (avatar, Posts entry) follows the same policy
        // as a map marker: start compact in place. Horizontal paging keeps
        // its current detent and never goes through this root-opening path.
        experiencePresentation.presentNewContent()
        focusFriendStoryPage(page, geometry: geometry)
    }

    func finishFriendStory(restoreMap: Bool) {
        guard friendStoryNavigation.isActive || friendStoryNavigation.origin != nil else { return }
        rememberPreviewCursor()
        isBrowsingPostPreview = false
        flightController.cancelActiveTransition()
        if restoreMap, let origin = friendStoryNavigation.origin { restoreFriendStoryCamera(origin) }
        friendStoryNavigation.clear()
        selectedStoryId = nil
        selectedRealId = nil
        selectedFriendFootprintID = nil
        activeExperience = nil
        pendingViewedStoryKey = nil
        viewModel.releaseRetainedActiveFeedItem()
    }

    func reconcileFriendStories(geometry: GeometryProxy) {
        guard friendStoryNavigation.isActive else { return }
        let previousPage = friendStoryNavigation.session?.currentPage?.id
        friendStoryNavigation.session?.invalidate(memoryIDs: viewModel.withdrawnPublicMemoryIDs,
            chronologicalPosts: isBrowsingPostPreview)
        if isBrowsingPostPreview {
            friendStoryNavigation.session?.reconcilePosts(with: postFeedGroups)
        } else {
            let refreshedGroups = showsSocialFeedPreview
                ? previewGroups(friendStoryGroups, posts: false) : friendStoryGroups
            friendStoryNavigation.session?.reconcile(with: refreshedGroups)
        }
        guard let page = friendStoryNavigation.session?.currentPage else {
            finishFriendStory(restoreMap: false)
            cardPresentation.dismiss()
            return
        }
        // A revoked member cannot survive through a previously opened child.
        let withdrawn = viewModel.withdrawnPublicMemoryIDs
        if friendStoryNavigation.routes.contains(where: { route in
            switch route.content {
            case let .reel(reel): return withdrawn.contains(reel.id)
            case let .place(place): return place.checkIns.contains { withdrawn.contains($0.id) }
            case let .bubble(scope):
                return scope.journey.reels.contains { withdrawn.contains($0.id) }
                    || scope.journey.pois.contains { $0.checkIns.contains { withdrawn.contains($0.id) } }
            }
        }) {
            if let parent = friendStoryNavigation.routes.first {
                restoreFriendStoryCamera(parent.returnCamera)
                experiencePresentation.detent = parent.returnDetent == .large ? .large : experiencePresentation.compactDetent
            }
            friendStoryNavigation.routes = []
        }
        if previousPage != page.id {
            // A child may be focused somewhere else. Restore its parent before
            // applying same-place suppression for the replacement story page.
            if let parent = friendStoryNavigation.routes.first {
                restoreFriendStoryCamera(parent.returnCamera)
                experiencePresentation.detent = parent.returnDetent == .large ? .large : experiencePresentation.compactDetent
            }
            friendStoryNavigation.routes = []
            focusFriendStoryPage(page, geometry: geometry)
        }
    }

    func friendStoryPlace(_ id: UUID) -> RatedPOI? {
        // The expanded original card has public place history; the compact
        // story continues to reference only its exact original check-in.
        viewModel.publicPlaceDetails(id: id)
            ?? friendStoryNavigation.session?.groups.flatMap(\.pages).compactMap { page in
                if case let .poi(place, _, _) = page.content, place.id == id { return place }
                return nil
            }.first
    }

    func focusFriendStoryPage(_ page: FriendStoryPage, geometry: GeometryProxy) {
        guard mapWorkEnabled else { return }
        let previousStoryID = selectedStoryId
        if showsSocialFeedPreview && isBrowsingPostPreview && friendStoryNavigation.routes.isEmpty {
            postPreviewResumePageID = page.id
            viewModel.postFeedDidSelect(memoryID: page.memoryID)
            // Posts keep their own cursor and pagination, but share the map
            // camera: every selected Post should show where it happened.
        }
        switch page.content {
        case let .reel(reel):
            selectedStoryId = reel.id
            selectedRealId = reel.id
        case let .poi(place, _, _):
            selectedStoryId = place.id
            selectedRealId = nil
        }
        if selectedStoryId != previousStoryID || friendStoryNavigation.lastFocusedAuthorID != page.authorID {
            reelAlignTrigger &+= 1
        }
        guard let locationKey = page.locationKey else {
            // A location-less update must not finish the previous person's
            // delayed dive after the author has already changed.
            flightController.cancelActiveTransition()
            friendStoryNavigation.lastLocationKey = nil
            friendStoryNavigation.lastViewportSize = nil
            friendStoryNavigation.lastFocusedAuthorID = nil
            return
        }
        guard friendStoryNavigation.needsMapFocus(locationKey: locationKey,
            viewportSize: geometry.size, authorID: page.authorID) else { return }
        // A chronological Post is one destination, not a route containing
        // every place this author has ever published. POI story framing stays.
        let browsingCoordinates = isBrowsingPostPreview ? nil
            : friendStoryNavigation.session?.currentGroup?.pages.compactMap(\.coordinate)
        // Both detents share one selection and camera. Switching a post while
        // expanded must not leave the map at the previous post on return.
        friendStoryNavigation.lastLocationKey = locationKey
        friendStoryNavigation.lastViewportSize = geometry.size
        friendStoryNavigation.lastFocusedAuthorID = page.authorID
        switch page.content {
        case let .reel(reel):
            focusFriendStoryContent(.real(reel, viewModel.user(for: reel.userId)),
                geometry: geometry, browsingCoordinates: browsingCoordinates)
        case let .poi(place, _, _):
            focusFriendStoryContent(.poi(place), geometry: geometry, browsingCoordinates: browsingCoordinates)
        }
    }

    func focusFriendStoryContent(_ mode: ExperienceDetailView.Mode, geometry: GeometryProxy,
                                 browsingCoordinates: [CLLocationCoordinate2D]? = nil) {
        guard mapWorkEnabled else { return }
        viewModel.cancelPendingLocationFocus()
        let region: MKCoordinateRegion
        let cause: RegionChangeCause
        switch mode {
        case let .real(reel, _):
            guard CLLocationCoordinate2DIsValid(reel.center) else { return }
            region = viewModel.region(for: reel)
            cause = .real
        case let .poi(place):
            guard CLLocationCoordinate2DIsValid(place.poi.coordinate) else { return }
            region = viewModel.region(for: place)
            cause = .poi
        case let .journey(journey):
            let bubbleHeaderFraction = friendStoryNavigation.isBrowsingBubble
                ? FriendStoryLayout.floatingHeight / max(1, geometry.size.height) : 0
            guard let target = MapJourneyCamera.target(for: journey, size: geometry.size,
                safeAreaBottom: geometry.safeAreaInsets.bottom,
                compactFraction: activePreviewFraction + bubbleHeaderFraction) else { return }
            flightController.cancelActiveTransition()
            withAnimation(.easeInOut(duration: 0.28)) { cameraPosition = .region(target.region) }
            currentRegion = target.region
            return
        }
        // The Map ignores safe areas, while this outer GeometryReader does
        // not. Use the full canvas before subtracting chrome; otherwise the
        // same safe areas shrink the useful map twice and inflate lift height.
        let canvasSize = CGSize(
            width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
            height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
        let viewport = MapCameraViewport(size: canvasSize,
            topInset: MapTalkTopChromeLayout.height(safeAreaTop: geometry.safeAreaInsets.top, showsStories: true),
            bottomInset: geometry.size.height * activePreviewFraction
                + geometry.safeAreaInsets.bottom
                + (isBrowsingPostPreview && !friendStoryNavigation.isBrowsingBubble
                    ? 0 : FriendStoryLayout.floatingHeight))
        flightController.handleRegionChange(currentRegion: currentRegion, targetRegion: region,
            cause: cause, viewport: viewport, browsingCoordinates: browsingCoordinates,
            cameraPosition: cameraPositionStore.commandBinding) { currentRegion = $0 }
    }

    func searchNearbyPlaces(_ query: String) async -> MapTalkNearbyPlaceSearchResult {
        guard let location = viewModel.publishableLiveLocation else { return .init(options: []) }
        let publisher = environment.nearbyPOIRepo.searchResult(query, near: location.coordinate)
        for await result in publisher.values {
            guard !Task.isCancelled,
                  let currentLocation = viewModel.publishableLiveLocation else { return .init(options: []) }
            let places = result.places
            var matchingIDs = Set<UUID>()
            for place in places {
                let canonicalID = environment.backend?.canonicalPlaceForSelection(place.poi).id ?? place.id
                matchingIDs.insert(canonicalID)
            }
            // GPS can change while Apple's request is in flight. Revalidate
            // every candidate against the current fix before displaying it.
            let options = viewModel.nearbyPlaceOptions(near: currentLocation, matching: places)
            let matchingOptions = options.filter { option in
                matchingIDs.contains(option.id) || option.place.poi.name.localizedStandardContains(query)
            }
            return .init(options: matchingOptions, issue: result.issue)
        }
        return .init(options: [], issue: .temporarilyUnavailable)
    }

    func updateStandalonePlacePreview(from places: [RatedPOI]) {
        // Metadata renders before media downloads. Refresh the selected card in
        // place as photos arrive, preserving its detent, identity and map camera.
        switch activeExperience {
        case let .poi(previous, nonce):
            if let current = viewModel.publicPlaceDetails(id: previous.id,
                latestPublicPlace: places.first { $0.id == previous.id }), current != previous {
                activeExperience = .poi(rated: current, nonce: nonce)
            }
        case let .friendPlace(previous, sourceID, nonce):
            if let current = viewModel.publicPlaceDetails(id: previous.id,
                latestPublicPlace: places.first { $0.id == previous.id }), current != previous {
                activeExperience = .friendPlace(rated: current, sourceID: sourceID, nonce: nonce)
            }
        default:
            break
        }
    }

    func dismissWithdrawnPreview() {
        selectedRealId = nil
        selectedStoryId = nil
        selectedFriendFootprintID = nil
        activeExperience = nil
        cardPresentation.dismiss()
        pendingViewedStoryKey = nil
    }

    var selectedStandalonePOI: RatedPOI? {
        if case let .place(place)? = friendStoryNavigation.routes.last?.content { return place }
        if friendStoryNavigation.routes.isEmpty,
           case let .poi(place, _, _)? = friendStoryNavigation.session?.currentPage?.content { return place }
        guard case let .poi(rated, _)? = activeExperience else { return nil }
        return rated
    }

    var selectedStandaloneReel: RealPost? {
        if case let .reel(reel)? = friendStoryNavigation.routes.last?.content { return reel }
        if friendStoryNavigation.routes.isEmpty,
           case let .reel(reel)? = friendStoryNavigation.session?.currentPage?.content { return reel }
        guard case let .real(real, _)? = activeExperience else { return nil }
        return real
    }

    var friendStoryMapSelection: UUID? {
        if let route = friendStoryNavigation.routes.last {
            switch route.content {
            case let .place(place): return place.id
            case let .reel(reel): return reel.id
            case .bubble: return route.selectedID
            }
        }
        guard let page = friendStoryNavigation.session?.currentPage else { return nil }
        switch page.content {
        case let .reel(reel): return reel.id
        case let .poi(place, _, _): return place.id
        }
    }

    func refreshFriendFootprintVisibility(
        using mapProxy: MapProxy,
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        region: MKCoordinateRegion
    ) {
        guard mapWorkEnabled else { return }
        guard focusedJourneyHeader == nil, viewModel.isUserScope == false else {
            friendFootprintLayoutScheduler.cancel()
            friendFootprintVisibility = nil
            return
        }

        // Data, GPS and chrome changes can arrive during a pan or flight.
        // Project them only after the actual camera settles, using the latest
        // settled region rather than pairing an old region with a moving MapProxy.
        friendFootprintLayoutScheduler.request(canApply: {
            mapWorkEnabled && !flightController.isTransitionInProgress
        }) {
            applyFriendFootprintVisibility(
                using: mapProxy, canvasSize: canvasSize,
                topChromeBottom: topChromeBottom,
                region: friendFootprintLayoutScheduler.visibleRegion
                    ?? settledFriendFootprintRegion ?? region
            )
        }
    }

    func applyFriendFootprintVisibility(
        using mapProxy: MapProxy,
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        region: MKCoordinateRegion
    ) {
        guard mapWorkEnabled, focusedJourneyHeader == nil, !viewModel.isUserScope else { return }
        // A data refresh at the same zoom keeps existing representatives.
        // Only an actual scale change gets a fresh spatial sample.
        let preserveVisibleRepresentatives = FriendFootprintSamplingContinuityPolicy
            .shouldPreserveRepresentatives(from: friendFootprintLayoutRegion, to: region)

        let layout = FriendFootprintViewportPolicy.layout(
            footprints: viewModel.friendFootprints,
            in: region,
            retaining: selectedFriendFootprintID
        )
        let projectedPlaces = layout.places.compactMap { footprint in
            guard let point = mapProxy.convert(footprint.coordinate, to: .local),
                  let screenPoint = mapProxy.convert(footprint.coordinate, to: .global),
                  !FriendFootprintScreenOcclusionPolicy.isCoveredByControls(
                    projectedPoint: screenPoint, controlsFrame: mapControlsFrame
                  ) else { return nil as FriendFootprintProjectedPlace? }
            return FriendFootprintProjectedPlace(
                id: footprint.id,
                point: point,
                friendCount: footprint.friendIDs.count
            )
        }
        // Hidden home Post markers must not reserve space or suppress nearby POIs.
        let primaryCoordinates = viewModel.mapRenderPOIs(
            retaining: selectedStoryId,
            selectedMapPOI: selectedStandalonePOI
        ).map(\.poi.coordinate)
            + [viewModel.userCoordinate].compactMap { $0 }
        let reservedPoints = Array(
            primaryCoordinates.lazy.filter { coordinate in
                FriendFootprintViewportPolicy.contains(
                    coordinate,
                    in: region,
                    overscanFactor: 1.25
                )
            }.compactMap { coordinate in
                mapProxy.convert(coordinate, to: .local)
            }
        )
        let newVisibility = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: projectedPlaces,
            reservedPoints: reservedPoints,
            canvasSize: canvasSize,
            topChromeBottom: topChromeBottom,
            selectedID: selectedFriendFootprintID,
            previouslyVisibleIDs: preserveVisibleRepresentatives
                ? friendFootprintVisibility?.placeIDs ?? []
                : [],
            previouslyExpandedIDs: friendFootprintVisibility?.expandedPlaceIDs ?? [],
            previousDensityStyle: friendFootprintVisibility?.densityStyle
        )

        // Automatic layout must not inherit a sheet/flight animation and blink
        // annotations. A deliberate marker tap keeps its own selection feedback.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            friendFootprintLayoutRegion = region
            if friendFootprintVisibility != newVisibility {
                friendFootprintVisibility = newVisibility
            }
        }
    }

    func keepFriendFootprintVisible(
        footprint: MapTalkFriendFootprint,
        projectedPoint: CGPoint?,
        using mapProxy: MapProxy,
        canvasSize: CGSize,
        topChromeBottom: CGFloat
    ) {
        guard let camera = currentCamera,
              let targetPoint = FriendFootprintSelectionCameraPolicy.targetPoint(
            projectedPoint: projectedPoint,
            canvasSize: canvasSize,
            topChromeBottom: topChromeBottom,
            compactSheetFraction: ControlsLayout.previewFraction
        ),
              let coordinateAtTarget = mapProxy.convert(targetPoint, from: .local) else {
            return
        }
        let adjustedCenter = FriendFootprintSelectionCameraPolicy.adjustedCenter(
            selectedCoordinate: footprint.coordinate,
            coordinateAtTargetPoint: coordinateAtTarget,
            currentCenter: camera.centerCoordinate
        )
        let adjustedCamera = MapCamera(
            centerCoordinate: adjustedCenter,
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )

        pendingRegionCause = .other
        flightController.cancelActiveTransition()
        withAnimation(.easeOut(duration: 0.16)) {
            cameraPosition = .camera(adjustedCamera)
        }
    }

    /// The Bubble picker is another view of the person's private MyMap, not of
    /// the public map underneath the composer. POIs are projected to this
    /// person's check-ins so a shared landmark never leaks somebody else's
    /// activity into a Bubble preview.
    var myMapBubbleRecords: [UserMapRecord] {
        let archive = environment.myMapArchive
        let ownerID = archive.currentUserID

        let reelRecords = archive.privateReels
            .filter { $0.userId == ownerID }
            .map { reel in
                UserMapRecord(id: reel.id, timestamp: reel.activityDate, kind: .reel(reel))
            }

        let placeRecords = archive.privatePOIs.compactMap { rated -> UserMapRecord? in
            let personalVisits = rated.checkIns.filter { $0.userId == ownerID }
            guard let latestVisit = personalVisits.map(\.activityDate).max() else { return nil }

            var personalPlace = rated
            personalPlace.media = []
            personalPlace.checkIns = personalVisits
            personalPlace.comments = []
            personalPlace.endorsements = .init(hype: 0, solid: 0, meh: 0, questionable: 0)
            personalPlace.tags = []
            personalPlace.favoritesCount = 0
            return UserMapRecord(
                id: personalPlace.id,
                timestamp: latestVisit,
                kind: .poi(personalPlace)
            )
        }

        return (reelRecords + placeRecords)
            .sorted { $0.timestamp > $1.timestamp }
    }

    func completePublishing(
        _ draft: MapTalkPublishDraft,
        audience: MapPublishAudience,
        destination: MapTalkPublishDestination,
        requestID: UUID
    ) async throws {
        // POI stays anchored to current GPS. Only an explicit Post choice can
        // replace that coordinate; browsing the map never chooses it for you.
        guard let liveLocation = viewModel.publishLocation(for: destination) else {
            environment.location.requestWhenInUse()
            throw BackendClientError.message("Finding your current location. Try again in a moment.")
        }
        let location: CLLocation
        if case let .reel(post) = draft, let selected = post.location {
            guard let chosenLocation = PostLocationPolicy.location(for: selected, near: liveLocation) else {
                throw BackendClientError.message("This location is now more than 5 km away. Choose a nearby location.")
            }
            location = chosenLocation
        } else {
            location = liveLocation
        }

        let result: BackendPublishResult
        if let backend = environment.backend {
            result = try await backend.enqueuePublish(
                draft,
                audience: audience,
                location: location,
                requestID: requestID
            )
        } else {
            switch draft {
            case let .place(placeDraft):
                guard let place = viewModel.publishPlace(
                    placeDraft,
                    at: location,
                    audience: audience
                ) else {
                    throw BackendClientError.message("This place is no longer nearby. Choose a place at your current location.")
                }
                result = .poi(place)
            case let .reel(reelDraft):
                guard let reel = viewModel.publishReel(
                    reelDraft,
                    at: location,
                    audience: audience
                ) else {
                    throw BackendClientError.message("The reel couldn't be saved. Your draft is still here; try again.")
                }
                result = .reel(reel)
            }
        }

        // Public posts are available immediately. Still honor a server-side
        // takedown when reconciling a retry of an older publish request.
        let status = environment.backend?.ownedMemories[requestID]?.moderationStatus
        let visiblePublicly = audience == .livePublic && (status == nil || status == "approved")
            && environment.backend?.pendingPublications[requestID] == nil
        switch result {
        case let .poi(place):
            if visiblePublicly {
                selectedRealId = nil
                selectedStoryId = place.id
            }
        case let .reel(reel):
            if visiblePublicly {
                selectedRealId = reel.id
                selectedStoryId = reel.id
            }
        }

        // A private or queued post has no public marker yet. Acknowledge the
        // durable local save without claiming a network upload has completed.
        if environment.backend?.pendingPublications[requestID] != nil {
            publishAcknowledgement = "Saved · syncing in background"
        } else if audience == .privateMyMap {
            publishAcknowledgement = "Saved to MyMap"
        } else {
            publishAcknowledgement = visiblePublicly ? "Posted" : "Saved to MyMap"
        }
        publishAcknowledgementID = UUID()
        pendingRegionCause = .other
        reelAlignTrigger += 1
        publishDestination = nil
        if environment.backend != nil, visiblePublicly {
            viewModel.searchMap(in: currentRegion ?? viewModel.region)
        }
    }

    func requestPublish(_ destination: MapTalkPublishDestination) {
        guard publishDestination == nil else { return }
        if !cardPresentation.isMounted { finishFriendStory(restoreMap: false) }
        flightController.cancelActiveTransition()

        viewModel.refreshNearbyPlaces()

        if viewModel.publishLocation(for: destination) == nil {
            // Both publishers open immediately. Location and nearby POIs can
            // arrive while the person is already composing.
            environment.location.requestWhenInUse()
        }

        centerMapOnLivePublishLocation(for: destination)

        if cardPresentation.isMounted {
            // Native sheets cannot hand off cleanly to one another. Finish
            // reading the current capsule first, then open the chosen creator.
            queuedPublishDestination = destination
            cardPresentation.dismiss()
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                publishDestination = destination
            }
        }
    }

    func requestActivity() {
        guard isActivityPresented == false,
              isActivityOverExperiencePresented == false,
              publishDestination == nil else {
            return
        }

        if experiencePresentation.isPresented {
            // Present from the existing capsule so its selection and detent
            // remain intact underneath this independent notification flow.
            isActivityOverExperiencePresented = true
        } else {
            isActivityPresented = true
        }
    }

    /// Browsing can look anywhere, but the publishing surface always opens
    /// over the one place it represents: the device's live location. This is
    /// deliberately an immediate recenter rather than a cinematic map flight.
    func centerMapOnLivePublishLocation(for destination: MapTalkPublishDestination) {
        guard let coordinate = viewModel.publishLocation(for: destination)?.coordinate else { return }
        let region = MKCoordinateRegion(
            center: coordinate,
            span: currentRegion?.span ?? viewModel.region.span
        )

        flightController.cancelActiveTransition()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cameraPosition = .region(region)
        }
        currentRegion = region
    }

    func presentQueuedPublisherIfNeeded() {
        guard let destination = queuedPublishDestination else { return }
        queuedPublishDestination = nil
        viewModel.refreshNearbyPlaces()

        if viewModel.publishLocation(for: destination) == nil {
            environment.location.requestWhenInUse()
        }
        withAnimation(.easeOut(duration: 0.18)) {
            publishDestination = destination
        }
    }

    func journeyBoundingTarget(
        for journey: JourneyPost,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? {
        guard let target = MapJourneyCamera.target(
            for: journey,
            size: size,
            safeAreaBottom: safeAreaBottom,
            compactFraction: ControlsLayout.previewFraction
        ) else {
            return nil
        }
        return (target.region, target.distance)
    }

    func region(for item: RealStoriesRow.StoryItem) -> MKCoordinateRegion? {
        switch item.source {
        case let .real(real):
            return viewModel.region(for: real)
        case let .poi(group):
            return viewModel.region(for: group.ratedPOI)
        case let .journey(journey):
            return viewModel.region(for: journey)
        }
    }

    func exitJourneyFocus(size: CGSize, safeAreaBottom: CGFloat) {
        let currentJourney = focusedJourneyHeader
        if let parent = journeyStack.popLast() {
            focusedJourneyHeader = parent
            if let target = journeyBoundingTarget(
                for: parent,
                size: size,
                safeAreaBottom: safeAreaBottom
            ) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    cameraPosition = .camera(
                        MapCamera(
                            centerCoordinate: target.region.center,
                            distance: target.distance,
                            heading: 0,
                            pitch: 0
                        )
                    )
                }
                currentRegion = target.region
            } else {
                let region = viewModel.region(for: parent)
                withAnimation(.easeInOut(duration: 0.35)) {
                    cameraPosition = .region(region)
                }
                currentRegion = region
            }
            activeExperience = .sequence(nonce: UUID())
            configureProfileCardHeight()
            experiencePresentation.presentNewContent()
            return
        }

        focusedJourneyHeader = nil
        if journeyEntry == nil, currentJourney == nil {
            activeExperience = nil
            cardPresentation.dismiss()
        }
    }
}

private struct MapTalkHandwrittenBadge: View {
    let usesLightInk: Bool

    private func handwritingFont(scale: CGFloat = 1) -> Font {
        if UIFont(name: "SavoyeLetPlain", size: 44) != nil {
            return .custom("SavoyeLetPlain", size: 44 * scale)
        }
        if UIFont(name: "SnellRoundhand-Bold", size: 42) != nil {
            return .custom("SnellRoundhand-Bold", size: 42 * scale)
        }
        if UIFont(name: "MarkerFelt-Wide", size: 38) != nil {
            return .custom("MarkerFelt-Wide", size: 38 * scale)
        }
        return .system(size: 38 * scale, weight: .regular, design: .serif).italic()
    }

    private var signature: AttributedString {
        var text = AttributedString(AppBrand.wordmark)
        text.font = handwritingFont().weight(.bold)
        if let tallLetters = text.range(of: "fl") {
            // One shaped line and one baseline: soften the tall central pair
            // without compressing the rest of the signature or its descenders.
            text[tallLetters].font = handwritingFont(scale: 0.92).weight(.bold)
        }
        return text
    }

    private var inkGradient: LinearGradient {
        LinearGradient(
            colors: usesLightInk ? [.white, .white.opacity(0.97), .white] : [
                Color.black.opacity(0.98),
                Color.black.opacity(0.94),
                Color.black.opacity(0.98)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        Text(signature)
            .kerning(-0.15)
            .foregroundStyle(inkGradient)
            .shadow(color: .black.opacity(usesLightInk ? 0.7 : 0), radius: 3, y: 1)
            .accessibilityLabel(AppBrand.name)
    }
}

private struct MapTalkActivityButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let unreadCount: Int
    let usesDarkMaterial: Bool
    let action: () -> Void

    private var badgeText: String {
        unreadCount > 99 ? "99+" : unreadCount.formatted()
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: unreadCount > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(usesDarkMaterial ? Color.white.opacity(0.94) : Color.black.opacity(0.84))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(usesDarkMaterial ? 0.18 : 0.48), lineWidth: 1)
                    }
                    .environment(\.colorScheme, usesDarkMaterial ? .dark : colorScheme)

                if unreadCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, unreadCount > 9 ? 4 : 0)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.red, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.white, lineWidth: 1.5)
                        }
                        .offset(x: 5, y: -4)
                }
            }
            .shadow(color: Color.black.opacity(0.10), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .accessibilityLabel("Activity")
        .accessibilityValue(unreadCount == 0 ? "No new messages" : "\(unreadCount) new messages")
        .accessibilityIdentifier("maptalk.activity")
    }
}

private struct ProfileMapIdentityBadge: View {
    let user: User

    var body: some View {
        HStack(spacing: 8) {
            avatar

            Text("@\(user.handle)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
    }

    private var avatar: some View {
        ZStack {
            if let url = user.avatarURL {
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        placeholder
                            .overlay {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        Text(String(user.handle.prefix(2)).uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.6))
    }
}

private struct MapTalkControls: View {
    @Binding var mapLayer: MapTalkMapLayer
    let onTapLocate: () -> Void
    let onTapPlace: () -> Void
    let showsPublishActions: Bool
    var usesPostPreviewLayout = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if showsPublishActions {
                MapNavigationControls(selection: $mapLayer, onLocate: onTapLocate)
                    .frame(width: ControlsLayout.controlButtonSize)
            } else {
                LocateButton(action: onTapLocate)
                    .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
                    .accessibilityIdentifier("maptalk.locate")
            }
            if showsPublishActions {
                PlacePublishButton(action: onTapPlace, usesMomentMark: usesPostPreviewLayout)
                    .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
            }
        }
    }
}

/// Profile keeps a mixed history pager. Its native sheet follows the selected
/// card's backdrop; each page owns its own colors so neighbors never inherit it.
private struct MapTalkScopedSheetChrome: ViewModifier {
    let isProfile: Bool
    let profileMotion: ProfileCardSheetMotion
    let homeMotion: ProfileCardSheetMotion
    let presentation: MapExperiencePresentation
    let navigation: FriendStoryNavigation
    let feedPresentation: MapTalkFeedPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if isProfile {
            content
                .environment(\.profileCardSheetMotion, profileMotion)
                .modifier(ProfileCardSheetChrome(presentation: presentation, motion: profileMotion))
        } else {
            content.modifier(FriendStorySheetChrome(presentation: presentation,
                navigation: navigation, motion: homeMotion, feedPresentation: feedPresentation))
        }
    }
}

private struct MapTalkExperienceSheetHost: ViewModifier {
    let isProfile: Bool
    @ObservedObject var presentation: MapTalkCardPresentation
    let compactFraction: CGFloat
    let expandedTopInset: CGFloat
    let selectedSource: MapTalkCardTransitionID?
    let usesPostBackdrop: Bool
    let sheetContent: AnyView
    let onDismiss: () -> Void
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white

    @ViewBuilder
    func body(content: Content) -> some View {
        if isProfile {
            content.sheet(isPresented: Binding(get: { presentation.isPresented },
                set: presentation.nativePresentationChanged), onDismiss: onDismiss) { sheetContent }
        } else {
            content.background(HomeCardNativePresenter(presentation: presentation,
                compactFraction: compactFraction, expandedTopInset: expandedTopInset,
                selectedSource: selectedSource,
                backgroundColor: usesPostBackdrop ? UIColor(palette.background) : .clear,
                content: sheetContent, onDismiss: onDismiss)
                .allowsHitTesting(false))
        }
    }
}

private struct ProfileMapCardBackground: ViewModifier {
    let isEnabled: Bool
    let isPost: Bool
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.presentationBackground(isPost
                ? AnyShapeStyle(palette.background) : AnyShapeStyle(.thinMaterial))
        } else {
            content
        }
    }
}

private struct ProfilePlacePreview {
    let returnPostID: UUID?
    let returnWasExpanded: Bool
    let returnCamera: FriendStoryNavigation.MapSnapshot
}

private enum ActiveExperience: Identifiable {
    case sequence(nonce: UUID)
    case journey(journey: JourneyPost, nonce: UUID)
    case real(real: RealPost, nonce: UUID)
    case poi(rated: RatedPOI, nonce: UUID)
    case friendPlace(rated: RatedPOI, sourceID: String, nonce: UUID)

    var id: UUID {
        switch self {
        case let .sequence(nonce):
            return nonce
        case let .journey(_, nonce):
            return nonce
        case let .real(_, nonce):
            return nonce
        case let .poi(_, nonce):
            return nonce
        case let .friendPlace(_, _, nonce):
            return nonce
        }
    }

    var sequenceNonce: UUID? {
        switch self {
        case let .sequence(nonce):
            return nonce
        default:
            return nil
        }
    }
}

private enum JourneyEntry {
    case feedItem(UUID)
    case reel(RealPost)
    case poi(RatedPOI)
}

private enum MapTalkTopChromeLayout {
    static let topPadding: CGFloat = 10
    static let titleHeight: CGFloat = 52
    static let storySpacing: CGFloat = 6
    static let bottomPadding: CGFloat = 10

    static func height(safeAreaTop: CGFloat, showsStories: Bool) -> CGFloat {
        safeAreaTop
            + topPadding
            + titleHeight
            + (showsStories ? storySpacing + RealStoriesRow.layoutHeight : 0)
            + bottomPadding
    }
}

/// Equatable layout input, separate from model identity. A marker that moves or
/// gains friend activity must refresh ranking and collision even when its ID is
/// unchanged.
private struct MapMarkerLayoutRevision: Equatable {
    let id: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let weight: Int
}

private enum ControlsLayout {
    static let baseInset: CGFloat = 0.2
    static let baseSafeAreaMultiplier: CGFloat = 0.2
    static let previewGap: CGFloat = 1
    static let previewFraction: CGFloat = 0.35
    // Leave a separate fixed footer without squeezing the photo grid.
    static let postPreviewFraction: CGFloat = 0.48
    static let controlButtonSize: CGFloat = 54

    static func basePadding(for geometry: GeometryProxy) -> CGFloat {
        geometry.safeAreaInsets.bottom * baseSafeAreaMultiplier + baseInset
    }

    static func previewPadding(for geometry: GeometryProxy, fraction: CGFloat = previewFraction) -> CGFloat {
        basePadding(for: geometry) + geometry.size.height * fraction + previewGap
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

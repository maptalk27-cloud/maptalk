import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapTalkView: View {
    @StateObject private var viewModel: MapTalkViewModel
    @Environment(\.appEnv) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var flightController = MapFlightController()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var selectedStoryId: UUID?
    @State private var selectedFriendFootprintID: String?
    @State private var activeExperience: ActiveExperience?
    @StateObject private var experiencePresentation = MapExperiencePresentation(
        compactDetent: .fraction(ControlsLayout.previewFraction)
    )
    @State private var currentRegion: MKCoordinateRegion?
    @State private var currentCamera: MapCamera?
    @State private var settledFriendFootprintRegion: MKCoordinateRegion?
    @State private var friendFootprintVisibility: FriendFootprintScreenVisibility?
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
    @Namespace private var heroNamespace
    private let initialStoryId: UUID?

    init(viewModel: @autoclosure @escaping () -> MapTalkViewModel, initialStoryId: UUID? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.initialStoryId = initialStoryId
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
            let baseStoryItems = viewModel.activeFeedItems
            let friendGroups = usesFriendStories ? friendStoryGroups : []

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
            let mapReels = viewModel.mapRenderReels(
                retaining: selectedStoryId,
                selectedMapReel: selectedStandaloneReel
            )
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
            let sequenceItems = storyItems.map { item -> ExperienceDetailView.SequencePager.Item in
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
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            let previewControlsPadding = ControlsLayout.previewPadding(for: geometry,
                fraction: ControlsLayout.previewFraction)
                + (friendStoryNavigation.isActive ? FriendStoryLayout.floatingHeight : 0)
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
                guard sequenceItems.isEmpty == false else { return }
                let wasActive = experiencePresentation.isPresented
                guard shouldPresent || wasActive else { return }
                let nonce = (shouldPresent || activeExperience?.sequenceNonce == nil)
                    ? UUID()
                    : (activeExperience?.sequenceNonce ?? UUID())
                activeExperience = .sequence(nonce: nonce)
                if shouldPresent {
                    experiencePresentation.presentNewContent()
                }
            }

            let selectStoryItem: (RealStoriesRow.StoryItem, Bool, Bool, RegionChangeCause?) -> Void = { item, shouldPresent, shouldFocus, overrideCause in
                viewModel.cancelPendingLocationFocus()
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
                viewModel.cancelPendingLocationFocus()
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
                      let item = storyItemForId(initialStoryId) else {
                    return
                }
                didApplyInitialStorySelection = true
                selectStoryItem(item, true, true, .initial)
                reelAlignTrigger &+= 1
            }

            ZStack(alignment: .top) {
                MapReader { mapProxy in
                    let selectFriendFootprint: (MapTalkFriendFootprint) -> Void = { tapped in
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

                    Map(position: $cameraPosition, interactionModes: .all) {
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
                                onTap: selectFriendFootprint
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
                                experiencePresentation.presentNewContent()
                            },
                            onTapPOI: { rated in
                                finishFriendStory(restoreMap: false)
                                viewModel.cancelPendingLocationFocus()
                                if let item = storyItemForPOI(rated) {
                                    selectStoryItem(item, true, false, nil)
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
                                experiencePresentation.presentNewContent()
                            },
                            showsSelectedReelRangeOnly: usesFriendStories && focusedJourneyHeader == nil
                        )
                    }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("maptalk.map-canvas")
                    .accessibilityValue(currentCamera.map {
                        "\($0.centerCoordinate.latitude),\($0.centerCoordinate.longitude)"
                    } ?? "")
                    .onMapCameraChange(frequency: .continuous) { _ in
                        friendFootprintInteractionGate.noteCameraMotion()
                        if cameraPosition.positionedByUser {
                            viewModel.cancelPendingLocationFocus()
                            if friendStoryNavigation.isActive {
                                flightController.cancelActiveTransition()
                            }
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        friendFootprintInteractionGate.noteCameraMotion()
                        let preservesSettledRepresentatives =
                            FriendFootprintSamplingContinuityPolicy
                                .shouldPreserveRepresentatives(
                                    from: settledFriendFootprintRegion,
                                    to: context.region
                                )
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
                            region: context.region,
                            preserveVisibleRepresentatives: preservesSettledRepresentatives
                        )
                    }
                    .onChangeCompat(of: friendFootprintTopExclusion) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region,
                            preserveVisibleRepresentatives: false
                        )
                    }
                    .onChangeCompat(of: geometry.size) { _ in
                        refreshFriendFootprintVisibility(
                            using: mapProxy,
                            canvasSize: geometry.size,
                            topChromeBottom: friendFootprintTopExclusion,
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region,
                            preserveVisibleRepresentatives: false
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
                            region: settledFriendFootprintRegion ?? currentRegion ?? viewModel.region,
                            preserveVisibleRepresentatives: false
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
                                } else {
                                    MapTalkHandwrittenBadge()
                                }
                            }

                            if viewModel.scopedUser == nil {
                                HStack {
                                    Spacer()
                                    MapTalkActivityButton(
                                        unreadCount: unreadActivityCount
                                    ) {
                                        requestActivity()
                                    }
                                    .padding(.trailing, 16)
                                }
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
                                groups: friendStoryNavigation.session?.groups ?? friendGroups,
                                selectedAuthorID: friendStoryNavigation.session?.currentGroup?.authorID,
                                userProvider: viewModel.user(for:),
                                isUnseen: { group in group.readKeys.contains { !storyReadStore.isViewed($0) } },
                                onSelect: { authorID in
                                    openFriendStory(authorID: authorID, groups: friendGroups, geometry: geometry)
                                },
                                alignTrigger: reelAlignTrigger
                            )
                        }
                    } else if storyItems.isEmpty == false {
                        RealStoriesRow(
                            items: storyItems,
                            selectedId: selectedStoryId,
                            onSelectReal: { real in
                                guard let item = storyItemForReal(real) else { return }
                                selectStoryItem(item, true, true, nil)
                            },
                            onSelectPOIGroup: { group in
#if DEBUG
                                let userHandle = group.primarySharers.first?.user?.handle ?? "unknown"
                                print("[MapTalkView] Row tap poi=\(group.poiName) id=\(group.ratedPOI.id) topSharer=\(userHandle) hasRecent=\(group.ratedPOI.hasRecentPhotoShare)")
#endif
                                if let item = storyItemForPOI(group.ratedPOI) {
                                    selectStoryItem(item, true, true, nil)
                                }
                            },
                            onSelectJourney: { _ in },
                            userProvider: viewModel.user(for:),
                            alignTrigger: reelAlignTrigger,
                            displayMode: viewModel.isUserScope ? .content : .people,
                            isUnseen: isStoryUnseen
                        )
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, geometry.safeAreaInsets.top + MapTalkTopChromeLayout.topPadding)
                .padding(.bottom, MapTalkTopChromeLayout.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .top)
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.65))
                        .overlay(Color.white.opacity(0.06))
                        .mask {
                            LinearGradient(
                                colors: [
                                    .white,
                                    .white,
                                    .white.opacity(0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
                .ignoresSafeArea(edges: .top)
                .opacity(publishDestination == nil && !(friendStoryNavigation.isActive && experiencePresentation.isExpanded) ? 1 : 0)
                .allowsHitTesting(publishDestination == nil && !(friendStoryNavigation.isActive && experiencePresentation.isExpanded))
                .animation(.easeOut(duration: 0.16), value: publishDestination)
                .animation(.easeOut(duration: 0.16), value: experiencePresentation.isExpanded)

                if focusedJourneyHeader == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MapTalkControls(
                                onTapLocate: {
                                    finishFriendStory(restoreMap: false)
                                    if let region = currentRegion,
                                       let coordinate = viewModel.userCoordinate,
                                       region.center.distance(to: coordinate) < 500 {
                                        pendingRegionCause = .other
                                    } else {
                                        pendingRegionCause = .user
                                    }
                                    selectedRealId = nil
                                    selectedStoryId = nil
                                    activeExperience = nil
                                    experiencePresentation.dismiss()
                                    flushPendingViewedStory(nil)
                                    viewModel.releaseRetainedActiveFeedItem()
                                    viewModel.centerOnUser()
                                },
                                onTapPlace: {
                                    requestPublish(.place)
                                },
                                onTapReel: {
                                    requestPublish(.reel)
                                },
                                showsPublishActions: viewModel.isUserScope == false
                            )
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
            .sheet(isPresented: $experiencePresentation.isPresented, onDismiss: {
                guard experiencePresentation.didDismiss() == false else { return }
                if friendStoryNavigation.isActive { finishFriendStory(restoreMap: true) }
                flushPendingViewedStory(nil)
                selectedRealId = nil
                selectedStoryId = focusedJourneyHeader != nil ? storyItems.first?.id : nil
                selectedFriendFootprintID = nil
                viewModel.releaseRetainedActiveFeedItem()

                presentQueuedPublisherIfNeeded()
            }) {
                let isExpanded = experiencePresentation.isExpanded
                let shouldAnimateSelection = isExpanded == false

                let content: AnyView = {
                    if friendStoryNavigation.isActive {
                        return AnyView(FriendStoryFlow(
                            navigation: friendStoryNavigation,
                            detent: $experiencePresentation.detent,
                            compactDetent: experiencePresentation.compactDetent,
                            viewedKeys: storyReadStore.viewedKeys,
                            userProvider: viewModel.user(for:),
                            journeyProvider: viewModel.journey(for:),
                            placeProvider: friendStoryPlace,
                            captureCamera: friendStoryMapSnapshot,
                            restoreCamera: restoreFriendStoryCamera,
                            focusPage: { page in focusFriendStoryPage(page, geometry: geometry) },
                            focusContent: { mode in focusFriendStoryContent(mode, geometry: geometry) },
                            onRead: { storyReadStore.markViewed($0) },
                            onClose: {
                                // Keep the current card mounted throughout the native
                                // dismissal; onDismiss clears the session and restores the map.
                                experiencePresentation.dismiss(preservingDetent: true)
                            },
                            allowsPlayback: !isActivityOverExperiencePresented
                        ))
                    }
                    switch activeExperience {
                    case let .sequence(nonce):
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
                                    if suppressJourneySelectionUpdate {
                                        suppressJourneySelectionUpdate = false
                                        return
                                    }
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
                                    onCollapsedTap: experiencePresentation.expand,
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
                                onCollapsedTap: experiencePresentation.expand,
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
                                onCollapsedTap: experiencePresentation.expand,
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
                                onCollapsedTap: experiencePresentation.expand,
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

                content
                    .id(experiencePresentation.contentRevision)
                    .modifier(FriendStorySheetChrome(presentation: experiencePresentation,
                                                     navigation: friendStoryNavigation))
                    .fullScreenCover(isPresented: $isActivityOverExperiencePresented) {
                        activityContent
                            .presentationBackground(Color(.systemBackground))
                    }
            }
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
                    onRetryNearbyPlaces: { viewModel.refreshNearbyPlaces() }
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
                storyReadStore.configure(
                    accountID: environment.currentUser.id,
                    server: environment.backend?.api.baseURL.absoluteString ?? "preview"
                )
                WorldBasemapPrefetcher.shared.prefetchGlobalBasemapIfNeeded()
                if currentRegion == nil {
                    let initialRegion = viewModel.region
                    cameraPosition = .region(initialRegion)
                    currentRegion = initialRegion
                    settledFriendFootprintRegion = initialRegion
                    pendingRegionCause = .initial
                }
                viewModel.onAppear()
                controlsBottomPadding = baseControlsPadding
                ensureSelectionIfNeeded()
                applyInitialStorySelectionIfNeeded()
            }
            .onReceive(viewModel.$region.dropFirst()) { newRegion in
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
                    cameraPosition: $cameraPosition
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
                        experiencePresentation.dismiss()
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
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .active {
                    viewModel.onBecomeActive()
                    reconcileFriendStories(geometry: geometry)
                }
            }
            .onChange(of: friendStoryRevision(friendGroups)) { _, _ in
                reconcileFriendStories(geometry: geometry)
            }
            .onChange(of: environment.currentUser.id) { _, accountID in
                if friendStoryNavigation.isActive {
                    finishFriendStory(restoreMap: false)
                    experiencePresentation.dismiss()
                }
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
                        experiencePresentation.dismiss()
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
                    experiencePresentation.presentNewContent()
                }
            }
            .onChangeCompat(of: experiencePresentation.isPresented) { isActive in
                if isActive == false {
                    flushPendingViewedStory(nil)
                }
                let target = isActive ? previewControlsPadding : baseControlsPadding
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    controlsBottomPadding = target
                }
            }
            .onChangeCompat(of: experiencePresentation.detent) { detent in
                if friendStoryNavigation.isActive,
                   detent == experiencePresentation.compactDetent,
                   let page = friendStoryNavigation.session?.currentPage,
                   friendStoryNavigation.routes.isEmpty {
                    focusFriendStoryPage(page, geometry: geometry)
                }
                if detent == experiencePresentation.compactDetent, experiencePresentation.isPresented {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        controlsBottomPadding = previewControlsPadding
                    }
                } else if experiencePresentation.isPresented == false {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        controlsBottomPadding = baseControlsPadding
                    }
                }
            }
            .onChangeCompat(of: geometry.size) { _ in
                experiencePresentation.configureCompactDetent(.fraction(ControlsLayout.previewFraction))
                let recalculatedBase = ControlsLayout.basePadding(for: geometry)
                let recalculatedPreview = ControlsLayout.previewPadding(for: geometry,
                    fraction: ControlsLayout.previewFraction)
                    + (friendStoryNavigation.isActive ? FriendStoryLayout.floatingHeight : 0)
                let isElevated = controlsBottomPadding > recalculatedBase + 1
                controlsBottomPadding = isElevated ? recalculatedPreview : recalculatedBase
                if friendStoryNavigation.isActive, friendStoryNavigation.routes.isEmpty,
                   let page = friendStoryNavigation.session?.currentPage {
                    focusFriendStoryPage(page, geometry: geometry)
                }
            }
            .onChangeCompat(of: baseControlsPadding) { newValue in
                guard experiencePresentation.isPresented == false else { return }
                controlsBottomPadding = newValue
            }
            .onChangeCompat(of: previewControlsPadding) { newValue in
                guard experiencePresentation.isPresented else { return }
                controlsBottomPadding = newValue
            }
            .onChangeCompat(of: viewModel.mode) { _ in
                collapseDetent()
            }
        }
    }
}

private extension MapTalkView {
    var usesFriendStories: Bool {
        guard !viewModel.isUserScope else { return false }
#if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("--legacy-stories")
#else
        return true
#endif
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
        .init(camera: currentCamera, region: currentRegion)
    }

    func restoreFriendStoryCamera(_ snapshot: FriendStoryNavigation.MapSnapshot) {
        flightController.cancelActiveTransition()
        pendingRegionCause = .other
        if let camera = snapshot.camera { cameraPosition = .camera(camera) }
        else if let region = snapshot.region { cameraPosition = .region(region) }
        currentRegion = snapshot.region
        currentCamera = snapshot.camera
    }

    func openFriendStory(authorID: UUID, groups: [FriendStoryGroup], geometry: GeometryProxy) {
        let alreadyOpen = friendStoryNavigation.isActive
        viewModel.cancelPendingLocationFocus()
        pendingViewedStoryKey = nil
        if let parent = friendStoryNavigation.routes.first {
            restoreFriendStoryCamera(parent.returnCamera)
            experiencePresentation.detent = parent.returnDetent == .large ? .large : experiencePresentation.compactDetent
        }
        friendStoryNavigation.begin(groups: groups, authorID: authorID,
            viewedKeys: storyReadStore.viewedKeys, origin: friendStoryMapSnapshot())
        guard let page = friendStoryNavigation.session?.currentPage else { return }
        activeExperience = nil
        focusedJourneyHeader = nil
        journeyEntry = nil
        journeyStack = []
        selectedFriendFootprintID = nil
        if !alreadyOpen {
            experiencePresentation.configureCompactDetent(.fraction(ControlsLayout.previewFraction))
            experiencePresentation.presentNewContent()
        }
        focusFriendStoryPage(page, geometry: geometry)
        reelAlignTrigger &+= 1
    }

    func finishFriendStory(restoreMap: Bool) {
        guard friendStoryNavigation.isActive || friendStoryNavigation.origin != nil else { return }
        if restoreMap, let origin = friendStoryNavigation.origin { restoreFriendStoryCamera(origin) }
        friendStoryNavigation.clear()
        experiencePresentation.configureCompactDetent(.fraction(ControlsLayout.previewFraction))
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
        friendStoryNavigation.session?.invalidate(memoryIDs: viewModel.withdrawnPublicMemoryIDs)
        friendStoryNavigation.session?.reconcile(with: friendStoryGroups)
        guard let page = friendStoryNavigation.session?.currentPage else {
            finishFriendStory(restoreMap: true)
            experiencePresentation.dismiss()
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
        switch page.content {
        case let .reel(reel):
            selectedStoryId = reel.id
            selectedRealId = reel.id
        case let .poi(place, _, _):
            selectedStoryId = place.id
            selectedRealId = nil
        }
        reelAlignTrigger &+= 1
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
        // Both detents share one selection and camera. Switching a post while
        // expanded must not leave the map at the previous post on return.
        friendStoryNavigation.lastLocationKey = locationKey
        friendStoryNavigation.lastViewportSize = geometry.size
        friendStoryNavigation.lastFocusedAuthorID = page.authorID
        switch page.content {
        case let .reel(reel): focusFriendStoryContent(.real(reel, viewModel.user(for: reel.userId)), geometry: geometry)
        case let .poi(place, _, _): focusFriendStoryContent(.poi(place), geometry: geometry)
        }
    }

    func focusFriendStoryContent(_ mode: ExperienceDetailView.Mode, geometry: GeometryProxy) {
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
            guard let target = MapJourneyCamera.target(for: journey, size: geometry.size,
                safeAreaBottom: geometry.safeAreaInsets.bottom,
                compactFraction: ControlsLayout.previewFraction) else { return }
            flightController.cancelActiveTransition()
            withAnimation(.easeInOut(duration: 0.28)) { cameraPosition = .region(target.region) }
            currentRegion = target.region
            return
        }
        let viewport = MapCameraViewport(size: geometry.size,
            topInset: MapTalkTopChromeLayout.height(safeAreaTop: geometry.safeAreaInsets.top, showsStories: true),
            bottomInset: geometry.size.height * ControlsLayout.previewFraction
                + geometry.safeAreaInsets.bottom + FriendStoryLayout.floatingHeight)
        flightController.handleRegionChange(currentRegion: currentRegion, targetRegion: region,
            cause: cause, viewport: viewport, cameraPosition: $cameraPosition) { currentRegion = $0 }
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
        experiencePresentation.dismiss()
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
        region: MKCoordinateRegion,
        preserveVisibleRepresentatives: Bool = true
    ) {
        guard focusedJourneyHeader == nil, viewModel.isUserScope == false else {
            friendFootprintVisibility = nil
            return
        }

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
        let primaryCoordinates = viewModel.mapRenderReels(
            retaining: selectedStoryId,
            selectedMapReel: selectedStandaloneReel
        ).map(\.center)
            + viewModel.mapRenderPOIs(
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

        if friendFootprintVisibility != newVisibility {
            friendFootprintVisibility = newVisibility
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
        // Re-read the location at confirmation. The map may have been browsed
        // elsewhere, but neither a Place nor a Reel inherits its coordinate.
        guard let location = viewModel.publishLocation(for: destination) else {
            environment.location.requestWhenInUse()
            throw BackendClientError.message("Finding your current location. Try again in a moment.")
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
        finishFriendStory(restoreMap: false)

        viewModel.refreshNearbyPlaces()

        if viewModel.publishLocation(for: destination) == nil {
            // Both publishers open immediately. Location and nearby POIs can
            // arrive while the person is already composing.
            environment.location.requestWhenInUse()
        }

        centerMapOnLivePublishLocation(for: destination)

        if experiencePresentation.isPresented {
            // Native sheets cannot hand off cleanly to one another. Finish
            // reading the current capsule first, then open the chosen creator.
            queuedPublishDestination = destination
            experiencePresentation.dismiss()
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
            experiencePresentation.presentNewContent()
            return
        }

        focusedJourneyHeader = nil
        if journeyEntry == nil, currentJourney == nil {
            activeExperience = nil
            experiencePresentation.dismiss()
        }
    }
}

private struct MapTalkHandwrittenBadge: View {
    private var handwritingFont: Font {
        if UIFont(name: "SavoyeLetPlain", size: 44) != nil {
            return .custom("SavoyeLetPlain", size: 44)
        }
        if UIFont(name: "SnellRoundhand-Bold", size: 42) != nil {
            return .custom("SnellRoundhand-Bold", size: 42)
        }
        if UIFont(name: "MarkerFelt-Wide", size: 38) != nil {
            return .custom("MarkerFelt-Wide", size: 38)
        }
        return .system(size: 38, weight: .regular, design: .serif).italic()
    }

    private var inkGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.95),
                Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.82),
                Color.black.opacity(0.92)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        Text("maptalk")
            .font(handwritingFont.weight(.bold))
            .kerning(-0.8)
            .foregroundStyle(inkGradient)
    }
}

private struct MapTalkActivityButton: View {
    let unreadCount: Int
    let action: () -> Void

    private var badgeText: String {
        unreadCount > 99 ? "99+" : unreadCount.formatted()
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: unreadCount > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.84))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.48), lineWidth: 1)
                    }

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
    let onTapLocate: () -> Void
    let onTapPlace: () -> Void
    let onTapReel: () -> Void
    let showsPublishActions: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            LocateButton(action: onTapLocate)
                .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
            if showsPublishActions {
                PlacePublishButton(action: onTapPlace)
                    .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
                ReelPublishButton(action: onTapReel)
                    .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
            }
        }
    }
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

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapTalkView: View {
    @StateObject private var viewModel: MapTalkViewModel
    @Environment(\.appEnv) private var environment
    @State private var flightController = MapFlightController()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var selectedStoryId: UUID?
    @State private var activeExperience: ActiveExperience?
    @StateObject private var experiencePresentation = MapExperiencePresentation(
        compactDetent: .fraction(ControlsLayout.previewFraction)
    )
    @State private var currentRegion: MKCoordinateRegion?
    @State private var pendingRegionCause: RegionChangeCause = .initial
    @State private var reelAlignTrigger: Int = 0
    @State private var controlsBottomPadding: CGFloat = 0
    @State private var focusedJourneyHeader: JourneyPost?
    @State private var journeyEntryStoryId: UUID?
    @State private var journeyStack: [JourneyPost] = []
    @State private var suppressJourneySelectionUpdate: Bool = false
    @State private var didApplyInitialStorySelection: Bool = false
    @StateObject private var storyReadStore = StoryReadStore()
    @State private var pendingViewedStoryKey: String?
    @Namespace private var heroNamespace
    private let initialStoryId: UUID?

    init(viewModel: MapTalkViewModel, initialStoryId: UUID? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
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

            let baseStoryItems = MapStoryFeed.items(
                reals: viewModel.reals,
                ratedPOIs: viewModel.ratedPOIs,
                onlyRecentPOIStories: viewModel.isUserScope == false,
                userProvider: viewModel.user(for:)
            )

            let focusedStoryItems = focusedJourneyHeader.map(journeyStoryItems) ?? []

            let storyItems = focusedJourneyHeader == nil ? baseStoryItems : focusedStoryItems

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
                        mode: .poi(group.ratedPOI)
                    )
                case let .journey(journey):
                    return ExperienceDetailView.SequencePager.Item(
                        id: journey.id,
                        mode: .journey(journey)
                    )
                }
            }
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            let previewControlsPadding = ControlsLayout.previewPadding(for: geometry)
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
                flushPendingViewedStory(item.readKey)
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
                    journeyEntryStoryId = selectedStoryId ?? selectedRealId
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
                Map(position: $cameraPosition, interactionModes: .all) {
                    MapOverlays(
                        ratedPOIs: focusedJourneyHeader?.pois ?? viewModel.ratedPOIs,
                        reals: focusedJourneyHeader?.reels ?? viewModel.reals,
                        journeys: [],
                        userCoordinate: focusedJourneyHeader == nil ? viewModel.userCoordinate : nil,
                        heroNamespace: journeyNamespace,
                        useTimelineStyle: focusedJourneyHeader != nil,
                        displayMode: viewModel.isUserScope ? .content : .people,
                        selectedStoryId: selectedStoryId,
                        userProvider: viewModel.user(for:),
                        isRealUnseen: isRealUnseen,
                        isPOIUnseen: isPOIUnseen,
                        onTapReal: { real in
                            guard let item = storyItemForReal(real) else { return }
                            selectStoryItem(item, true, false, nil)
                            reelAlignTrigger &+= 1
                        },
                        onTapPOI: { rated in
                            guard let item = storyItemForPOI(rated) else { return }
                            selectStoryItem(item, true, false, nil)
                            reelAlignTrigger &+= 1
                        }
                    )
                }
                .ignoresSafeArea()

                VStack(spacing: 6) {
                    if focusedJourneyHeader == nil {
                        Group {
                            if let scopedUser = viewModel.scopedUser {
                                ProfileMapIdentityBadge(user: scopedUser)
                            } else {
                                MapTalkHandwrittenBadge()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
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

                    if storyItems.isEmpty == false {
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
                .padding(.top, geometry.safeAreaInsets.top + 10)
                .padding(.bottom, 10)
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

                if focusedJourneyHeader == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MapTalkControls(
                                onTapLocate: {
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
                                    viewModel.centerOnUser()
                                },
                                onTapRating: {},
                                onTapReal: {}
                            )
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, controlsBottomPadding)
                    }
                }
            }
            .sheet(isPresented: $experiencePresentation.isPresented, onDismiss: {
                guard experiencePresentation.didDismiss() == false else { return }
                flushPendingViewedStory(nil)
                selectedRealId = nil
                selectedStoryId = focusedJourneyHeader != nil ? storyItems.first?.id : nil
            }) {
                let isExpanded = experiencePresentation.isExpanded
                let shouldAnimateSelection = isExpanded == false

                let content: AnyView = {
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
                    default:
                        return AnyView(EmptyView())
                    }
                }()

                content
                    .id(experiencePresentation.contentRevision)
                    .mapExperienceSheetChrome(
                        compactDetent: .fraction(ControlsLayout.previewFraction),
                        selection: $experiencePresentation.detent
                    )
            }
            .onAppear {
                WorldBasemapPrefetcher.shared.prefetchGlobalBasemapIfNeeded()
                let initialRegion = viewModel.region
                cameraPosition = .region(initialRegion)
                currentRegion = initialRegion
                pendingRegionCause = .initial
                viewModel.onAppear()
                controlsBottomPadding = baseControlsPadding
                ensureSelectionIfNeeded()
                applyInitialStorySelectionIfNeeded()
            }
            .onReceive(viewModel.$region.dropFirst()) { newRegion in
                let cause = pendingRegionCause
                pendingRegionCause = .other
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
                if ids.isEmpty {
                    selectedRealId = nil
                    selectedStoryId = nil
                    activeExperience = nil
                    experiencePresentation.dismiss()
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
            .onChangeCompat(of: focusedJourneyHeader?.id) { identifier in
                if identifier != nil {
                    return
                }
                guard let entryId = journeyEntryStoryId else { return }
                if let item = storyItemForId(entryId) {
                    selectStoryItem(item, true, true, nil)
                } else {
                    selectedStoryId = entryId
                }
                journeyEntryStoryId = nil
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
                if detent == .fraction(ControlsLayout.previewFraction), experiencePresentation.isPresented {
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
                let recalculatedBase = ControlsLayout.basePadding(for: geometry)
                let recalculatedPreview = ControlsLayout.previewPadding(for: geometry)
                let isElevated = controlsBottomPadding > recalculatedBase + 1
                controlsBottomPadding = isElevated ? recalculatedPreview : recalculatedBase
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
        if journeyEntryStoryId == nil, currentJourney == nil {
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
                AsyncImage(url: url) { phase in
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
    let onTapRating: () -> Void
    let onTapReal: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            LocateButton(action: onTapLocate)
                .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
            RatingButton(action: onTapRating)
                .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
            RealButton(action: onTapReal)
                .frame(width: ControlsLayout.controlButtonSize, height: ControlsLayout.controlButtonSize)
        }
    }
}

private enum ActiveExperience: Identifiable {
    case sequence(nonce: UUID)
    case journey(journey: JourneyPost, nonce: UUID)
    case poi(rated: RatedPOI, nonce: UUID)

    var id: UUID {
        switch self {
        case let .sequence(nonce):
            return nonce
        case let .journey(_, nonce):
            return nonce
        case let .poi(_, nonce):
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

private enum ControlsLayout {
    static let baseInset: CGFloat = 0.2
    static let baseSafeAreaMultiplier: CGFloat = 0.2
    static let previewGap: CGFloat = 1
    static let previewFraction: CGFloat = 0.35
    static let controlButtonSize: CGFloat = 54

    static func basePadding(for geometry: GeometryProxy) -> CGFloat {
        geometry.safeAreaInsets.bottom * baseSafeAreaMultiplier + baseInset
    }

    static func previewPadding(for geometry: GeometryProxy) -> CGFloat {
        basePadding(for: geometry) + geometry.size.height * previewFraction + previewGap
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

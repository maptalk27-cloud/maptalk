import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapTalkView: View {
    @StateObject var viewModel: MapTalkViewModel
    @Environment(\.appEnv) private var environment
    @State private var flightController = MapFlightController()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var selectedStoryId: UUID?
    @State private var activeExperience: ActiveExperience?
    @State private var isExperiencePresented: Bool = false
    @State private var experienceDetent: PresentationDetent = .fraction(0.25)
    @State private var currentRegion: MKCoordinateRegion?
    @State private var pendingRegionCause: RegionChangeCause = .initial
    @State private var reelAlignTrigger: Int = 0
    @State private var controlsBottomPadding: CGFloat = 0
    @State private var focusedJourneyHeader: JourneyPost?
    @State private var preFocusSnapshot: (camera: MapCameraPosition, region: MKCoordinateRegion?, selectedId: UUID?)?
    @State private var journeyStack: [JourneyPost] = []
    @State private var detentRerenderKey: Int = 0
    @Namespace private var heroNamespace

    var body: some View {
        GeometryReader { geometry in
            let journeyNamespace = focusedJourneyHeader != nil ? heroNamespace : nil
            let makePOIGroup: (RatedPOI, Bool) -> RealStoriesRow.POIStoryGroup? = { rated, onlyRecent in
                let sharers = rated.checkIns.compactMap { checkIn -> RealStoriesRow.POISharer? in
                    let hasPhoto = checkIn.media.contains { media in
                        if case .photo = media.kind { return true }
                        return false
                    }
                    if onlyRecent {
                        if hasPhoto == false { return nil }
                        if checkIn.createdAt < Date().addingTimeInterval(-60 * 60 * 24) {
                            return nil
                        }
                    }
                    let user = viewModel.user(for: checkIn.userId)
                    return RealStoriesRow.POISharer(
                        id: checkIn.id,
                        user: user,
                        timestamp: checkIn.createdAt
                    )
                }
                .sorted { $0.timestamp > $1.timestamp }
                guard sharers.isEmpty == false else { return nil }
                return RealStoriesRow.POIStoryGroup(
                    ratedPOI: rated,
                    sharers: sharers,
                    latestTimestamp: sharers.first?.timestamp ?? (rated.checkIns.map(\.createdAt).max() ?? Date())
                )
            }

            let sortedReals = viewModel.reals.sorted { $0.createdAt > $1.createdAt }
            let baseJourneys = PreviewData.sampleJourneys
            let poiGroups = viewModel.ratedPOIs.compactMap { rated in
                makePOIGroup(rated, true)
            }
            let baseStoryItems = (
                sortedReals.map { RealStoriesRow.StoryItem(real: $0) } +
                baseJourneys.map { RealStoriesRow.StoryItem(journey: $0) } +
                poiGroups.compactMap { RealStoriesRow.StoryItem(poiGroup: $0) }
            )
            .sorted { $0.timestamp > $1.timestamp }

            let focusedStoryItems: [RealStoriesRow.StoryItem] = {
                guard let journey = focusedJourneyHeader else { return [] }
                let journeyPOIs = journey.pois.compactMap { rated in
                    makePOIGroup(rated, false)
                }
                let subJourneys = PreviewData.nestedJourneys[journey.id] ?? []
                let items = (
                    journey.reels.sorted { $0.createdAt > $1.createdAt }.map { RealStoriesRow.StoryItem(real: $0) } +
                    journeyPOIs.compactMap { RealStoriesRow.StoryItem(poiGroup: $0) } +
                    subJourneys.map { RealStoriesRow.StoryItem(journey: $0) }
                )
                return items.sorted { $0.timestamp > $1.timestamp }
            }()

            let storyItems = focusedJourneyHeader == nil ? baseStoryItems : focusedStoryItems

            let storyItemIds = storyItems.map(\.id)
            let nestedJourneys = focusedJourneyHeader.flatMap { PreviewData.nestedJourneys[$0.id] } ?? []
            let sequenceItems: [ExperienceDetailView.SequencePager.Item] = {
                if let journey = focusedJourneyHeader {
                    let journeyItem = ExperienceDetailView.SequencePager.Item(
                        id: journey.id,
                        mode: .journey(journey)
                    )
                    let others = storyItems.map { item -> ExperienceDetailView.SequencePager.Item in
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
                    return [journeyItem] + others
                } else {
                    return storyItems.map { item -> ExperienceDetailView.SequencePager.Item in
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
                }
            }()
            let primaryJourneyId = focusedJourneyHeader?.id
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            let previewControlsPadding = ControlsLayout.previewPadding(for: geometry)
            let collapseDetent = {
                print("[MapTalkView] collapseDetent requested; current detent=\(experienceDetent)")
                let wasLarge = experienceDetent == .large
                let wasPresented = isExperiencePresented
                let target: PresentationDetent = .fraction(0.25)
                detentRerenderKey &+= 1
                experienceDetent = target
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        experienceDetent = target
                    }
                }
                if wasPresented, wasLarge {
                    let savedExperience = activeExperience
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isExperiencePresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            activeExperience = savedExperience
                            experienceDetent = target
                            isExperiencePresented = wasPresented
                        }
                    }
                }
            }
            let journeyBoundingTarget: (JourneyPost) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? = { journey in
                let reelCoords = journey.reels.map(\.center)
                let poiCoords = journey.pois.map { $0.poi.coordinate }
                let coords = reelCoords + poiCoords
                guard coords.isEmpty == false else { return nil }

                if coords.count == 1, let coord = coords.first {
                    let region = MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: 800,
                        longitudinalMeters: 800
                    )
                    return (region, 800)
                }

                var mapRect = MKMapRect.null
                for coord in coords {
                    let point = MKMapPoint(coord)
                    let eventRect = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
                    mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
                }

                let fallbackSize = CGSize(width: 430, height: 932)
                let baseSize = geometry.size == .zero ? fallbackSize : geometry.size
                let mapView = MKMapView(frame: CGRect(origin: .zero, size: baseSize))
                // Reserve space for the header + stories row so the fitted region stays below them.
                let headerHeight = 52.0    // title bar
                let spacing: Double = 14.0 // spacing between title and row
                let rowHeight = 108.0      // RealStoriesRow fixed height
                let topInset = headerHeight + spacing + rowHeight + 8.0
                // Bottom inset: reserve space for the collapsed card.
                let bottomInset = 200.0
                let edgePadding = UIEdgeInsets(
                    top: topInset,
                    left: 40,
                    bottom: bottomInset,
                    right: 40
                )
                let fittedRect = mapView.mapRectThatFits(mapRect, edgePadding: edgePadding)
                let fittedRegion = MKCoordinateRegion(fittedRect)

                let spanMeters = UserMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
                let multiplier: Double = coords.count == 2 ? 3.4 : 2.2
                let distance = max(spanMeters * multiplier, 800)

                return (fittedRegion, distance)
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
            let storyItemForJourney: (JourneyPost) -> RealStoriesRow.StoryItem? = { journey in
                storyItems.first { item in
                    if case let .journey(candidate) = item.source {
                        return candidate.id == journey.id
                    }
                    return false
                } ?? RealStoriesRow.StoryItem(journey: journey)
            }
            let storyItemForId: (UUID) -> RealStoriesRow.StoryItem? = { id in
                if let match = storyItems.first(where: { $0.id == id }) {
                    return match
                }
                if let journey = focusedJourneyHeader, journey.id == id {
                    return RealStoriesRow.StoryItem(journey: journey)
                }
                return nil
            }

            let presentSequenceIfNeeded: (Bool) -> Void = { shouldPresent in
                guard sequenceItems.isEmpty == false else { return }
                let wasActive = isExperiencePresented
                guard shouldPresent || wasActive else { return }
                let nonce = (shouldPresent || activeExperience?.sequenceNonce == nil)
                    ? UUID()
                    : (activeExperience?.sequenceNonce ?? UUID())
                activeExperience = .sequence(nonce: nonce)
                if isExperiencePresented == false {
                    isExperiencePresented = true
                }
                if shouldPresent {
                    collapseDetent()
                }
            }

            let selectStoryItem: (RealStoriesRow.StoryItem, Bool, Bool, RegionChangeCause?) -> Void = { item, shouldPresent, shouldFocus, overrideCause in
                selectedStoryId = item.id
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

            let presentReal: (RealPost) -> Void = { real in
                guard let item = storyItemForReal(real) else { return }
                selectStoryItem(item, true, false, nil)
            }

            let handleJourneyTap: (JourneyPost, Bool, JourneyPost?) -> Void = { journey, presentSheet, parent in
                let isTappingCurrentFocusedJourney = (focusedJourneyHeader?.id == journey.id)
                if isExperiencePresented, experienceDetent == .large, isTappingCurrentFocusedJourney == false {
                    print("[MapTalkView] journeyTap collapsing sheet from large -> .25 detent")
                    collapseDetent()
                    if case .sequence = activeExperience {
                        activeExperience = .sequence(nonce: activeExperience?.sequenceNonce ?? UUID())
                    }
                }
                if focusedJourneyHeader == nil {
                    preFocusSnapshot = (
                        camera: cameraPosition,
                        region: currentRegion,
                        selectedId: selectedStoryId
                    )
                }
                if let parent, parent.id != journey.id {
                    journeyStack.append(parent)
                }
                focusedJourneyHeader = journey
                selectedStoryId = journey.id
                if let target = journeyBoundingTarget(journey) {
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
                    let preservedId = preFocusSnapshot?.selectedId ?? selectedStoryId
                    preFocusSnapshot = (
                        camera: cameraPosition,
                        region: currentRegion,
                        selectedId: preservedId
                    )
                } else {
                    viewModel.focus(on: journey)
                }
                if presentSheet {
                    if isTappingCurrentFocusedJourney, isExperiencePresented, experienceDetent == .large {
                        // Already on this journey in large sheet: refresh data but keep detent.
                        activeExperience = .sequence(nonce: activeExperience?.sequenceNonce ?? UUID())
                    } else {
                        activeExperience = .sequence(nonce: UUID())
                        if isExperiencePresented == false {
                            isExperiencePresented = true
                        }
                        experienceDetent = .fraction(0.25)
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

            ZStack(alignment: .top) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    MapOverlays(
                        ratedPOIs: focusedJourneyHeader?.pois ?? viewModel.ratedPOIs,
                        reals: focusedJourneyHeader?.reels ?? viewModel.reals,
                        journeys: focusedJourneyHeader == nil ? baseJourneys : nestedJourneys,
                        userCoordinate: focusedJourneyHeader == nil ? viewModel.userCoordinate : nil,
                        currentUser: PreviewData.currentUser,
                        onSelectPOI: { rated in
#if DEBUG
                            let handle = rated.checkIns.first?.userId
                            print("[MapTalkView] Pin tap poi=\(rated.poi.name) id=\(rated.id) hasRecent=\(rated.hasRecentPhotoShare) firstCheckInUser=\(handle?.uuidString ?? "nil")")
#endif
                            let targetRegion = viewModel.region(for: rated)
                            let cause: RegionChangeCause
                            if let region = currentRegion,
                               region.center.distance(to: targetRegion.center) < 1_000 {
                                cause = .other
                            } else {
                                cause = .poi
                            }
                            if let item = storyItemForPOI(rated) {
                                selectStoryItem(item, true, false, cause)
                            } else {
                                pendingRegionCause = cause
                                selectedStoryId = nil
                                selectedRealId = nil
                                activeExperience = .poi(rated: rated, nonce: UUID())
                                if isExperiencePresented == false {
                                    isExperiencePresented = true
                                }
                                collapseDetent()
                            }
                        },
                        onSelectReal: { real in
                            presentReal(real)
                        },
                        onSelectJourney: { journey in
                            handleJourneyTap(journey, true, focusedJourneyHeader)
                        },
                        onSelectUser: { },
                        heroNamespace: journeyNamespace,
                        useTimelineStyle: focusedJourneyHeader != nil
                    )
                }
                .ignoresSafeArea()

                VStack(spacing: 6) {
                    if focusedJourneyHeader == nil {
                        MapTalkHandwrittenBadge()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if let journeyHeader = focusedJourneyHeader {
                        let journeyPath = journeyStack + [journeyHeader]
                        let isHeaderHighlighted = (focusedJourneyHeader?.id == journeyHeader.id) &&
                            isExperiencePresented &&
                            (selectedStoryId == journeyHeader.id)
                        journeyHeaderView(
                            path: journeyPath,
                            selectedJourneyId: journeyHeader.id,
                            isActive: isHeaderHighlighted,
                            onSelect: { journey in
                                focusJourneyFromBreadcrumb(journey)
                            },
                            onExit: {
                                exitJourneyFocus()
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
                            onSelectJourney: { journey in
                                if let item = storyItemForJourney(journey) {
                                    // Only focus/fly, do not open the sheet from the row.
                                    selectStoryItem(item, true, true, .journey)
                                }
                            },
                            userProvider: viewModel.user(for:),
                            alignTrigger: reelAlignTrigger
                        )
                    }
                }
                .padding(.top, 10)

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
                                    isExperiencePresented = false
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
            .sheet(isPresented: $isExperiencePresented, onDismiss: {
                experienceDetent = .fraction(0.25)
                selectedRealId = nil
                if let journey = focusedJourneyHeader {
                    selectedStoryId = journey.id
                } else {
                    selectedStoryId = nil
                }
            }) {
                let isExpanded = experienceDetent == .large
                let shouldAnimateSelection = isExpanded == false

                let content: AnyView = {
                    switch activeExperience {
                    case .sequence:
                        if sequenceItems.isEmpty == false {
                            let pager = ExperienceDetailView.SequencePager(
                                items: sequenceItems,
                                primaryJourneyId: primaryJourneyId
                            )
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
                                    selectedStoryId = newValue
                                    if let journey = focusedJourneyHeader, newValue == journey.id {
                                        handleJourneyTap(journey, false, nil)
                                    } else if let item = storyItemForId(newValue) {
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
                                ExperienceDetailView(
                                    sequencePager: pager,
                                    selection: selectionBinding,
                                    isExpanded: isExpanded,
                                    onJourneyAvatarStackTap: { journey in
                                        handleJourneyTap(journey, true, focusedJourneyHeader)
                                    },
                                    userProvider: viewModel.user(for:)
                                )
                            )
                        } else {
                            return AnyView(EmptyView())
                        }
                    case let .poi(rated: rated, nonce: nonce):
                        return AnyView(
                            ExperienceDetailView(
                                ratedPOI: rated,
                                isExpanded: isExpanded,
                                userProvider: viewModel.user(for:)
                            )
                            .id("\(rated.id)-\(nonce)")
                        )
                    default:
                        return AnyView(EmptyView())
                    }
                }()

                content
                    .id(detentRerenderKey)
                    .presentationDetents([.fraction(0.25), .large], selection: $experienceDetent)
                    .presentationBackground(.thinMaterial)
                    .presentationCompactAdaptation(.none)
                    .applyBackgroundInteractionIfAvailable()
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
                if let focused = focusedJourneyHeader {
                    if selectedStoryId == focused.id {
                        return
                    }
                }
                if ids.isEmpty {
                    selectedRealId = nil
                    selectedStoryId = nil
                    activeExperience = nil
                    isExperiencePresented = false
                    return
                }
                if let currentId = selectedStoryId {
                    if ids.contains(currentId) == false {
                        selectedStoryId = nil
                        selectedRealId = nil
                    }
                } else {
                    selectedStoryId = nil
                    selectedRealId = nil
                }
            }
            .onChangeCompat(of: selectedStoryId) { identifier in
                if focusedJourneyHeader != nil {
                    return
                }
            }
            .onChangeCompat(of: isExperiencePresented) { isActive in
                let target = isActive ? previewControlsPadding : baseControlsPadding
                print("[MapTalkView] isExperiencePresented changed to \(isActive) detent=\(experienceDetent)")
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    controlsBottomPadding = target
                }
            }
            .onChangeCompat(of: experienceDetent) { detent in
                print("[MapTalkView] detent changed -> \(detent)")
                if detent == .fraction(0.25), isExperiencePresented {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        controlsBottomPadding = previewControlsPadding
                    }
                } else if isExperiencePresented == false {
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
                guard isExperiencePresented == false else { return }
                controlsBottomPadding = newValue
            }
            .onChangeCompat(of: previewControlsPadding) { newValue in
                guard isExperiencePresented else { return }
                controlsBottomPadding = newValue
            }
            .onChangeCompat(of: viewModel.mode) { _ in
                collapseDetent()
            }
        }
    }
}

private extension MapTalkView {
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

    func journeyFallbackTarget(for journey: JourneyPost) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? {
        let coords = journey.reels.map(\.center) + journey.pois.map { $0.poi.coordinate }
        guard coords.isEmpty == false else { return nil }

        if coords.count == 1, let coord = coords.first {
            let region = MKCoordinateRegion(center: coord, latitudinalMeters: 800, longitudinalMeters: 800)
            return (region, 800)
        }

        var mapRect = MKMapRect.null
        for coord in coords {
            let point = MKMapPoint(coord)
            let eventRect = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
            mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
        }

        let baseSize = CGSize(width: 430, height: 932)
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: baseSize))
        let topInset = 52.0 + 14.0 + 108.0 + 8.0
        let bottomInset = 200.0
        let edgePadding = UIEdgeInsets(top: topInset, left: 40, bottom: bottomInset, right: 40)
        let fittedRect = mapView.mapRectThatFits(mapRect, edgePadding: edgePadding)
        let fittedRegion = MKCoordinateRegion(fittedRect)

        let spanMeters = UserMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
        let multiplier: Double = coords.count == 2 ? 2.0 : 2.2
        let distance = max(spanMeters * multiplier, 240)

        return (fittedRegion, distance)
    }

    @ViewBuilder
    func journeyHeaderView(
        path: [JourneyPost],
        selectedJourneyId: UUID?,
        isActive: Bool,
        onSelect: @escaping (JourneyPost) -> Void,
        onExit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                onExit()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.45), in: Circle())
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(path, id: \.id) { journey in
                            let title = journeyTitle(for: journey)
                            JourneyBreadcrumbCard(
                                title: title,
                                subtitle: "Journey",
                                leadingSymbol: String(title.prefix(1)).uppercased(),
                                isSelected: journey.id == selectedJourneyId,
                                isActive: isActive && journey.id == selectedJourneyId
                            )
                            .id(journey.id)
                            .onTapGesture {
                                onSelect(journey)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: selectedJourneyId)
                }
                .onAppear {
                    guard let selectedJourneyId else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(selectedJourneyId, anchor: .center)
                    }
                }
                .onChangeCompat(of: selectedJourneyId) { identifier in
                    guard let identifier else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
        }
    }

    func journeyTitle(for journey: JourneyPost) -> String {
        let trimmed = journey.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? journey.displayLabel : trimmed
    }

    private struct JourneyBreadcrumbCard: View {
        let title: String
        let subtitle: String
        let leadingSymbol: String
        let isSelected: Bool
        let isActive: Bool

        var body: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(borderStyle, lineWidth: isSelected ? 1.5 : 1)
                    }

                content
            }
            .frame(width: isSelected ? 260 : 60, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(
                color: isSelected && isActive ? Theme.neonPrimary.opacity(0.15) : .clear,
                radius: isSelected && isActive ? 4 : 0,
                y: isSelected && isActive ? 1 : 0
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSelected)
        }

        @ViewBuilder
        private var content: some View {
            if isSelected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                Text(leadingSymbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var backgroundFill: AnyShapeStyle {
            if isSelected, isActive {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [Theme.neonPrimary.opacity(0.28), Color.black.opacity(0.82)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
            }
            if isSelected {
                return AnyShapeStyle(Color.black.opacity(0.6))
            }
            return AnyShapeStyle(Color.black.opacity(0.35))
        }

        private var borderStyle: AnyShapeStyle {
            if isSelected, isActive {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Theme.neonPrimary.opacity(0.35),
                            Theme.neonPrimary.opacity(0.12),
                            .clear
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
            }
            return AnyShapeStyle(Color.white.opacity(0.22))
        }
    }

    func exitJourneyFocus() {
        let currentJourney = focusedJourneyHeader
        if let parent = journeyStack.popLast() {
            focusedJourneyHeader = parent
            selectedStoryId = parent.id
            if let target = journeyFallbackTarget(for: parent) {
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
            isExperiencePresented = true
            experienceDetent = .fraction(0.25)
            preFocusSnapshot = nil
            return
        }
        focusedJourneyHeader = nil
        preFocusSnapshot = nil
        if let journey = currentJourney {
            selectedStoryId = journey.id
            let region = viewModel.region(for: journey)
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(region)
            }
            currentRegion = region
            activeExperience = .sequence(nonce: UUID())
            isExperiencePresented = true
            experienceDetent = .fraction(0.25)
        } else {
            activeExperience = nil
            isExperiencePresented = false
            experienceDetent = .fraction(0.25)
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
    static let previewFraction: CGFloat = 0.2
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

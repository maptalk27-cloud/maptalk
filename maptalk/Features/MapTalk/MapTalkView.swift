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

    var body: some View {
        GeometryReader { geometry in
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
                let items = (
                    journey.reels.sorted { $0.createdAt > $1.createdAt }.map { RealStoriesRow.StoryItem(real: $0) } +
                    journeyPOIs.compactMap { RealStoriesRow.StoryItem(poiGroup: $0) }
                )
                return items.sorted { $0.timestamp > $1.timestamp }
            }()

            let storyItems = focusedJourneyHeader == nil ? baseStoryItems : focusedStoryItems

            let storyItemIds = storyItems.map(\.id)
            let sequenceItems: [ExperienceDetailView.SequencePager.Item] = storyItems.map { item -> ExperienceDetailView.SequencePager.Item in
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
                DispatchQueue.main.async {
                    experienceDetent = .fraction(0.25)
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
                let edgePadding = UIEdgeInsets(
                    top: 36,
                    left: 40,
                    bottom: 36 + geometry.safeAreaInsets.bottom + controlsBottomPadding,
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
                }
            }
            let storyItemForId: (UUID) -> RealStoriesRow.StoryItem? = { id in
                storyItems.first { $0.id == id }
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

            let handleJourneyTap: (JourneyPost) -> Void = { journey in
                if focusedJourneyHeader == nil {
                    preFocusSnapshot = (
                        camera: cameraPosition,
                        region: currentRegion,
                        selectedId: selectedStoryId
                    )
                }
                focusedJourneyHeader = journey
                selectedStoryId = journey.id
                if let target = journeyBoundingTarget(journey) {
                    pendingRegionCause = .journey
                    flightController.cancelActiveTransition()
                    withAnimation(.easeInOut(duration: 0.32)) {
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
                activeExperience = .journey(journey: journey, nonce: UUID())
                isExperiencePresented = true
                experienceDetent = .fraction(0.25)
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
                        journeys: focusedJourneyHeader == nil ? baseJourneys : [],
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
                            if let item = storyItemForJourney(journey) {
                                selectStoryItem(item, true, false, .other)
                            }
                        },
                        onSelectUser: { }
                    )
                }
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    if let journeyHeader = focusedJourneyHeader {
                        journeyHeaderView(
                            for: journeyHeader,
                            isActive: (focusedJourneyHeader?.id == journeyHeader.id) && isExperiencePresented,
                            onTap: handleJourneyTap
                        )
                            .padding(.horizontal, 16)
                    } else {
                        SegmentedControl(
                            options: ["World", "Friends"],
                            selection: Binding(
                                get: { viewModel.mode.rawValue },
                                set: { viewModel.mode = .init(index: $0) }
                            )
                        )
                        .frame(maxWidth: .infinity)
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
                                selectStoryItem(item, true, true, .journey)
                            }
                        },
                            userProvider: viewModel.user(for:),
                            alignTrigger: reelAlignTrigger
                        )
                    }
                }
                .padding(.top, 16)

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
                selectedStoryId = nil
            }) {
                let isExpanded = experienceDetent == .large
                let shouldAnimateSelection = isExpanded == false

                let content: AnyView = {
                    switch activeExperience {
                    case .sequence:
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
                                ExperienceDetailView(
                                    sequencePager: pager,
                                    selection: selectionBinding,
                                    isExpanded: isExpanded,
                                    onJourneyAvatarStackTap: { journey in
                                        if focusedJourneyHeader == nil {
                                            preFocusSnapshot = (
                                                camera: cameraPosition,
                                                region: currentRegion,
                                                selectedId: selectedStoryId
                                            )
                                        }
                                        focusedJourneyHeader = journey
                                    },
                                    userProvider: viewModel.user(for:)
                                )
                            )
                        } else {
                            return AnyView(EmptyView())
                        }
                    case let .journey(journey: journey, nonce: nonce):
                        let pager = ExperienceDetailView.SequencePager(items: [
                            ExperienceDetailView.SequencePager.Item(
                                id: journey.id,
                                mode: .journey(journey)
                            )
                        ])
                        let selection = Binding<UUID>(
                            get: { journey.id },
                            set: { _ in }
                        )
                        return AnyView(
                            ExperienceDetailView(
                                sequencePager: pager,
                                selection: selection,
                                isExpanded: isExpanded,
                                userProvider: viewModel.user(for:)
                            )
                            .id("\(journey.id)-\(nonce)")
                        )
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
                    .presentationDetents([.fraction(0.25), .large], selection: $experienceDetent)
                    .presentationBackground(.thinMaterial)
                    .presentationSizing(.fitted)
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
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    controlsBottomPadding = target
                }
            }
            .onChangeCompat(of: experienceDetent) { detent in
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
            .onChangeCompat(of: focusedJourneyHeader?.id) { _ in
                guard let journey = focusedJourneyHeader else { return }
                handleJourneyTap(journey)
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

    @ViewBuilder
    func journeyHeaderView(
        for journey: JourneyPost,
        isActive: Bool,
        onTap: @escaping (JourneyPost) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                exitJourneyFocus()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.45), in: Circle())
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(isActive ? 0.65 : 0.45))
                    .frame(height: 52)
                    .frame(minWidth: 240)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(isActive ? 0.9 : 0.35), lineWidth: isActive ? 1.5 : 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(journeyTitle(for: journey))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(isActive ? Color.white : Color.white)
                        .lineLimit(1)
                    Text("Journey")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isActive ? .white.opacity(0.9) : .white.opacity(0.72))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

        Spacer()
    }
    .onTapGesture {
        onTap(journey)
    }
}

    func journeyTitle(for journey: JourneyPost) -> String {
        let trimmed = journey.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? journey.displayLabel : trimmed
    }

    func exitJourneyFocus() {
        focusedJourneyHeader = nil
        isExperiencePresented = false
        activeExperience = nil
        experienceDetent = .fraction(0.25)
        if let snapshot = preFocusSnapshot {
            selectedStoryId = snapshot.selectedId
            if let real = viewModel.reals.first(where: { $0.id == snapshot.selectedId }) {
                selectedRealId = real.id
            } else {
                selectedRealId = nil
            }
            pendingRegionCause = .other
            if let region = snapshot.region {
                currentRegion = region
            }
            cameraPosition = snapshot.camera
            preFocusSnapshot = nil
        }
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

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

    var body: some View {
        GeometryReader { geometry in
            let sortedReals = viewModel.reals.sorted { $0.createdAt > $1.createdAt }
            let poiGroups = viewModel.ratedPOIs.compactMap { rated -> RealStoriesRow.POIStoryGroup? in
                let sharers = rated.checkIns.compactMap { checkIn -> RealStoriesRow.POISharer? in
                    let hasPhoto = checkIn.media.contains { media in
                        if case .photo = media.kind { return true }
                        return false
                    }
                    guard hasPhoto, checkIn.createdAt >= Date().addingTimeInterval(-60 * 60 * 24) else { return nil }
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
                    latestTimestamp: sharers.first?.timestamp ?? Date()
                )
            }
            let storyItems = (
                sortedReals.map { RealStoriesRow.StoryItem(real: $0) } +
                poiGroups.map { RealStoriesRow.StoryItem(poiGroup: $0) }
            )
            .sorted { $0.timestamp > $1.timestamp }
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
                }
            }
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            let previewControlsPadding = ControlsLayout.previewPadding(for: geometry)
            let collapseDetent = {
                DispatchQueue.main.async {
                    experienceDetent = .fraction(0.25)
                }
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
                }
                presentSequenceIfNeeded(shouldPresent)
            }

            let presentReal: (RealPost) -> Void = { real in
                guard let item = storyItemForReal(real) else { return }
                selectStoryItem(item, true, false, nil)
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
                    return
                }
                if let first = storyItems.first {
                    let override: RegionChangeCause = pendingRegionCause == .initial ? .initial : .other
                    selectStoryItem(first, false, false, override)
                }
            }

            ZStack(alignment: .top) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    MapOverlays(
                        ratedPOIs: viewModel.ratedPOIs,
                        reals: viewModel.reals,
                        userCoordinate: viewModel.userCoordinate,
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
                        onSelectUser: { }
                    )
                }
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    SegmentedControl(
                        options: ["World", "Friends"],
                        selection: Binding(
                            get: { viewModel.mode.rawValue },
                            set: { viewModel.mode = .init(index: $0) }
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)

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
                            userProvider: viewModel.user(for:),
                            alignTrigger: reelAlignTrigger
                        )
                    }
                }
                .padding(.top, 16)

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
            .sheet(isPresented: $isExperiencePresented, onDismiss: {
                experienceDetent = .fraction(0.25)
                selectedRealId = nil
                selectedStoryId = nil
                activeExperience = nil
            }) {
                if let experience = activeExperience {
                    let isExpanded = experienceDetent == .large
                    let shouldAnimateSelection = isExpanded == false
                    Group {
                        switch experience {
                        case .sequence:
                            if sequenceItems.isEmpty == false {
                                let pager = ExperienceDetailView.SequencePager(items: sequenceItems)
                                let selectionBinding = Binding<UUID>(
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
                                ExperienceDetailView(
                                    sequencePager: pager,
                                    selection: selectionBinding,
                                    isExpanded: isExpanded,
                                    userProvider: viewModel.user(for:)
                                )
                            } else {
                                EmptyView()
                            }
                        case let .poi(rated: rated, nonce: nonce):
                            ExperienceDetailView(
                                ratedPOI: rated,
                                isExpanded: isExpanded,
                                userProvider: viewModel.user(for:)
                            )
                            .id("\(rated.id)-\(nonce)")
                        }
                    }
                    .presentationDetents([.fraction(0.25), .large], selection: $experienceDetent)
                    .presentationBackground(.thinMaterial)
                    .presentationSizing(.fitted)
                    .presentationCompactAdaptation(.none)
                    .applyBackgroundInteractionIfAvailable()
                }
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
                if ids.isEmpty {
                    selectedRealId = nil
                    selectedStoryId = nil
                    activeExperience = nil
                    isExperiencePresented = false
                    return
                }
                if let currentId = selectedStoryId {
                    if ids.contains(currentId) == false {
                        if let first = storyItems.first {
                            selectStoryItem(first, false, false, .other)
                        } else {
                            selectedStoryId = nil
                            selectedRealId = nil
                        }
                    }
                } else if let first = storyItems.first {
                    selectStoryItem(first, false, false, .other)
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
    case poi(rated: RatedPOI, nonce: UUID)

    var id: UUID {
        switch self {
        case let .sequence(nonce):
            return nonce
        case let .poi(_, nonce):
            return nonce
        }
    }

    var sequenceNonce: UUID? {
        if case let .sequence(nonce) = self {
            return nonce
        }
        return nil
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

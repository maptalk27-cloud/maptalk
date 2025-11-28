import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapTalkView: View {
    @StateObject var viewModel: MapTalkViewModel
    @Environment(\.appEnv) private var environment
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var selectedStoryId: UUID?
    @State private var activeExperience: ActiveExperience?
    @State private var isExperiencePresented: Bool = false
    @State private var experienceDetent: PresentationDetent = .fraction(0.25)
    @State private var currentRegion: MKCoordinateRegion?
    @State private var pendingRegionCause: RegionChangeCause = .initial
    @State private var activeTransitionID: UUID?
    @State private var reelAlignTrigger: Int = 0
    @State private var controlsBottomPadding: CGFloat = 0
    @State private var isProfilePresented: Bool = false

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
                        onSelectUser: {
                            isProfilePresented = true
                        }
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
                                        selectStoryItem(item, false, true, nil)
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
            .fullScreenCover(isPresented: $isProfilePresented) {
                NavigationStack {
                        ProfileHomeView(
                            viewModel: ProfileViewModel(environment: environment, context: .me)
                        )
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
                handleRegionChange(to: newRegion)
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

    private func handleRegionChange(to newRegion: MKCoordinateRegion) {
        // Interrupt any in-flight segment transition to avoid stacking animations
        if activeTransitionID != nil {
            activeTransitionID = nil
        }

        let cause = pendingRegionCause
        pendingRegionCause = .other

        guard let existingRegion = currentRegion else {
            withAnimation(smoothAnimation(duration: 0.5)) {
                self.cameraPosition = .region(cityClamp(newRegion))
            }
            self.currentRegion = cityClamp(newRegion)
            return
        }

        let travelDistance = existingRegion.center.distance(to: newRegion.center)

        if existingRegion.contains(newRegion.center, insetFraction: 0.92) &&
            newRegion.dominantSpanMeters <= existingRegion.dominantSpanMeters * 1.15 {
            let preserved = MKCoordinateRegion(center: newRegion.center, span: existingRegion.span)
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45)
            withAnimation(smoothAnimation(duration: duration)) {
                self.cameraPosition = .region(preserved)
            }
            self.currentRegion = preserved
            return
        }

        // Reduce Motion: fall back to a simplified transition
        if UIAccessibility.isReduceMotionEnabled {
            self.activeTransitionID = nil
            let d = min(0.30 + (travelDistance / 150_000.0), 0.45)
            withAnimation(smoothAnimation(duration: d)) {
                self.cameraPosition = .region(cityClamp(newRegion))
            }
            self.currentRegion = cityClamp(newRegion)
            return
        }

        let plan = transitionPlan(
            for: travelDistance,
            cause: cause,
            current: existingRegion,
            target: newRegion
        )
        apply(
            plan: plan,
            current: existingRegion,
            target: newRegion,
            travelDistance: travelDistance
        )
    }

    private func transitionPlan(
        for travelDistance: CLLocationDistance,
        cause: RegionChangeCause,
        current: MKCoordinateRegion,
        target: MKCoordinateRegion
    ) -> TransitionPlan {
        switch cause {
        case .initial, .other:
            return .direct

        case .user, .poi, .real:
            return stagedPlan(
                for: travelDistance,
                baseSpan: max(current.dominantSpanMeters, target.dominantSpanMeters)
            )
        }
    }

    private func stagedPlan(
        for travelDistance: CLLocationDistance,
        baseSpan: CLLocationDistance
    ) -> TransitionPlan {
        if travelDistance > 280_000 {
            let zoomDistance = clamp(travelDistance * 8, lower: 1_800_000, upper: 40_000_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 120_000 {
            let zoomDistance = clamp(max(travelDistance * 1.7, baseSpan * 4.2), lower: 320_000, upper: 1_600_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 55_000 {
            let zoomDistance = clamp(max(travelDistance * 1.45, baseSpan * 2.8), lower: 85_000, upper: 220_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else if travelDistance > 12_000 {
            let zoomDistance = clamp(max(travelDistance * 1.30, baseSpan * 2.1), lower: 40_000, upper: 120_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else {
            return .direct
        }
    }

    private func apply(
        plan: TransitionPlan,
        current: MKCoordinateRegion,
        target: MKCoordinateRegion,
        travelDistance: CLLocationDistance
    ) {
        switch plan {
        case .direct:
            self.activeTransitionID = nil
            let duration = min(0.35 + (travelDistance / 120_000.0), 0.55)
            withAnimation(smoothAnimation(duration: duration)) {
                self.cameraPosition = .region(cityClamp(target))
            }
            self.currentRegion = cityClamp(target)

        case let .staged(zoomDistance, tempo):
            runStagedTransition(
                from: current,
                to: target,
                zoomDistance: zoomDistance,
                tempo: tempo,
                travelDistance
            )
        }
    }

    private func runStagedTransition(
        from current: MKCoordinateRegion,
        to target: MKCoordinateRegion,
        zoomDistance: CLLocationDistance,
        tempo: TransitionTempo,
        _ travelDistance: CLLocationDistance
    ) {
        let id = UUID()
        self.activeTransitionID = id
        let durations = tempo.durations
        let liftFraction = tempo == .cinematic ? 0.38 : 0.26
        let liftCenter = current.center.interpolated(to: target.center, fraction: liftFraction)
        let liftPitch: CGFloat = tempo == .cinematic ? 36 : 0
        let cruisePitch: CGFloat = tempo == .cinematic ? 36 : 0

        // Stage 1: Lift up while easing toward the target
        withAnimation(smoothAnimation(duration: durations.zoomOut)) {
            self.cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: liftCenter,
                    distance: zoomDistance,
                    heading: 0,
                    pitch: liftPitch
                )
            )
        }

        // Stage 2: Cruise from the lift point toward the destination
        DispatchQueue.main.asyncAfter(deadline: .now() + durations.zoomOut) {
            guard self.activeTransitionID == id else { return }
            withAnimation(smoothAnimation(duration: durations.travel)) {
                self.cameraPosition = .camera(
                    MapCamera(
                        centerCoordinate: target.center,
                        distance: zoomDistance,
                        heading: 0,
                        pitch: cruisePitch
                    )
                )
            }
            self.scheduleDive(
                after: durations.travel,
                id: id,
                target: target,
                durations: durations,
                travelDistance: travelDistance
            )
        }
    }

    private func scheduleDive(
        after cruiseDuration: Double,
        id: UUID,
        target: MKCoordinateRegion,
        durations: (zoomOut: Double, travel: Double, prefetchHold: Double, zoomIn: Double),
        travelDistance: CLLocationDistance
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cruiseDuration) {
            guard self.activeTransitionID == id else { return }
            
            self.completeDive(to: target, with: durations.zoomIn, transitionID: id)
            
        }
    }

    private func completeDive(to target: MKCoordinateRegion, with duration: Double, transitionID id: UUID) {
        // Stage 3: Dive back to the city-level landing scale
        let clamped = cityClamp(target)
        withAnimation(smoothAnimation(duration: duration)) {
            self.cameraPosition = .region(clamped)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.activeTransitionID == id else { return }
            self.currentRegion = clamped
            self.activeTransitionID = nil
        }
    }

    /// Clamp the region to a consistent city-scale span (20km ~ 60km)
    private func cityClamp(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let meters = clamp(region.dominantSpanMeters, lower: 20_000, upper: 60_000)
        return MKCoordinateRegion(center: region.center, latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

// MARK: - Types & Helpers

private enum RegionChangeCause {
    case initial
    case real
    case poi
    case user
    case other
}

private enum TransitionPlan {
    case direct
    case staged(zoomDistance: CLLocationDistance, tempo: TransitionTempo)
}

private enum TransitionTempo {
    case subtle
    case cinematic

    var durations: (zoomOut: Double, travel: Double, prefetchHold: Double, zoomIn: Double) {
        switch self {
        case .subtle:
            return (0.2, 0.36, 0.08, 0.28)
        case .cinematic:
            return (1.5, 1.5, 0.02, 0.2)
        }
    }
}

private func smoothAnimation(duration: Double) -> Animation {
    // Animation curve inspired by Earth Studio (ease-in-out)
    Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: duration)
}

private func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    max(lower, min(value, upper))
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let target = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return origin.distance(from: target)
    }

    func interpolated(to other: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D {
        let clampedFraction = max(0, min(1, fraction))
        guard clampedFraction > 0 else { return self }
        guard clampedFraction < 1 else { return other }

        let lat1 = latitude.radians
        let lon1 = longitude.radians
        let lat2 = other.latitude.radians
        let lon2 = other.longitude.radians

        let sinLat = sin((lat2 - lat1) / 2)
        let sinLon = sin((lon2 - lon1) / 2)
        let a = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let angularDistance = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))

        if angularDistance.isZero {
            return other
        }

        let sinDistance = sin(angularDistance)
        let weightStart = sin((1 - clampedFraction) * angularDistance) / sinDistance
        let weightEnd = sin(clampedFraction * angularDistance) / sinDistance

        let x = weightStart * cos(lat1) * cos(lon1) + weightEnd * cos(lat2) * cos(lon2)
        let y = weightStart * cos(lat1) * sin(lon1) + weightEnd * cos(lat2) * sin(lon2)
        let z = weightStart * sin(lat1) + weightEnd * sin(lat2)

        let interpolatedLatitude = atan2(z, sqrt(x * x + y * y))
        let interpolatedLongitude = atan2(y, x)

        return CLLocationCoordinate2D(
            latitude: interpolatedLatitude.degrees,
            longitude: interpolatedLongitude.degrees
        )
    }
}

private extension MKCoordinateRegion {
    var dominantSpanMeters: CLLocationDistance {
        let halfLatitude = span.latitudeDelta / 2
        let halfLongitude = span.longitudeDelta / 2

        let north = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude + halfLatitude, longitude: center.longitude))
        let south = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude - halfLatitude, longitude: center.longitude))
        let east = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + halfLongitude))
        let west = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude - halfLongitude))

        let vertical = north.distance(to: south)
        let horizontal = east.distance(to: west)
        return max(vertical, horizontal)
    }

    func prefetchRegion(distance: CLLocationDistance) -> MKCoordinateRegion {
        let dominant = max(dominantSpanMeters, 60_000)
        let candidate = max(dominant * prefetchMultiplier(for: distance), distance * 0.68)
        let meters = clamp(candidate, lower: 80_000, upper: 3_500_000)
        return MKCoordinateRegion(
            center: center,
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
    }

    private func prefetchMultiplier(for distance: CLLocationDistance) -> CLLocationDistance {
        if distance > 3_200_000 {
            return 6.5
        } else if distance > 1_800_000 {
            return 5.1
        } else if distance > 900_000 {
            return 4.1
        } else if distance > 320_000 {
            return 3.1
        } else if distance > 140_000 {
            return 2.4
        } else {
            return 1.9
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D, insetFraction: Double = 1.0) -> Bool {
        let clampedFraction = max(0.0, min(1.0, insetFraction))
        let latRadius = span.latitudeDelta * 0.5 * clampedFraction
        let lonRadius = span.longitudeDelta * 0.5 * clampedFraction

        let latDelta = coordinate.latitude - center.latitude
        let lonDelta = coordinate.longitude - center.longitude

        return abs(latDelta) <= latRadius && abs(lonDelta) <= lonRadius
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

private extension View {
    @ViewBuilder
    func applyBackgroundInteractionIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            presentationBackgroundInteraction(.enabled)
        } else {
            self
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

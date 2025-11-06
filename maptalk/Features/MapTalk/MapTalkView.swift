import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapTalkView: View {
    @StateObject var viewModel: MapTalkViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var activeExperience: ActiveExperience?
    @State private var experienceDetent: PresentationDetent = .fraction(0.25)
    @State private var currentRegion: MKCoordinateRegion?
    @State private var pendingRegionCause: RegionChangeCause = .initial
    @State private var activeTransitionID: UUID?
    @State private var reelAlignTrigger: Int = 0
    @State private var controlsBottomPadding: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let sortedReals = viewModel.reals.sorted { $0.createdAt < $1.createdAt }
            let realItems = sortedReals.map { ActiveExperience.RealItem(real: $0, user: viewModel.user(for: $0.userId)) }
            let baseControlsPadding = ControlsLayout.basePadding(for: geometry)
            let previewControlsPadding = ControlsLayout.previewPadding(for: geometry)

            let updateSelection: (RealPost, Bool) -> Void = { real, shouldPresent in
                let previousSelection = selectedRealId
                selectedRealId = real.id
                if previousSelection == real.id {
                    pendingRegionCause = .other
                } else if previousSelection == nil && pendingRegionCause == .initial {
                    pendingRegionCause = .initial
                } else {
                    pendingRegionCause = .real
                }
                let wasActive = activeExperience != nil
                if shouldPresent || wasActive {
                    activeExperience = .real(items: realItems, currentId: real.id)
                }
                if shouldPresent && wasActive == false {
                    experienceDetent = .fraction(0.25)
                }
            }
            let presentReal: (RealPost) -> Void = { real in updateSelection(real, true) }

            ZStack(alignment: .top) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    MapOverlays(
                        ratedPOIs: viewModel.ratedPOIs,
                        reals: viewModel.reals,
                        userCoordinate: viewModel.userCoordinate,
                        onSelectPOI: { rated in
                            let targetRegion = viewModel.region(for: rated)
                            if let region = currentRegion,
                               region.center.distance(to: targetRegion.center) < 1_000 {
                                pendingRegionCause = .other
                            } else {
                                pendingRegionCause = .poi
                            }
                            activeExperience = .poi(rated)
                            experienceDetent = .fraction(0.25)
                        },
                        onSelectReal: { real in
                            presentReal(real)
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

                    if sortedReals.isEmpty == false {
                        RealStoriesRow(
                            reals: sortedReals,
                            selectedId: selectedRealId,
                            onSelect: { real, shouldPresent in
                                pendingRegionCause = .real
                                updateSelection(real, shouldPresent)
                                viewModel.focus(on: real)
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
                                activeExperience = nil
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
            .sheet(item: $activeExperience, onDismiss: {
                experienceDetent = .fraction(0.25)
                selectedRealId = nil
            }) { experience in
                let isExpanded = experienceDetent == .large
                Group {
                    switch experience {
                    case let .real(context):
                        let pagerItems = context.items.map { item in
                            ExperienceDetailView.ReelPager.Item(real: item.real, user: item.user)
                        }
                        let pager = ExperienceDetailView.ReelPager(
                            items: pagerItems,
                            initialId: context.currentId
                        )
                        let selectionBinding = Binding<UUID>(
                            get: { selectedRealId ?? context.currentId },
                            set: { newValue in
                                if let real = context.items.first(where: { $0.id == newValue })?.real {
                                    pendingRegionCause = .real
                                    updateSelection(real, false)
                                    viewModel.focus(on: real)
                                    reelAlignTrigger += 1
                                }
                            }
                        )
                        ExperienceDetailView(reelPager: pager, selection: selectionBinding, isExpanded: isExpanded)
                    case let .poi(rated):
                        ExperienceDetailView(ratedPOI: rated, isExpanded: isExpanded)
                    }
                }
                .presentationDetents([.fraction(0.25), .large], selection: $experienceDetent)
                .presentationBackground(.thinMaterial)
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
                if selectedRealId == nil, let first = sortedReals.first {
                    updateSelection(first, false)
                }
            }
            .onReceive(viewModel.$region.dropFirst()) { newRegion in
                handleRegionChange(to: newRegion)
            }
            .onChange(of: sortedReals.map(\.id)) { _ in
                if sortedReals.isEmpty {
                    selectedRealId = nil
                    activeExperience = nil
                    return
                }
                if let currentId = selectedRealId,
                   sortedReals.contains(where: { $0.id == currentId }) == false {
                    selectedRealId = nil
                }
                if selectedRealId == nil, let first = sortedReals.first {
                    updateSelection(first, false)
                }
            }
            .onChange(of: activeExperience != nil) { isActive in
                let target = isActive ? previewControlsPadding : baseControlsPadding
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    controlsBottomPadding = target
                }
            }
            .onChange(of: experienceDetent) { detent in
                if detent == .fraction(0.25), activeExperience != nil {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        controlsBottomPadding = previewControlsPadding
                    }
                } else if activeExperience == nil {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        controlsBottomPadding = baseControlsPadding
                    }
                }
            }
            .onChange(of: geometry.size) { _ in
                let recalculatedBase = ControlsLayout.basePadding(for: geometry)
                let recalculatedPreview = ControlsLayout.previewPadding(for: geometry)
                let isElevated = controlsBottomPadding > recalculatedBase + 1
                controlsBottomPadding = isElevated ? recalculatedPreview : recalculatedBase
            }
            .onChange(of: baseControlsPadding) { newValue in
                guard activeExperience == nil else { return }
                controlsBottomPadding = newValue
            }
            .onChange(of: previewControlsPadding) { newValue in
                guard activeExperience != nil else { return }
                controlsBottomPadding = newValue
            }
        }
    }

    private func handleRegionChange(to newRegion: MKCoordinateRegion) {
        // 并线打断：取消在途分段动画，避免排队/撕裂
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

        // Reduce Motion：直接/轻量过渡
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

        // Stage 1: 抬升（同时轻移向目标方向）
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

        // Stage 2: 巡航（从抬升点向目标慢速滑行）
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
        // Stage 3: 俯冲到“城市级”落地（统一尺度）
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

    /// 将 Region 收敛到城市级（20km ~ 60km 之间）
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
    // 更接近 Earth Studio 的缓入缓出
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
            RatingButton(action: onTapRating)
            RealButton(action: onTapReal)
        }
    }
}

private enum ActiveExperience: Identifiable {
    case real(items: [RealItem], currentId: UUID)
    case poi(RatedPOI)

    private static let realSheetID = UUID()

    struct RealItem: Identifiable {
        let real: RealPost
        let user: User?

        var id: UUID { real.id }
    }

    var id: UUID {
        switch self {
        case .real:
            return Self.realSheetID
        case let .poi(rated):
            return rated.poi.id
        }
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

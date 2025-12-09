import Combine
import MapKit
import SwiftUI
import UIKit

struct ProfileHomeView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMapDetail = false
    @State private var timelineDetailStartSegmentId: String?

    var body: some View {
        GeometryReader { proxy in
            let topInset = safeAreaTop()
            let heroHeightHint = proxy.size.height * 0.42
            let horizontalPadding: CGFloat = 8
            let safeWidth = proxy.size.width.isFinite ? proxy.size.width : 0
            let safeHeight = proxy.size.height.isFinite ? proxy.size.height : 0
            let availableWidth = max(0, safeWidth - (horizontalPadding * 2))
            let heightFactor: CGFloat = viewModel.identity.isCurrentUser ? 0.55 : 0.65
            let mapHeight = max(1, min(availableWidth, safeHeight * heightFactor))

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    ProfileHeroHeader(
                        identity: viewModel.identity,
                        summary: viewModel.summary,
                        persona: viewModel.persona,
                        onDismiss: dismiss,
                        topInset: topInset,
                        heightHint: heroHeightHint
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(
                        RoundedCorners(corners: [.bottomLeft, .bottomRight], radius: 32)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 20, x: 0, y: 8)

                    Group {
                        if viewModel.identity.isCurrentUser {
                            Button {
                                isShowingMapDetail = true
                            } label: {
                                ProfileMapPreview(
                                    pins: viewModel.mapPins,
                                    footprints: viewModel.footprints,
                                    reels: viewModel.reels,
                                    region: viewModel.mapRegion,
                                    isActive: isShowingMapDetail == false
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: mapHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, horizontalPadding)
                        } else {
                            ProfileTimelinePreview(
                                pins: viewModel.mapPins,
                                footprints: viewModel.footprints,
                                reels: viewModel.reels,
                                region: viewModel.mapRegion,
                                userProvider: userProvider,
                                onOpenDetail: { segment in
                                    timelineDetailStartSegmentId = segment?.id
                                    isShowingMapDetail = true
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: mapHeight)
                            .padding(.horizontal, horizontalPadding)
                        }
                    }

                    ProfileWideButton(title: "Message")
                        .padding(.horizontal, horizontalPadding)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .fullScreenCover(isPresented: $isShowingMapDetail) {
            ProfileMapDetailView(
                pins: viewModel.mapPins,
                reels: viewModel.reels,
                footprints: viewModel.footprints,
                profileUser: viewModel.identity.user,
                region: viewModel.mapRegion,
                userProvider: userProvider,
                onDismiss: {
                    isShowingMapDetail = false
                    timelineDetailStartSegmentId = nil
                },
                initialDisplayMode: .timeline,
                initialTimelineSegmentId: timelineDetailStartSegmentId
            )
        }
    }

    private var userProvider: (UUID) -> User? {
        { id in
            if id == viewModel.identity.user.id {
                return viewModel.identity.user
            }
            return PreviewData.user(for: id)
        }
    }

    private func safeAreaTop() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first?
            .safeAreaInsets.top ?? 0
    }

}

private struct ProfileHeroHeader: View {
    let identity: ProfileViewModel.Identity
    let summary: ProfileViewModel.Summary
    let persona: ProfileViewModel.Persona
    let onDismiss: DismissAction
    let topInset: CGFloat
    let heightHint: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Theme.neonPrimary.opacity(0.95), Color.black.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(
                Color.black.opacity(0.25)
                    .blendMode(.overlay)
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    Spacer()
                    Button {
                        // placeholder for share action
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    ProfileAvatarView(user: identity.user, size: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text(identity.subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Text(persona.bio)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            ProfileStatChip(title: "POI", value: summary.footprintCount)
                            ProfileStatChip(title: "Reels", value: summary.reelCount)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset + 6)
            .padding(.bottom, 18)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: heroHeight,
            maxHeight: heroHeight,
            alignment: .top
        )
        .ignoresSafeArea(edges: .top)
    }

    private var heroHeight: CGFloat {
        let minimumContent = topInset + 180
        return max(minimumContent, heightHint)
    }
}

private struct ProfileWideButton: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: 10, y: 6)
    }
}

private struct ProfileStatChip: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
        )
    }
}

private struct ProfileMapPreview: View {
    let pins: [ProfileViewModel.MapPin]
    let footprints: [ProfileViewModel.Footprint]
    let reels: [RealPost]
    let region: MKCoordinateRegion
    let isActive: Bool

    @State private var cameraPosition: MapCameraPosition
    @State private var spinLongitude: CLLocationDegrees
    @State private var spinPhase: SpinPhase = .north
    @State private var ticksRemaining: Int = 0
    @State private var phaseTicksTotal: Int = 0
    @StateObject private var cityResolver = TimelineCityResolver()

    private let spinLatitude: CLLocationDegrees
    private let globeDistance: CLLocationDistance = 20_000_000
    private let spinDuration: TimeInterval = 20
    private let spinFrameInterval: TimeInterval = 1.0 / 60.0
    private let transitionDuration: TimeInterval = 3.5
    private var previewTimelineSegments: [TimelineSegment] {
        let reelEvents = reels.map { real in
            TimelineEvent(
                id: real.id,
                date: real.createdAt,
                coordinate: real.center,
                kind: .reel(real, PreviewData.user(for: real.userId))
            )
        }

        let footprintEvents: [TimelineEvent] = footprints.compactMap { footprint in
            guard let visitDate = footprint.latestVisit else { return nil }
            return TimelineEvent(
                id: footprint.id,
                date: visitDate,
                coordinate: footprint.coordinate,
                kind: .poi(footprint.ratedPOI)
            )
        }

        let events = (reelEvents + footprintEvents).sorted { $0.date > $1.date }
        var segments: [TimelineSegment] = []
        for event in events {
            let label = cityResolver.label(for: event.coordinate, preferred: event.labelHint)
            if var last = segments.last, last.label == label {
                last.events.append(event)
                last.end = max(last.end, event.date)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TimelineSegment(
                        label: label,
                        start: event.date,
                        end: event.date,
                        events: [event]
                    )
                )
            }
        }
        return segments
    }
    private var spinFrameNanoseconds: UInt64 {
        UInt64((spinFrameInterval * 1_000_000_000).rounded())
    }
    private var rotationTicks: Int {
        Int((spinDuration / spinFrameInterval).rounded())
    }
    private var latitudeTransitionTicks: Int {
        Int((transitionDuration / spinFrameInterval).rounded())
    }

    init(
        pins: [ProfileViewModel.MapPin],
        footprints: [ProfileViewModel.Footprint],
        reels: [RealPost],
        region: MKCoordinateRegion,
        isActive: Bool
    ) {
        self.pins = pins
        self.footprints = footprints
        self.reels = reels
        self.region = region
        self.isActive = isActive
        let latitude = Self.clampedLatitude(region.center.latitude)
        spinLatitude = latitude
        let startingLongitude = Self.wrappedLongitude(region.center.longitude)
        _spinLongitude = State(initialValue: startingLongitude)
        let camera = Self.makeCamera(latitude: latitude, longitude: startingLongitude, distance: globeDistance)
        _cameraPosition = State(initialValue: .camera(camera))
    }

    var body: some View {
        let showDetails = ProfileMapAnnotationZoomHelper.isClose(distance: globeDistance)

        VStack(spacing: 10) {
            Map(position: $cameraPosition, interactionModes: []) {
                if showDetails {
                    ForEach(reels) { real in
                        MapCircle(center: real.center, radius: real.radiusMeters)
                            .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                            .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                        Annotation("", coordinate: real.center) {
                            RealMapThumbnail(real: real, user: PreviewData.user(for: real.userId), size: 38)
                        }
                    }
                    ForEach(pins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            ProfileMapMarker(category: pin.category)
                        }
                    }
                } else {
                    ForEach(reels) { real in
                        Annotation("", coordinate: real.center) {
                            ProfileCollapsedReelMarker(real: real)
                        }
                    }
                    ForEach(pins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            ProfileMapDotMarker(category: pin.category)
                        }
                    }
                }
            }
            .mapStyle(hybridMapStyle)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 10)
            .task(id: isActive) {
                guard isActive else { return }
                await spinContinuously()
            }
            .animation(nil, value: cameraPosition)
            .environment(\.colorScheme, .light)

            if previewTimelineSegments.isEmpty == false {
                PreviewTimelineAxis(segments: previewTimelineSegments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 180)
            }
        }
    }

    private func spinContinuously() async {
        let frameDelay = spinFrameNanoseconds
        await MainActor.run {
            startPhase(.north, resetLongitude: true)
        }
        while !Task.isCancelled {
            await MainActor.run {
                stepSpin()
            }
            do {
                try await Task.sleep(nanoseconds: frameDelay)
            } catch {
                break
            }
        }
    }

    @MainActor
    private func stepSpin() {
        if ticksRemaining <= 0 {
            let next = nextPhase(after: spinPhase)
            startPhase(next, resetLongitude: false)
        }
        let delta = spinDegreesPerTick
        let nextLongitude = Self.wrappedLongitude(spinLongitude + delta)
        spinLongitude = nextLongitude
        let camera = Self.makeCamera(latitude: currentLatitude, longitude: nextLongitude, distance: globeDistance)
        withTransaction(Transaction(animation: nil)) {
            cameraPosition = .camera(camera)
        }
        ticksRemaining -= 1
    }

    private var spinDegreesPerTick: CLLocationDegrees {
        (360 / spinDuration) * spinFrameInterval
    }

    private static func makeCamera(latitude: CLLocationDegrees, longitude: CLLocationDegrees, distance: CLLocationDistance) -> MapCamera {
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            distance: distance,
            heading: 0,
            pitch: 0
        )
    }

    private static func clampedLatitude(_ latitude: CLLocationDegrees) -> CLLocationDegrees {
        max(min(latitude, 70), -70)
    }

    private var currentLatitude: CLLocationDegrees {
        // Bias orbits toward the equator; north/south ranges overlap more for smoother swaps
        let northMagnitude = min(max(abs(spinLatitude), 20), 40)
        let southMagnitude = min(max(abs(spinLatitude), 15), 35)
        switch spinPhase {
        case .north:
            return northMagnitude
        case .south:
            return -southMagnitude
        case .transitionToSouth:
            let total = max(phaseTicksTotal, 1)
            let progress = easedProgress(1 - (Double(ticksRemaining) / Double(total)))
            let start = northMagnitude
            let end = -southMagnitude
            return start + (end - start) * progress
        case .transitionToNorth:
            let total = max(phaseTicksTotal, 1)
            let progress = easedProgress(1 - (Double(ticksRemaining) / Double(total)))
            let start = -southMagnitude
            let end = northMagnitude
            return start + (end - start) * progress
        }
    }

    private var hybridMapStyle: MapStyle {
        if #available(iOS 17.0, *) {
            return .hybrid(elevation: .realistic)
        }
        return .hybrid
    }

    private static func wrappedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
        var value = longitude
        if value > 180 {
            value -= 360
        } else if value < -180 {
            value += 360
        }
        return value
    }

    @MainActor
    private func startPhase(_ phase: SpinPhase, resetLongitude: Bool) {
        spinPhase = phase
        switch phase {
        case .north, .south:
            ticksRemaining = rotationTicks
            phaseTicksTotal = rotationTicks
        case .transitionToSouth, .transitionToNorth:
            ticksRemaining = latitudeTransitionTicks
            phaseTicksTotal = latitudeTransitionTicks
        }
        if resetLongitude {
            let startLongitude = Self.wrappedLongitude(region.center.longitude)
            spinLongitude = startLongitude
        }
        let camera = Self.makeCamera(latitude: currentLatitude, longitude: spinLongitude, distance: globeDistance)
        cameraPosition = .camera(camera)
    }

    private func nextPhase(after phase: SpinPhase) -> SpinPhase {
        switch phase {
        case .north:
            return .transitionToSouth
        case .transitionToSouth:
            return .south
        case .south:
            return .transitionToNorth
        case .transitionToNorth:
            return .north
        }
    }

    private func easedProgress(_ linear: Double) -> Double {
        // Smoothstep easing to avoid robotic motion
        return linear * linear * (3 - 2 * linear)
    }

    private enum SpinPhase {
        case north
        case transitionToSouth
        case south
        case transitionToNorth
    }
}

private struct ProfileTimelinePreview: View {
    let pins: [ProfileViewModel.MapPin]
    let footprints: [ProfileViewModel.Footprint]
    let reels: [RealPost]
    let region: MKCoordinateRegion
    let userProvider: (UUID) -> User?
    let onOpenDetail: ((TimelineSegment?) -> Void)?

    @State private var cameraPosition: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedTimelineSegmentId: String?
    @StateObject private var cityResolver = TimelineCityResolver()
    @State private var autoScrollNonce: UUID = .init()
    @State private var isUserInteracting: Bool = false
    @State private var interactionResetTask: Task<Void, Never>?

    private let paddingFactor: Double = 1.5
    private let minSpanMeters: Double = 1_200
    private let zoomOutExtra: Double = 1.2
    private let autoScrollInterval: UInt64 = 4_500_000_000
    private let teleportThreshold: CLLocationDistance = 1_000_000
    private let quickHopThreshold: CLLocationDistance = 500_000
    private let interactionCooldown: TimeInterval = 6

    init(
        pins: [ProfileViewModel.MapPin],
        footprints: [ProfileViewModel.Footprint],
        reels: [RealPost],
        region: MKCoordinateRegion,
        userProvider: @escaping (UUID) -> User?,
        onOpenDetail: ((TimelineSegment?) -> Void)? = nil
    ) {
        self.pins = pins
        self.footprints = footprints
        self.reels = reels
        self.region = region
        self.userProvider = userProvider
        self.onOpenDetail = onOpenDetail
        _cameraPosition = State(initialValue: .region(region))
        _currentRegion = State(initialValue: region)
    }

    var body: some View {
        VStack(spacing: 10) {
            Map(position: $cameraPosition, interactionModes: .all) {
                let segment = activeTimelineSegment
                ForEach(segmentReels(segment)) { real in
                    MapCircle(center: real.center, radius: real.radiusMeters)
                        .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                        .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                    Annotation("", coordinate: real.center) {
                        RealMapThumbnail(real: real, user: userProvider(real.userId), size: 44)
                    }
                }
                ForEach(segmentPins(segment)) { pin in
                    Annotation("", coordinate: pin.coordinate) {
                        ProfileMapMarker(category: pin.category)
                    }
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange(frequency: .continuous) { _ in
                markUserInteraction()
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    markUserInteraction()
                    onOpenDetail?(activeTimelineSegment)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 8)
            .onAppear {
                if selectedTimelineSegmentId == nil {
                    selectedTimelineSegmentId = timelineSegments.first?.id
                    if let first = timelineSegments.first {
                        flyToSegment(first, animated: false)
                    }
                }
            }

            PreviewTimelineAxis(
                segments: timelineSegments,
                selectedId: selectedTimelineSegmentId
            ) { segment in
                selectedTimelineSegmentId = segment.id
                flyToSegment(segment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 200)
        }
        .task(id: timelineSegments.map(\.id)) {
            await autoScrollTimeline()
        }
    }

    private var activeTimelineSegment: TimelineSegment? {
        if let id = selectedTimelineSegmentId {
            return timelineSegments.first { $0.id == id }
        }
        return timelineSegments.first
    }

    private var timelineSegments: [TimelineSegment] {
        let reelEvents = reels.map { real in
            TimelineEvent(
                id: real.id,
                date: real.createdAt,
                coordinate: real.center,
                kind: .reel(real, userProvider(real.userId))
            )
        }

        let footprintEvents: [TimelineEvent] = footprints.compactMap { footprint in
            guard let visitDate = footprint.latestVisit else { return nil }
            return TimelineEvent(
                id: footprint.id,
                date: visitDate,
                coordinate: footprint.coordinate,
                kind: .poi(footprint.ratedPOI)
            )
        }

        let events = (reelEvents + footprintEvents).sorted { $0.date > $1.date }
        var segments: [TimelineSegment] = []
        for event in events {
            let label = cityResolver.label(for: event.coordinate, preferred: event.labelHint)
            if var last = segments.last, last.label == label {
                last.events.append(event)
                last.end = max(last.end, event.date)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TimelineSegment(
                        label: label,
                        start: event.date,
                        end: event.date,
                        events: [event]
                    )
                )
            }
        }
        return segments
    }

    private func autoScrollTimeline() async {
        guard timelineSegments.count > 1 else { return }
        autoScrollNonce = UUID()
        let nonce = autoScrollNonce
        while !Task.isCancelled && nonce == autoScrollNonce {
            do {
                try await Task.sleep(nanoseconds: autoScrollInterval)
            } catch {
                break
            }
            let segments = timelineSegments
            guard segments.count > 1 else { continue }
            if isUserInteracting {
                continue
            }
            if Date().timeIntervalSince(lastInteractionDate) < interactionCooldown {
                continue
            }
            let next = nextSegment(after: selectedTimelineSegmentId, in: segments)
            await MainActor.run {
                selectedTimelineSegmentId = next.id
                flyToSegment(next)
            }
        }
    }

    @State private var lastInteractionDate: Date = .distantPast

    private func markUserInteraction() {
        lastInteractionDate = Date()
        isUserInteracting = true
        interactionResetTask?.cancel()
        interactionResetTask = Task { [interactionCooldown] in
            try? await Task.sleep(nanoseconds: UInt64(interactionCooldown * 1_000_000_000))
            await MainActor.run {
                isUserInteracting = false
            }
        }
    }

    private func nextSegment(after id: String?, in segments: [TimelineSegment]) -> TimelineSegment {
        guard let id, let index = segments.firstIndex(where: { $0.id == id }) else {
            return segments.first!
        }
        let nextIndex = (index + 1) % segments.count
        return segments[nextIndex]
    }

    private func segmentReels(_ segment: TimelineSegment?) -> [RealPost] {
        guard let segment else { return [] }
        return segment.events.compactMap { event in
            if case let .reel(real, _) = event.kind {
                return real
            }
            return nil
        }
    }

    private func segmentPins(_ segment: TimelineSegment?) -> [ProfileViewModel.MapPin] {
        guard let segment else { return [] }
        return segment.events.compactMap { event in
            if case let .poi(rated) = event.kind {
                return pins.first { $0.id == rated.id }
            }
            return nil
        }
    }

    private func flyToSegment(_ segment: TimelineSegment, animated: Bool = true) {
        guard let target = boundingTarget(for: segment.events) else { return }
        let camera = MapCamera(
            centerCoordinate: target.region.center,
            distance: target.distance,
            heading: 0,
            pitch: 0
        )
        let travelDistance = currentRegion.center.distance(to: target.region.center)
        if travelDistance > teleportThreshold {
            withTransaction(Transaction(animation: nil)) {
                cameraPosition = .region(target.region)
            }
            currentRegion = target.region
            return
        }
        if animated {
            let duration: Double
            if travelDistance > quickHopThreshold {
                duration = 0.2
            } else {
                duration = 0.45
            }
            withAnimation(.smooth(duration: duration)) {
                cameraPosition = .camera(camera)
            }
        } else {
            cameraPosition = .camera(camera)
        }
        currentRegion = target.region
    }

    private func boundingTarget(for events: [TimelineEvent]) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? {
        guard events.isEmpty == false else { return nil }

        var mapRect = MKMapRect.null
        for event in events {
            let point = MKMapPoint(event.coordinate)
            let radiusMeters: CLLocationDistance
            if case let .reel(real, _) = event.kind {
                radiusMeters = max(real.radiusMeters, 0)
            } else {
                radiusMeters = 0
            }
            let pointsRadius = radiusMeters * MKMapPointsPerMeterAtLatitude(event.coordinate.latitude)
            let eventRect = MKMapRect(
                origin: MKMapPoint(x: point.x - pointsRadius, y: point.y - pointsRadius),
                size: MKMapSize(width: pointsRadius * 2, height: pointsRadius * 2)
            )
            mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
        }

        let centerPoint = MKMapPoint(x: mapRect.midX, y: mapRect.midY)
        let centerCoordinate = centerPoint.coordinate
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(centerCoordinate.latitude)
        let minSpanPoints = minSpanMeters * pointsPerMeter
        if mapRect.width < minSpanPoints || mapRect.height < minSpanPoints {
            let targetWidth = max(mapRect.width, minSpanPoints)
            let targetHeight = max(mapRect.height, minSpanPoints)
            mapRect = MKMapRect(
                x: centerPoint.x - targetWidth / 2,
                y: centerPoint.y - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            )
        }

        let scale = max(paddingFactor * zoomOutExtra, 1)
        let extraWidth = mapRect.width * (scale - 1) / 2
        let extraHeight = mapRect.height * (scale - 1) / 2
        mapRect = mapRect.insetBy(dx: -extraWidth, dy: -extraHeight)

        let screenSize = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
            .first ?? .zero
        let fallbackSize = screenSize == .zero ? CGSize(width: 430, height: 932) : screenSize
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: fallbackSize))
        let edgePadding = UIEdgeInsets(top: 40, left: 36, bottom: 140, right: 36)
        let fittedRect = mapView.mapRectThatFits(mapRect, edgePadding: edgePadding)
        let fittedRegion = MKCoordinateRegion(fittedRect)

        let spanMeters = ProfileMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
        let distance = max(spanMeters, minSpanMeters) * 1.2

        return (fittedRegion, distance)
    }
}

private struct ProfileMapDetailView: View {
    let pins: [ProfileViewModel.MapPin]
    let reels: [RealPost]
    let footprints: [ProfileViewModel.Footprint]
    let profileUser: User
    let region: MKCoordinateRegion
    let userProvider: (UUID) -> User?
    let onDismiss: () -> Void

    @State private var flightController = MapFlightController()
    @State private var cameraPosition: MapCameraPosition
    @State private var displayMode: MapDisplayMode = .timeline
    @StateObject private var cityResolver = TimelineCityResolver()
    @State private var selectedTimelineSegmentId: String?
    @State private var lastCenter: CLLocationCoordinate2D
    @State private var currentRegion: MKCoordinateRegion
    @State private var sheetState: MapSheetState = .collapsed
    @State private var filter: MapListFilter = .all
    @State private var isShowingDetailedAnnotations: Bool
    @State private var isExperiencePresented = false
    @State private var experienceDetent: PresentationDetent = .fraction(0.25)
    @State private var isListSelection: Bool = false
    @State private var selectedEntryId: UUID?
    @State private var lastCameraDistance: CLLocationDistance?
    @State private var timelineEffectStyle: TimelineVisualEffect?
    @State private var timelineEffectProgress: Double = 0
    @State private var didApplyInitialTimelineFocus = false
    private let timelineAnimationStyle: TimelineAnimationStyle = .smooth
    private let timelinePaddingFactor: Double = 1.65
    private let timelineMinSpanMeters: Double = 1_200
    private let timelineZoomOutExtra: Double = 1.25
    private let timelineTeleportThreshold: CLLocationDistance = 2_200_000

    init(
        pins: [ProfileViewModel.MapPin],
        reels: [RealPost],
        footprints: [ProfileViewModel.Footprint],
        profileUser: User,
        region: MKCoordinateRegion,
        userProvider: @escaping (UUID) -> User?,
        onDismiss: @escaping () -> Void,
        initialDisplayMode: MapDisplayMode = .timeline,
        initialTimelineSegmentId: String? = nil
    ) {
        self.pins = pins
        self.reels = reels
        self.footprints = footprints
        self.profileUser = profileUser
        self.region = region
        self.userProvider = userProvider
        self.onDismiss = onDismiss
        _cameraPosition = State(initialValue: .region(region))
        _lastCenter = State(initialValue: region.center)
        _currentRegion = State(initialValue: region)
        _isShowingDetailedAnnotations = State(initialValue: ProfileMapAnnotationZoomHelper.isClose(region: region))
        _displayMode = State(initialValue: initialDisplayMode)
        _selectedTimelineSegmentId = State(initialValue: initialTimelineSegmentId)
    }

    var body: some View {
        GeometryReader { _ in
            let topInset = safeAreaTopInset()
            ZStack(alignment: .topLeading) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    let now = Date()
                    let reelsForDisplay = activeReels.sorted { lhs, rhs in
                        let lhsMode = reelDisplayMode(for: lhs, now: now)
                        let rhsMode = reelDisplayMode(for: rhs, now: now)
                        if lhsMode.priority != rhsMode.priority {
                            return lhsMode.priority < rhsMode.priority
                        }
                        return lhs.createdAt > rhs.createdAt
                    }

                    ForEach(reelsForDisplay) { real in
                        let mode = reelDisplayMode(for: real, now: now)
                        if mode == .thumbnail {
                            MapCircle(center: real.center, radius: real.radiusMeters)
                                .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                                .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                        }
                        Annotation("", coordinate: real.center) {
                            Button {
                                isListSelection = false
                                presentReal(real)
                            } label: {
                                switch mode {
                                case .thumbnail:
                                    RealMapThumbnail(real: real, user: userProvider(real.userId), size: 44)
                                case .heart:
                                    ProfileMapReelHeartMarker()
                                case .dot:
                                    ProfileMapReelDotMarker()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(activePins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            Button {
                                isListSelection = false
                                presentPin(pin)
                            } label: {
                                if isShowingDetailedAnnotations {
                                    ProfileMapMarker(category: pin.category)
                                } else {
                                    ProfileMapDotMarker(category: pin.category)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
            .ignoresSafeArea()
            .mapStyle(.standard)
            .saturation(mapSaturationEffect)
            .blur(radius: mapBlurEffect)
            .overlay(timelineEffectOverlay)
            .onMapCameraChange(frequency: .continuous) { context in
                lastCenter = context.region.center
                currentRegion = context.region
                lastCameraDistance = context.camera.distance
                let nextState = ProfileMapAnnotationZoomHelper.nextDetailState(
                        current: isShowingDetailedAnnotations,
                        distance: context.camera.distance,
                        region: context.region
                    )
                    if nextState != isShowingDetailedAnnotations {
                        isShowingDetailedAnnotations = nextState
                    }
                }

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.4), radius: 8)
                }
                .padding(.top, topInset - 25)
                .padding(.leading, 18)
            }
            .overlay(alignment: .bottom) {
                if displayMode == .all {
                    ProfileMapBottomSheet(
                        entries: entries,
                        profileUser: profileUser,
                        userProvider: userProvider,
                        sheetState: $sheetState,
                        filter: $filter,
                        onSelectEntry: { entry in
                            isListSelection = true
                            presentEntry(entry)
                        }
                    )
                } else {
                    timelineOverlay
                }
            }
            .overlay(alignment: .topTrailing) {
                modeToggle
                    .padding(.top, topInset - 25)
                    .padding(.trailing, 18)
            }
        }
        .background(Color.black)
        .onAppear {
            applyInitialTimelineFocusIfNeeded()
        }
        .sheet(isPresented: $isExperiencePresented, onDismiss: {
            experienceDetent = .fraction(0.25)
            isListSelection = false
            selectedEntryId = nil
        }) {
            experienceSheetContent
                .presentationDetents(detentsForSelection, selection: $experienceDetent)
                .presentationBackground(.thinMaterial)
                .presentationSizing(.fitted)
                .presentationCompactAdaptation(.none)
                .applyBackgroundInteractionIfAvailable()
        }
    }

    private var entries: [Entry] {
        let reelEntries = reels.map { real in
            Entry(id: real.id, timestamp: real.createdAt, kind: .real(real))
        }
        let poiEntries = footprints.map { footprint in
            Entry(
                id: footprint.id,
                timestamp: footprint.latestVisit ?? .distantPast,
                kind: .poi(footprint.ratedPOI)
            )
        }
        return (reelEntries + poiEntries)
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var detentsForSelection: Set<PresentationDetent> {
        if isListSelection {
            return [.large]
        }
        return [.fraction(0.25), .large]
    }

    private var sequenceItems: [ExperienceDetailView.SequencePager.Item] {
        entries.map { entry in
            switch entry.kind {
            case let .real(real):
                return ExperienceDetailView.SequencePager.Item(
                    id: entry.id,
                    mode: .real(real, userProvider(real.userId))
                )
            case let .poi(rated):
                return ExperienceDetailView.SequencePager.Item(
                    id: entry.id,
                    mode: .poi(rated)
                )
            }
        }
    }

    private var filteredReels: [RealPost] {
        switch filter {
        case .all, .reel:
            return reels
        case .poi:
            return []
        }
    }

    private var filteredPins: [ProfileViewModel.MapPin] {
        switch filter {
        case .all, .poi:
            return pins
        case .reel:
            return []
        }
    }

    private var activeTimelineSegment: TimelineSegment? {
        if let id = selectedTimelineSegmentId {
            return timelineSegments.first { $0.id == id }
        }
        return timelineSegments.first
    }

    private var activeReels: [RealPost] {
        switch displayMode {
        case .all:
            return filteredReels
        case .timeline:
            guard let segment = activeTimelineSegment else { return [] }
            return segment.events.compactMap { event in
                if case let .reel(real, _) = event.kind {
                    return reelsById[real.id] ?? real
                }
                return nil
            }
        }
    }

    private var activePins: [ProfileViewModel.MapPin] {
        switch displayMode {
        case .all:
            return filteredPins
        case .timeline:
            guard let segment = activeTimelineSegment else { return [] }
            return segment.events.compactMap { event in
                if case let .poi(rated) = event.kind {
                    return mapPinsById[rated.id]
                }
                return nil
            }
        }
    }

    private var reelsById: [UUID: RealPost] {
        Dictionary(uniqueKeysWithValues: reels.map { ($0.id, $0) })
    }

    private var mapPinsById: [UUID: ProfileViewModel.MapPin] {
        Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
    }

    private var timelineSegments: [TimelineSegment] {
        let reelEvents = reels.map { real in
            TimelineEvent(
                id: real.id,
                date: real.createdAt,
                coordinate: real.center,
                kind: .reel(real, userProvider(real.userId))
            )
        }

        let footprintEvents: [TimelineEvent] = footprints.compactMap { footprint in
            guard let visitDate = footprint.latestVisit else { return nil }
            return TimelineEvent(
                id: footprint.id,
                date: visitDate,
                coordinate: footprint.coordinate,
                kind: .poi(footprint.ratedPOI)
            )
        }

        let events = (reelEvents + footprintEvents).sorted { $0.date > $1.date }
        var segments: [TimelineSegment] = []
        for event in events {
            let label = cityResolver.label(for: event.coordinate, preferred: event.labelHint)
            if var last = segments.last, last.label == label {
                last.events.append(event)
                last.end = max(last.end, event.date)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TimelineSegment(
                        label: label,
                        start: event.date,
                        end: event.date,
                        events: [event]
                    )
                )
            }
        }
        return segments
    }

    private var modeToggle: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    displayMode = .all
                    selectedTimelineSegmentId = nil
                }
            } label: {
                Text("All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(displayMode == .all ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minWidth: 70)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(displayMode == .all ? Color.white : Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    displayMode = .timeline
                    if selectedTimelineSegmentId == nil {
                        selectedTimelineSegmentId = timelineSegments.first?.id
                    }
                }
            } label: {
                Text("Timeline")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(displayMode == .timeline ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minWidth: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(displayMode == .timeline ? Color.white : Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
    }

    private var timelineOverlay: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            PreviewTimelineAxis(
                segments: timelineSegments,
                selectedId: selectedTimelineSegmentId ?? timelineSegments.first?.id
            ) { segment in
                selectedTimelineSegmentId = segment.id
                flyToTimelineSegment(segment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 220)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    struct Entry: Identifiable {
        enum Kind {
            case real(RealPost)
            case poi(RatedPOI)
        }

        let id: UUID
        let timestamp: Date
        let kind: Kind
    }

    private func presentReal(_ real: RealPost) {
        guard let entry = entry(for: real) else { return }
        presentEntry(entry)
    }

    private func presentPin(_ pin: ProfileViewModel.MapPin) {
        guard let footprint = footprint(for: pin),
              let entry = entry(for: footprint) else { return }
        presentEntry(entry)
    }

    private func presentEntry(_ entry: Entry) {
        guard sequenceItems.isEmpty == false else { return }
        selectedEntryId = entry.id
        experienceDetent = isListSelection ? .large : .fraction(0.25)
        isExperiencePresented = true
        if isListSelection {
            flyToEntry(entry, cause: cause(for: entry), animated: false)
        }
    }

    private func flyToTimelineSegment(_ segment: TimelineSegment, animated: Bool = true) {
        let relatedEvents = timelineSegments
            .filter { $0.label == segment.label }
            .flatMap(\.events)
        guard let target = boundingTarget(for: relatedEvents, padding: timelinePaddingFactor) else { return }

        if let baseRegion = Optional(currentRegion),
           baseRegion.center.distance(to: target.region.center) > timelineTeleportThreshold {
            timelineEffectStyle = nil
            timelineEffectProgress = 0
            withTransaction(Transaction(animation: nil)) {
                cameraPosition = .region(target.region)
            }
            currentRegion = target.region
            lastCenter = target.region.center
            return
        }

        triggerVisualEffect(for: timelineAnimationStyle)

        let camera = MapCamera(
            centerCoordinate: target.region.center,
            distance: target.distance,
            heading: 0,
            pitch: 0
        )

        let animation = timelineAnimationStyle.animation
        let transaction = Transaction(animation: animated ? animation : nil)
        withTransaction(transaction) {
            cameraPosition = .camera(camera)
        }
        currentRegion = target.region
        lastCenter = target.region.center
    }

    @MainActor
    private func triggerVisualEffect(for style: TimelineAnimationStyle) {
        let effect = style.visualEffect
        timelineEffectStyle = effect

        guard effect != nil else {
            withAnimation(.easeOut(duration: 0.2)) {
                timelineEffectProgress = 0
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            timelineEffectProgress = 1
        }
        let hold: Double = 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            withAnimation(.easeOut(duration: 0.3)) {
                timelineEffectProgress = 0
            }
        }
    }

    private var currentVisualEffect: TimelineVisualEffect? {
        guard timelineEffectProgress > 0 else { return nil }
        return timelineEffectStyle
    }

    private var mapBlurEffect: CGFloat {
        guard let effect = currentVisualEffect else { return 0 }
        let progress = timelineEffectProgress
        switch effect {
        case .materialBlur:
            return CGFloat(10 * progress)
        case .dimmed:
            return CGFloat(6 * progress)
        }
    }

    private var mapSaturationEffect: Double {
        guard let effect = currentVisualEffect else { return 1 }
        switch effect {
        case .materialBlur:
            return 1 - (0.25 * timelineEffectProgress)
        case .dimmed:
            return 1 - (0.45 * timelineEffectProgress)
        }
    }

    private var timelineEffectOverlayOpacity: Double {
        max(0, min(1, timelineEffectProgress))
    }

    private var timelineEffectOverlay: some View {
        Group {
            switch currentVisualEffect {
            case .materialBlur:
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.06),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            case .dimmed:
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.3),
                        Color.black.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(
                    RadialGradient(
                        colors: [Theme.neonPrimary.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 40,
                        endRadius: 300
                    )
                    .blendMode(.screen)
                )
            case nil:
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .opacity(timelineEffectOverlayOpacity)
        .animation(.easeInOut(duration: 0.2), value: timelineEffectProgress)
    }

    private func entry(for real: RealPost) -> Entry? {
        entries.first { candidate in
            if case let .real(current) = candidate.kind {
                return current.id == real.id
            }
            return false
        }
    }

    private func entry(for footprint: ProfileViewModel.Footprint) -> Entry? {
        entries.first { candidate in
            if case let .poi(rated) = candidate.kind {
                return rated.id == footprint.id
            }
            return false
        }
    }

    private func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    private func applyInitialTimelineFocusIfNeeded() {
        guard displayMode == .timeline,
              didApplyInitialTimelineFocus == false,
              let segment = initialTimelineSegment else { return }
        if selectedTimelineSegmentId == nil {
            selectedTimelineSegmentId = segment.id
        }
        flyToTimelineSegment(segment, animated: false)
        didApplyInitialTimelineFocus = true
    }

    private var initialTimelineSegment: TimelineSegment? {
        if let id = selectedTimelineSegmentId,
           let segment = timelineSegments.first(where: { $0.id == id }) {
            return segment
        }
        return timelineSegments.first
    }

    private func flyToEntry(_ entry: Entry, cause: RegionChangeCause = .other, animated: Bool = true) {
        guard let target = targetRegion(for: entry) else { return }
        if animated {
            flightController.handleRegionChange(
                currentRegion: currentRegion,
                targetRegion: target,
                cause: cause,
                cameraPosition: $cameraPosition,
                onRegionUpdate: { updated in
                    currentRegion = updated
                    lastCenter = updated.center
                }
            )
        } else {
            cameraPosition = .region(target)
            currentRegion = target
            lastCenter = target.center
        }
    }

    private func targetRegion(for entry: Entry) -> MKCoordinateRegion? {
        let span = currentRegion.span
        switch entry.kind {
        case let .real(real):
            return MKCoordinateRegion(center: real.center, span: span)
        case let .poi(rated):
            return MKCoordinateRegion(center: rated.poi.coordinate, span: span)
        }
    }

    private func cause(for entry: Entry) -> RegionChangeCause {
        switch entry.kind {
        case .real:
            return .real
        case .poi:
            return .poi
        }
    }

    private func footprint(for pin: ProfileViewModel.MapPin) -> ProfileViewModel.Footprint? {
        footprints.first { $0.id == pin.id }
    }

    private func boundingTarget(for events: [TimelineEvent], padding: Double) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? {
        guard events.isEmpty == false else { return nil }

        var mapRect = MKMapRect.null
        for event in events {
            let point = MKMapPoint(event.coordinate)
            let radiusMeters: CLLocationDistance
            if case let .reel(real, _) = event.kind {
                radiusMeters = max(real.radiusMeters, 0)
            } else {
                radiusMeters = 0
            }
            let pointsRadius = radiusMeters * MKMapPointsPerMeterAtLatitude(event.coordinate.latitude)
            let eventRect = MKMapRect(
                origin: MKMapPoint(x: point.x - pointsRadius, y: point.y - pointsRadius),
                size: MKMapSize(width: pointsRadius * 2, height: pointsRadius * 2)
            )
            mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
        }

        // Ensure a minimum footprint so single points don't produce a zero-size rect.
        let centerPoint = MKMapPoint(x: mapRect.midX, y: mapRect.midY)
        let centerCoordinate = centerPoint.coordinate
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(centerCoordinate.latitude)
        let minSpanPoints = timelineMinSpanMeters * pointsPerMeter
        if mapRect.width < minSpanPoints || mapRect.height < minSpanPoints {
            let targetWidth = max(mapRect.width, minSpanPoints)
            let targetHeight = max(mapRect.height, minSpanPoints)
            mapRect = MKMapRect(
                x: centerPoint.x - targetWidth / 2,
                y: centerPoint.y - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            )
        }

        // Apply the existing padding factor plus a slight zoom-out buffer.
        let scale = max(padding * timelineZoomOutExtra, 1)
        let extraWidth = mapRect.width * (scale - 1) / 2
        let extraHeight = mapRect.height * (scale - 1) / 2
        mapRect = mapRect.insetBy(dx: -extraWidth, dy: -extraHeight)

        let screenSize = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
            .first ?? .zero
        let fallbackSize = screenSize == .zero ? CGSize(width: 430, height: 932) : screenSize
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: fallbackSize))
        let edgePadding = UIEdgeInsets(top: 60, left: 48, bottom: 220, right: 48)
        let fittedRect = mapView.mapRectThatFits(mapRect, edgePadding: edgePadding)
        let fittedRegion = MKCoordinateRegion(fittedRect)

        let spanMeters = ProfileMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
        let distance = max(spanMeters, timelineMinSpanMeters) * 1.5

        return (fittedRegion, distance)
    }

    @ViewBuilder
    private var experienceSheetContent: some View {
        let items = sequenceItems
        if items.isEmpty {
            EmptyView()
        } else {
            let pager = ExperienceDetailView.SequencePager(items: items)
            let selectionBinding = Binding<UUID>(
                get: { selectedEntryId ?? items.first!.id },
                set: { newValue in
                    selectedEntryId = newValue
                    if let entry = entry(for: newValue) {
                        let shouldAnimate = isListSelection ? false : (experienceDetent != .large)
                        flyToEntry(entry, cause: cause(for: entry), animated: shouldAnimate)
                    }
                }
            )

            ExperienceDetailView(
                sequencePager: pager,
                selection: selectionBinding,
                isExpanded: experienceDetent == .large,
                userProvider: userProvider
            )
        }
    }

    private func shouldShowDetail(for real: RealPost, now: Date) -> Bool {
        reelDisplayMode(for: real, now: now) == .thumbnail
    }

    private func reelDisplayMode(for real: RealPost, now: Date) -> ReelDisplayMode {
        let age = now.timeIntervalSince(real.createdAt)
        let reference = referenceDistance()

        if isShowingDetailedAnnotations == false {
            if reference <= ProfileMapAnnotationZoomHelper.detailRevealMeters {
                return .heart
            }
            return .dot
        }

        let isRecent = age <= 30 * 24 * 3600
        if isRecent {
            return .thumbnail
        }

        if ProfileMapAnnotationZoomHelper.isClose(
            distance: reference,
            region: currentRegion,
            threshold: ProfileMapAnnotationZoomHelper.oldReelRevealMeters
        ) {
            return .thumbnail
        }

        if ProfileMapAnnotationZoomHelper.isClose(
            distance: reference,
            region: currentRegion,
            threshold: ProfileMapAnnotationZoomHelper.detailRevealMeters
        ) {
            return .heart
        }

        return .dot
    }

    private func referenceDistance() -> CLLocationDistance {
        if let lastCameraDistance {
            return lastCameraDistance
        }
        return ProfileMapAnnotationZoomHelper.spanMeters(for: currentRegion)
    }

    private func safeAreaTopInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first?
            .safeAreaInsets.top ?? 0
    }
}

private enum MapSheetState {
    case collapsed
    case expanded
}

private enum MapDisplayMode {
    case all
    case timeline
}

private enum MapListFilter: String, CaseIterable {
    case all = "All"
    case poi = "POI"
    case reel = "Reel"
}

private struct ProfileMapBottomSheet: View {
    let entries: [ProfileMapDetailView.Entry]
    let profileUser: User
    let userProvider: (UUID) -> User?
    @Binding var sheetState: MapSheetState
    @Binding var filter: MapListFilter
    let onSelectEntry: (ProfileMapDetailView.Entry) -> Void
    @GestureState private var dragOffset: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var isFilterMenuPresented = false
    @State private var filterButtonFrame: CGRect = .zero
    @State private var dropdownSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let totalHeight = proxy.size.height
            let maxHeight = max(totalHeight, 320)
            let defaultPeek = max(totalHeight / 12, 72)
            let peekHeight = min(max(headerHeight, defaultPeek), maxHeight)
            let collapsedOffset = max(maxHeight - peekHeight, 0)
            let baseOffset = sheetState == .collapsed ? collapsedOffset : 0
            let rawOffset = baseOffset + dragOffset
            let offset = min(max(rawOffset, 0), collapsedOffset)

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 44, height: 5)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    HStack {
                        filterButton
                        Spacer()
                        Text("\(filteredEntries.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                .background(
                    GeometryReader { headerProxy in
                        Color.clear.preference(key: SheetHeaderHeightKey.self, value: headerProxy.size.height)
                    }
                )

                Divider().background(Color.white.opacity(0.12))

                if entries.isEmpty {
                    VStack(spacing: 6) {
                        Text("No posts yet")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                        Text("When this profile shares a post, it will show up here.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(filteredEntries) { entry in
                                Button {
                                    onSelectEntry(entry)
                                } label: {
                                    ProfileMapListCard(
                                        entry: entry,
                                        profileUser: profileUser,
                                        userProvider: userProvider
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: maxHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.black.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.4), radius: 20, y: -6)
            .offset(y: offset)
            .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.85), value: sheetState)
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        let threshold: CGFloat = 80
                        if value.translation.height < -threshold {
                            sheetState = .expanded
                        } else if value.translation.height > threshold {
                            sheetState = .collapsed
                        } else {
                            let currentOffset = baseOffset + value.translation.height
                            let midpoint = collapsedOffset / 2
                            sheetState = currentOffset > midpoint ? .collapsed : .expanded
                        }
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .onPreferenceChange(SheetHeaderHeightKey.self) { value in
            headerHeight = value
        }
        .coordinateSpace(name: "SheetArea")
        .overlay(alignment: .topLeading) {
            if isFilterMenuPresented {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                isFilterMenuPresented = false
                            }
                        }
                    filterDropdown
                        .padding(.leading, filterButtonFrame.minX)
                        .padding(.top, dropdownTopOffset)
                }
            }
        }
    }

    private var filteredEntries: [ProfileMapDetailView.Entry] {
        switch filter {
        case .all:
            return entries
        case .poi:
            return entries.filter {
                if case .poi = $0.kind { return true }
                return false
            }
        case .reel:
            return entries.filter {
                if case .real = $0.kind { return true }
                return false
            }
        }
    }

    private var filterButton: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                isFilterMenuPresented.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Posts • \(filter.rawValue)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Image(systemName: isFilterMenuPresented ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FilterButtonFrameKey.self,
                    value: proxy.frame(in: .named("SheetArea"))
                )
            }
        )
        .onPreferenceChange(FilterButtonFrameKey.self) { frame in
            filterButtonFrame = frame
        }
    }

    private var filterDropdown: some View {
        VStack(spacing: 0) {
            ForEach(MapListFilter.allCases, id: \.self) { option in
                Button {
                    filter = option
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        isFilterMenuPresented = false
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        if option == filter {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if option != MapListFilter.allCases.last {
                    Divider().background(Color.white.opacity(0.12))
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 6)
        .frame(width: dropdownWidth, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FilterDropdownSizeKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(FilterDropdownSizeKey.self) { size in
            if size != .zero {
                dropdownSize = size
            }
        }
    }

    private var dropdownTopOffset: CGFloat {
        let gap: CGFloat = 6
        if sheetState == .collapsed {
            let target = filterButtonFrame.minY - dropdownSize.height - gap
            return max(target, 0)
        }
        return filterButtonFrame.maxY + gap
    }

    private var dropdownWidth: CGFloat {
        let minWidth: CGFloat = 120
        return max(minWidth, filterButtonFrame.width + 12)
    }
}

private struct ProfileMapListCard: View {
    let entry: ProfileMapDetailView.Entry
    let profileUser: User
    let userProvider: (UUID) -> User?

    var body: some View {
        cardContent
            .background(cardBackground)
            .overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 12, y: 6)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch entry.kind {
        case let .real(real):
            CompactRealCard(
                real: real,
                user: userProvider(real.userId),
                style: .collapsed,
                displayNameOverride: nil,
                avatarCategory: nil,
                suppressContent: false,
                hideHeader: true
            )
        case let .poi(rated):
            ProfilePOICard(
                rated: rated,
                profileUser: profileUser,
                userProvider: userProvider
            )
        }
    }

    private var cardBackground: some View {
        let colors: [Color]
        switch entry.kind {
        case let .real(real):
            colors = gradient(for: real.visibility)
        case let .poi(rated):
            let accent = rated.poi.category.accentColor
            colors = [Color.black, accent.opacity(0.4)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                RadialGradient(
                    colors: [Color.white.opacity(0.08), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 260
                )
                .blendMode(.screen)
            }
    }

    private func gradient(for visibility: RealPost.Visibility) -> [Color] {
        switch visibility {
        case .publicAll:
            return [Color.black, Theme.neonPrimary.opacity(0.25)]
        case .friendsOnly:
            return [Color.black, Theme.neonAccent.opacity(0.25)]
        case .anonymous:
            return [Color.black, Theme.neonWarning.opacity(0.25)]
        }
    }

}

private struct SheetHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FilterButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct FilterDropdownSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct ProfilePOICard: View {
    let rated: RatedPOI
    let profileUser: User
    let userProvider: (UUID) -> User?

    @State private var isStoryViewerPresented = false
    @State private var storyStartIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                categoryBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(rated.poi.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(rated.poi.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                if hasStory {
                    storyAvatar
                }
            }

            HStack(spacing: 12) {
                statLabel(icon: "shoeprints.fill", value: rated.checkIns.count)
                statLabel(icon: "text.bubble.fill", value: rated.comments.count)
                statLabel(icon: "heart.fill", value: rated.favoritesCount)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    private var categoryBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: rated.poi.category.markerGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 38, height: 38)
                .rotationEffect(.degrees(45))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 38, height: 38)
                .rotationEffect(.degrees(45))
            Image(systemName: rated.poi.category.symbolName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
    }

    private var storyAvatar: some View {
        let size: CGFloat = 36
        let ringWidth: CGFloat = 2

        return Button {
            storyStartIndex = initialContributorIndex
            isStoryViewerPresented = true
        } label: {
            Group {
                if let url = currentUser.avatarURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .empty:
                            ProgressView()
                        default:
                            avatarFallback
                        }
                    }
                } else {
                    avatarFallback
                }
            }
            .frame(width: size - (ringWidth * 2), height: size - (ringWidth * 2))
            .clipShape(Circle())
            .overlay {
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
            .padding(ringWidth)
            .background(
                Circle()
                    .stroke(hasStory ? Color.gray.opacity(0.85) : Color.white.opacity(0.18), lineWidth: ringWidth)
            )
            .background(
                Circle()
                    .fill(Color.black.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .opacity(hasStory ? 1 : 0.65)
        .fullScreenCover(isPresented: $isStoryViewerPresented) {
            ExperienceDetailView.POIStoryViewer(
                contributors: storyContributors,
                initialIndex: storyStartIndex,
                accentColor: rated.poi.category.accentColor
            ) {
                isStoryViewerPresented = false
            }
        }
    }

    private var currentUser: User {
        userProvider(profileUser.id) ?? profileUser
    }

    private var initialContributorIndex: Int {
        if let index = storyContributors.firstIndex(where: { $0.userId == profileUser.id }) {
            return index
        }
        return 0
    }

    private var hasStory: Bool {
        storyContributors.isEmpty == false
    }

    private var storyContributors: [ExperienceDetailView.POIStoryContributor] {
        let mediaCheckIns = rated.checkIns.filter { checkIn in
            checkIn.media.contains(where: isStoryEligible)
        }
        if mediaCheckIns.isEmpty == false {
            let grouped = Dictionary(grouping: mediaCheckIns, by: { $0.userId })
            let contributors: [ExperienceDetailView.POIStoryContributor] = grouped.compactMap { userId, entries in
                let sortedEntries = entries.sorted { $0.createdAt < $1.createdAt }
                let items: [ExperienceDetailView.POIStoryContributor.Item] = sortedEntries.flatMap { checkIn in
                    checkIn.media.compactMap { media in
                        guard let displayItem = mediaDisplayItem(media) else { return nil }
                        return ExperienceDetailView.POIStoryContributor.Item(
                            id: media.id,
                            media: displayItem,
                            timestamp: checkIn.createdAt
                        )
                    }
                }
                guard items.isEmpty == false else { return nil }
                let mostRecent = sortedEntries.map(\.createdAt).max() ?? Date()
                return ExperienceDetailView.POIStoryContributor(
                    id: userId,
                    userId: userId,
                    user: userProvider(userId),
                    items: items,
                    mostRecent: mostRecent
                )
            }

            return contributors.sorted { $0.mostRecent > $1.mostRecent }
        }

        let mediaItems: [ExperienceDetailView.POIStoryContributor.Item] = rated.media.compactMap { media in
            guard let displayItem = mediaDisplayItem(media) else { return nil }
            return ExperienceDetailView.POIStoryContributor.Item(
                id: media.id,
                media: displayItem,
                timestamp: Date()
            )
        }
        guard mediaItems.isEmpty == false else { return [] }

        return [
            ExperienceDetailView.POIStoryContributor(
                id: profileUser.id,
                userId: profileUser.id,
                user: currentUser,
                items: mediaItems,
                mostRecent: Date()
            )
        ]
    }

    private func isStoryEligible(_ media: RatedPOI.Media) -> Bool {
        switch media.kind {
        case .photo, .video:
            return true
        }
    }

    private func mediaDisplayItem(_ media: RatedPOI.Media) -> ExperienceDetailView.MediaDisplayItem? {
        switch media.kind {
        case let .photo(url):
            return ExperienceDetailView.MediaDisplayItem(id: media.id, content: .photo(url))
        case let .video(url, poster):
            return ExperienceDetailView.MediaDisplayItem(id: media.id, content: .video(url: url, poster: poster))
        }
    }

    private var avatarFallback: some View {
        Text(String(profileUser.handle.prefix(2)).uppercased())
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.45))
    }

    private func statLabel(icon: String, value: Int) -> some View {
        Label("\(value)", systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
    }
}

private struct ProfileMapDotMarker: View {
    let category: POICategory

    var body: some View {
        let size: CGFloat = 9
        let dotColor = (category.markerGradientColors.first ?? category.accentColor).opacity(0.95)
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .overlay {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.0)
            }
    }
}

private struct ProfileMapReelDotMarker: View {
    var body: some View {
        let size: CGFloat = 9
        let dotColor = Color(red: 1.0, green: 0.35, blue: 0.62).opacity(0.95)
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .overlay {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.0)
            }
    }
}

private enum ReelDisplayMode {
    case dot
    case heart
    case thumbnail

    var priority: Int {
        switch self {
        case .dot: return 0
        case .heart: return 1
        case .thumbnail: return 2
        }
    }
}

private struct ProfileMapClusterMarker: View {
    let poiCount: Int
    let reelCount: Int

    var body: some View {
        VStack(spacing: 6) {
            if reelCount > 0 {
                clusterChip(
                    icon: "heart.fill",
                    color: Color.pink,
                    count: reelCount
                )
            }
            if poiCount > 0 {
                clusterChip(
                    icon: "circle.fill",
                    color: Color.white.opacity(0.9),
                    count: poiCount
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay {
            Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
    }

    private func clusterChip(icon: String, color: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }
}

private struct ProfileMapReelHeartMarker: View {
    var body: some View {
        let innerSize: CGFloat = 21
        let corePink = Color(red: 1.0, green: 0.35, blue: 0.62)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: innerSize, height: innerSize)
            Circle()
                .fill(corePink)
                .frame(width: innerSize, height: innerSize)
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct ProfileCollapsedReelMarker: View {
    let real: RealPost

    private var thumbnailURL: URL? {
        for attachment in real.attachments {
            switch attachment.kind {
            case let .photo(url):
                return url
            case let .video(_, poster):
                if let poster { return poster }
            case .emoji:
                continue
            }
        }
        return nil
    }

    var body: some View {
        let circleSize: CGFloat = 26
        let lineHeight: CGFloat = 20
        let totalHeight = circleSize + lineHeight

        VStack(spacing: 0) {
            if let url = thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView().scaleEffect(0.6)
                    default:
                        Color.gray.opacity(0.35)
                    }
                }
                .frame(width: circleSize, height: circleSize)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.4)
                }
                .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: circleSize, height: circleSize)
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.2)
                    }
            }

            Rectangle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 2, height: lineHeight)
                .cornerRadius(1)
        }
        // Anchor the bottom tip of the line at the map coordinate (push the stack up by half its height)
        .offset(y: -(totalHeight / 2))
    }
}

private struct ProfileMapMarker: View {
    let category: POICategory

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(markerGradient)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))
                .shadow(color: markerGlow.opacity(0.45), radius: 6, y: 2)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))
            Image(systemName: category.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var markerGradient: LinearGradient {
        LinearGradient(
            colors: category.markerGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var markerGlow: Color {
        category.markerGradientColors.last ?? category.accentColor
    }
}

private struct RoundedCorners: Shape {
    let corners: UIRectCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

private struct RealMapThumbnail: View {
    let real: RealPost
    let user: User?
    var size: CGFloat = 40

    private var mediaURL: URL? {
        for attachment in real.attachments {
            switch attachment.kind {
            case let .photo(url):
                return url
            case let .video(_, poster):
                if let poster { return poster }
            case .emoji:
                continue
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .overlay {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            if let url = mediaURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        avatarFallback
                    @unknown default:
                        avatarFallback
                    }
                }
                .clipShape(Circle())
            } else if let avatar = user?.avatarURL {
                AsyncImage(url: avatar) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        avatarFallback
                    @unknown default:
                        avatarFallback
                    }
                }
                .clipShape(Circle())
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary.opacity(0.7), lineWidth: 2)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 6, y: 3)
    }

    private var avatarFallback: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
            .clipShape(Circle())
    }

    private var initials: String {
        guard let handle = user?.handle else { return "PO" }
        return String(handle.prefix(2)).uppercased()
    }
}

// MARK: - Timeline helpers for preview card

private enum TimelineEventKind {
    case reel(RealPost, User?)
    case poi(RatedPOI)

    var priority: Int {
        switch self {
        case .reel: return 1
        case .poi: return 0
        }
    }
}

private struct TimelineEvent: Identifiable {
    let id: UUID
    let date: Date
    let coordinate: CLLocationCoordinate2D
    let kind: TimelineEventKind

    var labelHint: String? {
        switch kind {
        case let .reel(real, _):
            return PreviewData.locationLabel(for: real.id)
        case let .poi(rated):
            return PreviewData.locationLabel(for: rated.poi.id)
        }
    }
}

private struct TimelineSegment: Identifiable {
    // Deterministic ID so SwiftUI keeps image loading state stable while the map spins.
    var id: String { "\(label)-\(Int(start.timeIntervalSince1970))" }
    let label: String
    var start: Date
    var end: Date
    var events: [TimelineEvent]
}

private enum TimelineAnimationStyle: String, CaseIterable {
    case none = "No Animation"
    case smooth = "Smooth"
    case bouncy = "Bouncy"
    case snappy = "Snappy"
    case materialBlur = "Material Blur"
    case dimmed = "Dim & Desaturate"

    var title: String { rawValue }

    var animation: Animation? {
        switch self {
        case .none:
            return nil
        case .smooth:
            return .smooth(duration: 0.45)
        case .bouncy:
            return .bouncy(duration: 0.6, extraBounce: 0.24)
        case .snappy:
            return .snappy(duration: 0.35, extraBounce: 0.14)
        case .materialBlur:
            return .smooth(duration: 0.5)
        case .dimmed:
            return .smooth(duration: 0.45)
        }
    }

    var visualEffect: TimelineVisualEffect? {
        switch self {
        case .materialBlur:
            return .materialBlur
        case .dimmed:
            return .dimmed
        case .none, .smooth, .bouncy, .snappy:
            return nil
        }
    }
}

private enum TimelineVisualEffect {
    case materialBlur
    case dimmed
}

private struct PreviewTimelineAxis: View {
    let segments: [TimelineSegment]
    var selectedId: String?
    var onSelect: ((TimelineSegment) -> Void)?

    init(
        segments: [TimelineSegment],
        selectedId: String? = nil,
        onSelect: ((TimelineSegment) -> Void)? = nil
    ) {
        self.segments = segments
        self.selectedId = selectedId
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(segments.enumerated()), id: \.1.id) { index, segment in
                        let isLast = index == segments.count - 1
                        let isSelected = segment.id == selectedId
                        HStack(alignment: .center, spacing: 12) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.pink)
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
                                    }
                                Rectangle()
                                    .fill(Color.white.opacity(isLast ? 0 : 0.2))
                                    .frame(width: 2, height: isLast ? 0 : 32)
                            }
                            .frame(width: 18)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.white : Color.white)
                                Text(dateRangeText(for: segment))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.7))
                                avatarStack(for: segment)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(isSelected ? 0.08 : 0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(isSelected ? 0.25 : 0.1), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .id(segment.id)
                        .onTapGesture {
                            onSelect?(segment)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                guard let id = selectedId else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func avatarStack(for segment: TimelineSegment) -> some View {
        // Favor reels so their thumbnails surface even when POI visits dominate.
        let events = segment.events.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority {
                return lhs.kind.priority > rhs.kind.priority
            }
            return lhs.date > rhs.date
        }
        return HStack(spacing: -10) {
            ForEach(events) { event in
                avatar(for: event)
                    .frame(width: 34, height: 34)
            }
        }
    }

private func avatar(for event: TimelineEvent) -> some View {
    switch event.kind {
    case let .reel(real, user):
        return AnyView(
            RealMapThumbnail(real: real, user: user, size: 34)
            )
        case let .poi(poi):
            return AnyView(
                ProfileMapMarker(category: poi.poi.category)
                    .frame(width: 30, height: 33)
            )
    }
}

private func dateRangeText(for segment: TimelineSegment) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    if Calendar.current.isDate(segment.start, inSameDayAs: segment.end) {
        return formatter.string(from: segment.start)
        }
        return "\(formatter.string(from: segment.start)) - \(formatter.string(from: segment.end))"
    }
}

@MainActor
private final class TimelineCityResolver: ObservableObject {
    private var labels: [String: String] = [:]

    func label(for coordinate: CLLocationCoordinate2D, preferred: String? = nil) -> String {
        let key = Self.cacheKey(for: coordinate)
        if let cached = labels[key] {
            return cached
        }
        if let preferred, preferred.isEmpty == false {
            return preferred
        }
        return Self.fallbackLabel(for: coordinate)
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    private static func fallbackLabel(for coordinate: CLLocationCoordinate2D) -> String {
        let candidates: [(String, CLLocationCoordinate2D)] = [
            ("Xi'an, Shaanxi, China", .init(latitude: 34.341, longitude: 108.939)),
            ("Hangzhou, Zhejiang, China", .init(latitude: 30.274, longitude: 120.155)),
            ("Suzhou, Jiangsu, China", .init(latitude: 31.298, longitude: 120.583)),
            ("Seattle, Washington, USA", .init(latitude: 47.6062, longitude: -122.3321))
        ]

        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (String, CLLocationDistance)? = nil
        for candidate in candidates {
            let dist = current.distance(from: CLLocation(latitude: candidate.1.latitude, longitude: candidate.1.longitude))
            if best == nil || dist < best!.1 {
                best = (candidate.0, dist)
            }
        }

        if let best, best.1 < 600_000 {
            return best.0
        }
        return String(format: "Lat %.3f, Lon %.3f", coordinate.latitude, coordinate.longitude)
    }
}

private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let midY = rect.midY
        path.move(to: CGPoint(x: midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        path.addLine(to: CGPoint(x: midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: midY))
        path.closeSubpath()
        return path
    }
}

private func poiPreview(for rated: RatedPOI, size: CGFloat) -> some View {
    let shape = DiamondShape()
    let fillColor = (rated.poi.category.markerGradientColors.first ?? rated.poi.category.accentColor).opacity(0.9)

    return ZStack {
        fillColor
        ProfileMapMarker(category: rated.poi.category)
            .frame(width: size, height: size * 1.1)
    }
    .frame(width: size, height: size)
    .clipShape(shape)
    .overlay {
        shape.stroke(Color.white.opacity(0.85), lineWidth: 1)
    }
}

private enum ProfileMapAnnotationZoomHelper {
    static let detailRevealMeters: CLLocationDistance = 500_0000
    static let oldReelRevealMeters: CLLocationDistance = 80_000

    static func isClose(distance: CLLocationDistance?) -> Bool {
        guard let distance else { return false }
        return distance <= detailRevealMeters
    }

    static func isClose(region: MKCoordinateRegion) -> Bool {
        maxSpanMeters(for: region) <= detailRevealMeters
    }

    static func isClose(
        distance: CLLocationDistance?,
        region: MKCoordinateRegion,
        threshold: CLLocationDistance
    ) -> Bool {
        let span = maxSpanMeters(for: region)
        let reference = distance ?? span
        return reference <= threshold
    }

    static func spanMeters(for region: MKCoordinateRegion) -> CLLocationDistance {
        maxSpanMeters(for: region)
    }

    static func nextDetailState(
        current: Bool,
        distance: CLLocationDistance?,
        region: MKCoordinateRegion
    ) -> Bool {
        let span = maxSpanMeters(for: region)
        let reference = distance ?? span
        return reference <= detailRevealMeters
    }

    private static func maxSpanMeters(for region: MKCoordinateRegion) -> CLLocationDistance {
        let center = region.center
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2

        let west = CLLocation(latitude: center.latitude, longitude: center.longitude - halfLon)
        let east = CLLocation(latitude: center.latitude, longitude: center.longitude + halfLon)
        let horizontal = west.distance(from: east)

        let north = CLLocation(latitude: center.latitude + halfLat, longitude: center.longitude)
        let south = CLLocation(latitude: center.latitude - halfLat, longitude: center.longitude)
        let vertical = north.distance(from: south)

        return max(horizontal, vertical)
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

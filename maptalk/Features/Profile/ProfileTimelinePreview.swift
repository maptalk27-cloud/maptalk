import MapKit
import SwiftUI

struct ProfileTimelinePreview: View {
    let pins: [ProfileViewModel.MapPin]
    let footprints: [ProfileViewModel.Footprint]
    let reels: [RealPost]
    let region: MKCoordinateRegion
    let selectedSegmentId: Binding<String?>?
    let onSelectSegment: ((TimelineSegment?) -> Void)?
    let userProvider: (UUID) -> User?
    let onOpenDetail: ((TimelineSegment?) -> Void)?
    let autoPlayEnabled: Bool

    @State private var cameraPosition: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedTimelineSegmentId: String?
    @StateObject private var cityResolver = TimelineCityResolver()
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var autoAdvanceProgress: Double = 0
    @State private var autoAdvanceElapsed: TimeInterval = 0
    @State private var autoPauseReasons: Set<AutoPauseReason> = []
    @State private var autoLastTick: Date = Date()
    @State private var lastAutoPlayEnabled: Bool

    private let paddingFactor: Double = 1.5
    private let minSpanMeters: Double = 1_200
    private let zoomOutExtra: Double = 1.2
    private let teleportThreshold: CLLocationDistance = 1_000_000
    private let quickHopThreshold: CLLocationDistance = 500_000
    private let autoAdvanceDuration: TimeInterval = 6
    private let autoAdvanceTick: UInt64 = 50_000_000

    init(
        pins: [ProfileViewModel.MapPin],
        footprints: [ProfileViewModel.Footprint],
        reels: [RealPost],
        region: MKCoordinateRegion,
        selectedSegmentId: Binding<String?>? = nil,
        onSelectSegment: ((TimelineSegment?) -> Void)? = nil,
        userProvider: @escaping (UUID) -> User?,
        onOpenDetail: ((TimelineSegment?) -> Void)? = nil,
        autoPlayEnabled: Bool = true
    ) {
        self.pins = pins
        self.footprints = footprints
        self.reels = reels
        self.region = region
        self.selectedSegmentId = selectedSegmentId
        self.onSelectSegment = onSelectSegment
        self.userProvider = userProvider
        self.onOpenDetail = onOpenDetail
        self.autoPlayEnabled = autoPlayEnabled
        _cameraPosition = State(initialValue: .region(region))
        _currentRegion = State(initialValue: region)
        _selectedTimelineSegmentId = State(initialValue: selectedSegmentId?.wrappedValue)
        _lastAutoPlayEnabled = State(initialValue: autoPlayEnabled)
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
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    pauseAutoAdvance(reason: .detail)
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
                    onSelectSegment?(activeTimelineSegment)
                    if let first = timelineSegments.first {
                        flyToSegment(first, animated: false)
                    }
                }
                updateAutoPlayEnabledState()
                startAutoAdvanceLoopIfNeeded()
            }
            .onDisappear {
                autoAdvanceTask?.cancel()
                autoAdvanceTask = nil
            }

            PreviewTimelineAxis(
                segments: timelineSegments,
                selectedId: selectedTimelineSegmentId,
                selectedProgress: autoAdvanceProgress,
                onSelect: { segment in
                    selectedTimelineSegmentId = segment.id
                    onSelectSegment?(segment)
                    flyToSegment(segment)
                    resetAutoAdvanceProgress()
                    startAutoAdvanceLoopIfNeeded()
                },
                onScrollStateChange: { isScrolling in
                    if isScrolling {
                        pauseAutoAdvance(reason: .userScroll)
                    } else {
                        resumeAutoAdvance(reason: .userScroll)
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: selectedSegmentId?.wrappedValue, initial: false) { _, newValue in
            guard let newValue, newValue != selectedTimelineSegmentId else { return }
            selectedTimelineSegmentId = newValue
            if let segment = timelineSegments.first(where: { $0.id == newValue }) {
                flyToSegment(segment)
            }
            resetAutoAdvanceProgress()
        }
        .onChange(of: selectedTimelineSegmentId, initial: false) { _, newValue in
            onSelectSegment?(activeTimelineSegment)
            selectedSegmentId?.wrappedValue = newValue
            resetAutoAdvanceProgress()
        }
        .onChange(of: autoPlayEnabled, initial: false) { oldValue, newValue in
            handleAutoPlayChange(from: oldValue, to: newValue)
        }
        .onChange(of: timelineSegments.map(\.id), initial: false) { _, _ in
            resetAutoAdvanceProgress()
            startAutoAdvanceLoopIfNeeded()
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

    private func startAutoAdvanceLoopIfNeeded() {
        guard autoAdvanceTask == nil else { return }
        autoAdvanceTask = Task { @MainActor in
            autoAdvanceElapsed = 0
            autoAdvanceProgress = 0
            autoLastTick = Date()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: autoAdvanceTick)
                } catch {
                    break
                }

                guard autoPauseReasons.isEmpty else {
                    autoLastTick = Date()
                    continue
                }
                guard timelineSegments.count > 1 else {
                    autoAdvanceProgress = 0
                    autoAdvanceElapsed = 0
                    autoLastTick = Date()
                    continue
                }

                let now = Date()
                autoAdvanceElapsed += now.timeIntervalSince(autoLastTick)
                autoLastTick = now

                autoAdvanceProgress = min(1, autoAdvanceElapsed / autoAdvanceDuration)

                if autoAdvanceProgress >= 1 {
                    autoAdvanceProgress = 0
                    autoAdvanceElapsed = 0
                    autoLastTick = Date()
                    advanceToNextSegment()
                }
            }
        }
    }

    private func resetAutoAdvanceProgress() {
        autoAdvanceElapsed = 0
        autoAdvanceProgress = 0
        autoLastTick = Date()
    }

    private func pauseAutoAdvance(reason: AutoPauseReason) {
        autoPauseReasons.insert(reason)
    }

    private func resumeAutoAdvance(reason: AutoPauseReason) {
        autoPauseReasons.remove(reason)
        if autoPauseReasons.isEmpty {
            startAutoAdvanceLoopIfNeeded()
        }
    }

    private func updateAutoPlayEnabledState() {
        if autoPlayEnabled == false {
            pauseAutoAdvance(reason: .external)
            pauseAutoAdvance(reason: .detail)
        }
        lastAutoPlayEnabled = autoPlayEnabled
    }

    private func handleAutoPlayChange(from old: Bool?, to new: Bool) {
        let previous = old ?? lastAutoPlayEnabled
        lastAutoPlayEnabled = new

        if previous == new { return }

        if new == false {
            pauseAutoAdvance(reason: .external)
            pauseAutoAdvance(reason: .detail)
            return
        }

        autoPauseReasons.remove(.detail)
        autoPauseReasons.remove(.external)
        resetAutoAdvanceProgress()
        startAutoAdvanceLoopIfNeeded()
    }

    private func advanceToNextSegment() {
        guard let next = nextSegment(after: selectedTimelineSegmentId, in: timelineSegments) else { return }
        selectedTimelineSegmentId = next.id
        onSelectSegment?(next)
        flyToSegment(next)
    }

    private func nextSegment(after id: String?, in segments: [TimelineSegment]) -> TimelineSegment? {
        guard let id, let index = segments.firstIndex(where: { $0.id == id }) else {
            return segments.first
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

private enum AutoPauseReason: Hashable {
    case userScroll
    case detail
    case external
}

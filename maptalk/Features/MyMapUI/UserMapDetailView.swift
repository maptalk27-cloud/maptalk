import MapKit
import SwiftUI
import UIKit

struct UserMapDetailView: View {
    let pins: [UserMapViewModel.MapPin]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let mapUser: User
    let region: MKCoordinateRegion
    let userProvider: (UUID) -> User?
    let onDismiss: () -> Void
    let onSelectSegment: ((String?) -> Void)?
    let onDismissWithSegment: ((String?) -> Void)?
    let selectedSegmentId: Binding<String?>?
    let showsCloseButton: Bool

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
    @State private var didApplyInitialDetailFit = false
    @State private var mapSize: CGSize = .zero
    @State private var overlayHeight: CGFloat = 0
    private let timelineAnimationStyle: TimelineAnimationStyle = .smooth
    private let timelineMinSpanMeters: Double = 36_000
    private let longHopThreshold: CLLocationDistance = 804_672 // ~500 miles

    init(
        pins: [UserMapViewModel.MapPin],
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        mapUser: User,
        region: MKCoordinateRegion,
        userProvider: @escaping (UUID) -> User?,
        onDismiss: @escaping () -> Void,
        selectedSegmentId: Binding<String?>? = nil,
        onSelectSegment: ((String?) -> Void)? = nil,
        onDismissWithSegment: ((String?) -> Void)? = nil,
        initialDisplayMode: MapDisplayMode = .timeline,
        initialTimelineSegmentId: String? = nil,
        showsCloseButton: Bool = true
    ) {
        self.pins = pins
        self.reels = reels
        self.footprints = footprints
        self.mapUser = mapUser
        self.region = region
        self.userProvider = userProvider
        self.onDismiss = onDismiss
        self.selectedSegmentId = selectedSegmentId
        self.onSelectSegment = onSelectSegment
        self.onDismissWithSegment = onDismissWithSegment
        self.showsCloseButton = showsCloseButton
        _cameraPosition = State(initialValue: .region(region))
        _lastCenter = State(initialValue: region.center)
        _currentRegion = State(initialValue: region)
        _isShowingDetailedAnnotations = State(initialValue: UserMapAnnotationZoomHelper.isClose(region: region))
        _displayMode = State(initialValue: initialDisplayMode)
        _selectedTimelineSegmentId = State(initialValue: initialTimelineSegmentId ?? selectedSegmentId?.wrappedValue)
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = max(proxy.safeAreaInsets.top, safeAreaTopInset())
            let topOffset = max(topInset - 25, 12)
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
                                    UserMapReelHeartMarker()
                                case .dot:
                                    UserMapReelDotMarker()
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
                                    UserMapMarker(category: pin.category)
                                } else {
                                    UserMapDotMarker(category: pin.category)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
            .ignoresSafeArea()
            .mapStyle(.standard)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { mapSize = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in mapSize = newValue }
                }
            )
            .saturation(mapSaturationEffect)
            .blur(radius: mapBlurEffect)
            .overlay(timelineEffectOverlay)
            .onMapCameraChange(frequency: .continuous) { context in
                lastCenter = context.region.center
                currentRegion = context.region
                lastCameraDistance = context.camera.distance
                let nextState = UserMapAnnotationZoomHelper.nextDetailState(
                        current: isShowingDetailedAnnotations,
                        distance: context.camera.distance,
                        region: context.region
                    )
                    if nextState != isShowingDetailedAnnotations {
                        isShowingDetailedAnnotations = nextState
                    }
                }

                if showsCloseButton {
                    Button {
                        onDismissWithSegment?(selectedTimelineSegmentId ?? timelineSegments.first?.id)
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
                    .padding(.top, topOffset)
                    .padding(.leading, 18)
                }
            }
            .overlay(alignment: .bottom) {
                if displayMode == .all {
                    UserMapBottomSheet(
                        entries: entries,
                        mapUser: mapUser,
                        userProvider: userProvider,
                        sheetState: $sheetState,
                        filter: $filter,
                        onSelectEntry: { entry in
                            isListSelection = true
                            presentEntry(entry)
                        }
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { updateOverlayHeight(proxy: proxy) }
                                .onChange(of: proxy.size) { _, _ in updateOverlayHeight(proxy: proxy) }
                        }
                    )
                } else {
                    timelineOverlay
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { updateOverlayHeight(proxy: proxy) }
                                    .onChange(of: proxy.size) { _, _ in updateOverlayHeight(proxy: proxy) }
                            }
                        )
                }
            }
            .overlay(alignment: .topTrailing) {
                modeToggle
                    .padding(.top, topOffset)
                    .padding(.trailing, 18)
            }
        }
        .background(Color.black)
        .onAppear {
            applyInitialTimelineFocusIfNeeded()
            applyInitialDetailFitIfNeeded()
        }
        .onChange(of: selectedSegmentId?.wrappedValue) { _, newValue in
            guard let newValue, newValue != selectedTimelineSegmentId else { return }
            setSelectedTimelineSegment(newValue)
        }
        .onChange(of: overlayHeight) { _, _ in
            applyInitialDetailFitIfNeeded()
        }
        .onDisappear {
            onDismissWithSegment?(selectedTimelineSegmentId ?? timelineSegments.first?.id)
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

    private var filteredPins: [UserMapViewModel.MapPin] {
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

    private var activePins: [UserMapViewModel.MapPin] {
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

    private var mapPinsById: [UUID: UserMapViewModel.MapPin] {
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
                    setSelectedTimelineSegment(nil)
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
                        setSelectedTimelineSegment(timelineSegments.first?.id)
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
                .padding(.top, 4)

            PreviewTimelineAxis(
                segments: timelineSegments,
                selectedId: selectedTimelineSegmentId ?? timelineSegments.first?.id
            ) { segment in
                setSelectedTimelineSegment(segment.id)
                flyToTimelineSegment(segment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 230)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .padding(.horizontal, 8)
        .padding(.bottom, -8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .ignoresSafeArea(edges: [.bottom, .horizontal])
        )
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

    private func presentPin(_ pin: UserMapViewModel.MapPin) {
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
        let target = boundingTarget(for: segment.events)
            ?? (region, max(UserMapAnnotationZoomHelper.spanMeters(for: region), timelineMinSpanMeters))

        let camera = MapCamera(
            centerCoordinate: target.region.center,
            distance: target.distance,
            heading: 0,
            pitch: 0
        )

        let travelDistance = currentRegion.center.distance(to: target.region.center)
        if animated {
            if travelDistance > longHopThreshold {
                withTransaction(Transaction(animation: nil)) {
                    cameraPosition = .camera(camera)
                }
            } else {
                withAnimation(.linear(duration: 0.35)) {
                    cameraPosition = .camera(camera)
                }
            }
        } else {
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

    private func entry(for footprint: UserMapViewModel.Footprint) -> Entry? {
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
            setSelectedTimelineSegment(segment.id)
        }
        flyToTimelineSegment(segment, animated: false)
        didApplyInitialTimelineFocus = true
    }

    private func applyInitialDetailFitIfNeeded() {
        guard displayMode == .timeline,
              didApplyInitialDetailFit == false,
              overlayHeight > 0,
              let segment = initialTimelineSegment else { return }
        flyToTimelineSegment(segment, animated: false)
        didApplyInitialDetailFit = true
    }

    private var initialTimelineSegment: TimelineSegment? {
        if let id = selectedTimelineSegmentId,
           let segment = timelineSegments.first(where: { $0.id == id }) {
            return segment
        }
        return timelineSegments.first
    }

    private func setSelectedTimelineSegment(_ id: String?) {
        selectedTimelineSegmentId = id
        onSelectSegment?(id)
        selectedSegmentId?.wrappedValue = id
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

    private func updateOverlayHeight(proxy: GeometryProxy) {
        let measured = proxy.size.height + proxy.safeAreaInsets.bottom
        if abs(measured - overlayHeight) > 1 {
            overlayHeight = measured
        }
    }

    private func boundingTarget(for events: [TimelineEvent]) -> (region: MKCoordinateRegion, distance: CLLocationDistance)? {
        guard events.isEmpty == false else { return nil }

        if events.count == 1, let coordinate = events.first?.coordinate {
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: timelineMinSpanMeters,
                longitudinalMeters: timelineMinSpanMeters
            )
            return (region, timelineMinSpanMeters)
        }

        var mapRect = MKMapRect.null
        for event in events {
            let point = MKMapPoint(event.coordinate)
            let eventRect = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
            mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
        }

        let screenSize = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
            .first ?? .zero
        let fallbackSize = screenSize == .zero ? CGSize(width: 430, height: 932) : screenSize
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let baseSize = mapSize == .zero
            ? ((window?.bounds.size ?? .zero) == .zero ? fallbackSize : (window?.bounds.size ?? fallbackSize))
            : mapSize
        let overlay = overlayHeight > 0 ? overlayHeight : (window?.safeAreaInsets.bottom ?? 0)
        let targetSize = baseSize
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: targetSize))
        let edgePadding = UIEdgeInsets(top: 36, left: 40, bottom: 36 + overlay, right: 40)
        let fittedRect = mapView.mapRectThatFits(mapRect, edgePadding: edgePadding)
        let fittedRegion = MKCoordinateRegion(fittedRect)

        let spanMeters = UserMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
        let multiplier: Double = events.count == 2 ? 3.4 : 2.2
        let distance = max(spanMeters * multiplier, timelineMinSpanMeters)

        return (fittedRegion, distance)
    }

    private func footprint(for pin: UserMapViewModel.MapPin) -> UserMapViewModel.Footprint? {
        footprints.first { $0.id == pin.id }
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
            if reference <= UserMapAnnotationZoomHelper.detailRevealMeters {
                return .heart
            }
            return .dot
        }

        let isRecent = age <= 30 * 24 * 3600
        if isRecent {
            return .thumbnail
        }

        if UserMapAnnotationZoomHelper.isClose(
            distance: reference,
            region: currentRegion,
            threshold: UserMapAnnotationZoomHelper.oldReelRevealMeters
        ) {
            return .thumbnail
        }

        if UserMapAnnotationZoomHelper.isClose(
            distance: reference,
            region: currentRegion,
            threshold: UserMapAnnotationZoomHelper.detailRevealMeters
        ) {
            return .heart
        }

        return .dot
    }

    private func referenceDistance() -> CLLocationDistance {
        if let lastCameraDistance {
            return lastCameraDistance
        }
        return UserMapAnnotationZoomHelper.spanMeters(for: currentRegion)
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

enum MapDisplayMode {
    case all
    case timeline
}

private enum MapListFilter: String, CaseIterable {
    case all = "All"
    case poi = "POI"
    case reel = "Reel"
}

private struct UserMapBottomSheet: View {
    let entries: [UserMapDetailView.Entry]
    let mapUser: User
    let userProvider: (UUID) -> User?
    @Binding var sheetState: MapSheetState
    @Binding var filter: MapListFilter
    let onSelectEntry: (UserMapDetailView.Entry) -> Void
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
                                    UserMapListCard(
                                        entry: entry,
                                        mapUser: mapUser,
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

    private var filteredEntries: [UserMapDetailView.Entry] {
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

private struct UserMapListCard: View {
    let entry: UserMapDetailView.Entry
    let mapUser: User
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
                userProvider: userProvider,
                suppressContent: false,
                hideHeader: true
            )
        case let .poi(rated):
            UserMapPOICard(
                rated: rated,
                mapUser: mapUser,
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

private struct UserMapPOICard: View {
    let rated: RatedPOI
    let mapUser: User
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
        userProvider(mapUser.id) ?? mapUser
    }

    private var initialContributorIndex: Int {
        if let index = storyContributors.firstIndex(where: { $0.userId == mapUser.id }) {
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
                id: mapUser.id,
                userId: mapUser.id,
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
            return ExperienceDetailView.MediaDisplayItem(
                id: media.id,
                content: .video(url: url, poster: poster, metadata: nil)
            )
        }
    }

    private var avatarFallback: some View {
        Text(String(mapUser.handle.prefix(2)).uppercased())
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

struct UserMapDotMarker: View {
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

private struct UserMapReelDotMarker: View {
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

private struct UserMapClusterMarker: View {
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

private struct UserMapReelHeartMarker: View {
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

struct UserMapCollapsedReelMarker: View {
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

// UserMapMarker and RealMapThumbnail moved to UserMapTimelineShared.swift for reuse.

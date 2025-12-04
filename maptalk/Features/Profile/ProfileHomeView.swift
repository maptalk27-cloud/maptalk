import MapKit
import SwiftUI
import UIKit

struct ProfileHomeView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMapDetail = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = safeAreaTop()
            let heroHeightHint = proxy.size.height * 0.42
            let horizontalPadding: CGFloat = 8
            let safeWidth = proxy.size.width.isFinite ? proxy.size.width : 0
            let safeHeight = proxy.size.height.isFinite ? proxy.size.height : 0
            let availableWidth = max(0, safeWidth - (horizontalPadding * 2))
            let mapHeight = max(1, min(availableWidth, safeHeight * 0.55))

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

                    Button {
                        isShowingMapDetail = true
                    } label: {
                        ProfileMapPreview(
                            pins: viewModel.mapPins,
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
                onDismiss: { isShowingMapDetail = false }
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
    let reels: [RealPost]
    let region: MKCoordinateRegion
    let isActive: Bool

    @State private var cameraPosition: MapCameraPosition
    @State private var spinLongitude: CLLocationDegrees
    @State private var spinPhase: SpinPhase = .north
    @State private var ticksRemaining: Int = 0
    @State private var phaseTicksTotal: Int = 0

    private let spinLatitude: CLLocationDegrees
    private let globeDistance: CLLocationDistance = 20_000_000
    private let spinDuration: TimeInterval = 20
    private let spinFrameInterval: TimeInterval = 1.0 / 60.0
    private let transitionDuration: TimeInterval = 3.5
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
        reels: [RealPost],
        region: MKCoordinateRegion,
        isActive: Bool
    ) {
        self.pins = pins
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

private struct ProfileMapDetailView: View {
    let pins: [ProfileViewModel.MapPin]
    let reels: [RealPost]
    let footprints: [ProfileViewModel.Footprint]
    let profileUser: User
    let region: MKCoordinateRegion
    let userProvider: (UUID) -> User?
    let onDismiss: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var isGlobeView: Bool = false
    @State private var lastCenter: CLLocationCoordinate2D
    @State private var sheetState: MapSheetState = .collapsed
    @State private var filter: MapListFilter = .all
    @State private var isShowingDetailedAnnotations: Bool
    private let globeDistance: CLLocationDistance = 20_000_000

    init(
        pins: [ProfileViewModel.MapPin],
        reels: [RealPost],
        footprints: [ProfileViewModel.Footprint],
        profileUser: User,
        region: MKCoordinateRegion,
        userProvider: @escaping (UUID) -> User?,
        onDismiss: @escaping () -> Void
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
        _isShowingDetailedAnnotations = State(initialValue: ProfileMapAnnotationZoomHelper.isClose(region: region))
    }

    var body: some View {
        GeometryReader { _ in
            let topInset = safeAreaTopInset()
            ZStack(alignment: .topLeading) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    ForEach(filteredReels) { real in
                        if isShowingDetailedAnnotations {
                            MapCircle(center: real.center, radius: real.radiusMeters)
                                .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                                .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                        }
                        Annotation("", coordinate: real.center) {
                            if isShowingDetailedAnnotations {
                                RealMapThumbnail(real: real, user: userProvider(real.userId), size: 44)
                            } else {
                                ProfileMapReelHeartMarker()
                            }
                        }
                    }
                    ForEach(filteredPins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            if isShowingDetailedAnnotations {
                                ProfileMapMarker(category: pin.category)
                            } else {
                                ProfileMapDotMarker(category: pin.category)
                            }
                        }
                    }
                }
                .ignoresSafeArea()
                .mapStyle(activeMapStyle)
                .onMapCameraChange(frequency: .continuous) { context in
                    lastCenter = context.region.center
                    let shouldShowDetails = ProfileMapAnnotationZoomHelper.isClose(region: context.region)
                    if shouldShowDetails != isShowingDetailedAnnotations {
                        isShowingDetailedAnnotations = shouldShowDetails
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
                ProfileMapBottomSheet(
                    entries: entries,
                    profileUser: profileUser,
                    userProvider: userProvider,
                    sheetState: $sheetState,
                    filter: $filter
                )
            }
            .overlay(alignment: .topTrailing) {
                globeToggle
                    .padding(.top, topInset - 25)
                    .padding(.trailing, 18)
            }
        }
        .background(Color.black)
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

    private var activeMapStyle: MapStyle {
        if isGlobeView {
            return globeStyle
        }
        return .standard
    }

    private var globeStyle: MapStyle {
        if #available(iOS 17.0, *) {
            return .hybrid(elevation: .realistic)
        }
        return .standard
    }

    private var globeToggle: some View {
        Button {
            toggleMapMode()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isGlobeView ? "globe.americas.fill" : "map.fill")
                    .font(.subheadline.weight(.bold))
                Text(isGlobeView ? "Globe" : "Map")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleMapMode() {
        isGlobeView.toggle()
        let center = lastCenter
        if isGlobeView {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: globeDistance,
                    heading: 0,
                    pitch: 0
                )
            )
        } else {
            cameraPosition = .region(
                MKCoordinateRegion(center: center, span: region.span)
            )
        }
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
                                ProfileMapListCard(
                                    entry: entry,
                                    profileUser: profileUser,
                                    userProvider: userProvider
                                )
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
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.6)
            }
            .shadow(color: dotColor.opacity(0.6), radius: 4, y: 1.5)
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
        let glowSize: CGFloat = 25
        let corePink = Color(red: 1.0, green: 0.35, blue: 0.62)
        ZStack {
            Circle()
                .fill(corePink)
                .frame(width: innerSize, height: innerSize)
            Circle()
                .stroke(corePink.opacity(0.65), lineWidth: 3)
                .frame(width: glowSize, height: glowSize)
                .blur(radius: 5)
                .opacity(0.9)
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(color: corePink.opacity(0.5), radius: 8, y: 3)
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

private enum ProfileMapAnnotationZoomHelper {
    private static let detailRevealMeters: CLLocationDistance = 500_0000

    static func isClose(distance: CLLocationDistance?) -> Bool {
        guard let distance else { return false }
        return distance <= detailRevealMeters
    }

    static func isClose(region: MKCoordinateRegion) -> Bool {
        maxSpanMeters(for: region) <= detailRevealMeters
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

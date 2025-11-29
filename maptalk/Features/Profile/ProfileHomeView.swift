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
            let heroHeightHint = proxy.size.height * 0.45
            let mapHeight = min(220, proxy.size.height * 0.3)

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
                            region: viewModel.mapRegion
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: mapHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)

                    ProfileWideButton(title: "Message")
                        .padding(.horizontal, 24)
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
                            ProfileStatChip(title: "Spots", value: summary.footprintCount)
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

    @State private var cameraPosition: MapCameraPosition

    init(pins: [ProfileViewModel.MapPin], reels: [RealPost], region: MKCoordinateRegion) {
        self.pins = pins
        self.reels = reels
        self.region = region
        _cameraPosition = State(initialValue: .region(region))
    }

    var body: some View {
        Map(position: $cameraPosition, interactionModes: []) {
            ForEach(reels) { real in
                MapCircle(center: real.center, radius: real.radiusMeters)
                    .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                    .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
            }
            ForEach(pins) { pin in
                Annotation("", coordinate: pin.coordinate) {
                    ProfileMapMarker(category: pin.category)
                }
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 10)
    }
}

private struct ProfileMapDetailView: View {
    let pins: [ProfileViewModel.MapPin]
    let reels: [RealPost]
    let footprints: [ProfileViewModel.Footprint]
    let region: MKCoordinateRegion
    let userProvider: (UUID) -> User?
    let onDismiss: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var sheetState: MapSheetState = .collapsed

    init(
        pins: [ProfileViewModel.MapPin],
        reels: [RealPost],
        footprints: [ProfileViewModel.Footprint],
        region: MKCoordinateRegion,
        userProvider: @escaping (UUID) -> User?,
        onDismiss: @escaping () -> Void
    ) {
        self.pins = pins
        self.reels = reels
        self.footprints = footprints
        self.region = region
        self.userProvider = userProvider
        self.onDismiss = onDismiss
        _cameraPosition = State(initialValue: .region(region))
    }

    var body: some View {
        GeometryReader { _ in
            let topInset = safeAreaTopInset()
            ZStack(alignment: .topLeading) {
                Map(position: $cameraPosition, interactionModes: .all) {
                    ForEach(reels) { real in
                        MapCircle(center: real.center, radius: real.radiusMeters)
                            .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                            .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                    }
                    ForEach(pins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            ProfileMapMarker(category: pin.category)
                        }
                    }
                }
                .ignoresSafeArea()

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
                .padding(.top, topInset + 12)
                .padding(.leading, 18)
            }
            .overlay(alignment: .bottom) {
                ProfileMapBottomSheet(entries: entries, userProvider: userProvider, sheetState: $sheetState)
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

private struct ProfileMapBottomSheet: View {
    let entries: [ProfileMapDetailView.Entry]
    let userProvider: (UUID) -> User?
    @Binding var sheetState: MapSheetState
    @GestureState private var dragOffset: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

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
                        Text("Posts")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(entries.count)")
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
                        VStack(spacing: 8) {
                            ForEach(entries) { entry in
                                ProfileMapListCard(entry: entry, userProvider: userProvider)
                                    .padding(.horizontal, 16)
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 20)
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
    }
}

private struct ProfileMapListCard: View {
    let entry: ProfileMapDetailView.Entry
    let userProvider: (UUID) -> User?

    var body: some View {
        cardContent
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
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
                suppressContent: false
            )
        case let .poi(rated):
            ProfilePOICard(rated: rated)
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

private struct ProfilePOICard: View {
    let rated: RatedPOI

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                categoryBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(rated.poi.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(rated.poi.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Label("\(rated.favoritesCount)", systemImage: "heart.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            if let highlight = rated.highlight {
                Text(highlight)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            if let secondary = rated.secondary {
                Text(secondary)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if rated.tags.isEmpty == false {
                HStack(spacing: 8) {
                    ForEach(Array(rated.tags.prefix(3))) { tag in
                        Text("\(tag.tag.emoji) \(tag.tag.displayName)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
            }

            HStack(spacing: 12) {
                statLabel(icon: "shoeprints.fill", value: rated.checkIns.count)
                statLabel(icon: "text.bubble.fill", value: rated.comments.count)
                statLabel(icon: "star.fill", value: rated.endorsements.hype + rated.endorsements.solid)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(20)
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
                .frame(width: 48, height: 48)
                .rotationEffect(.degrees(45))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 48, height: 48)
                .rotationEffect(.degrees(45))
            Image(systemName: rated.poi.category.symbolName)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 52, height: 52)
    }

    private func statLabel(icon: String, value: Int) -> some View {
        Label("\(value)", systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
    }
}

private struct ProfileMapMarker: View {
    let category: POICategory

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(markerGradient)
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(45))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(45))
            Image(systemName: category.symbolName)
                .font(.subheadline.weight(.bold))
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

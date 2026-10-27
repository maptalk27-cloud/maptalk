import MapKit
import SwiftUI

struct MapOverlays: MapContent {
    let ratedPOIs: [RatedPOI]
    let reals: [RealPost]
    let journeys: [JourneyPost]
    let userCoordinate: CLLocationCoordinate2D?
    let heroNamespace: Namespace.ID?
    let useTimelineStyle: Bool
    let displayMode: RealStoriesRow.DisplayMode
    let selectedStoryId: UUID?
    let userProvider: (UUID) -> User?
    let isRealUnseen: (RealPost) -> Bool
    let isPOIUnseen: (RatedPOI) -> Bool
    let onTapReal: ((RealPost) -> Void)?
    let onTapPOI: ((RatedPOI) -> Void)?
    var compactReelMarkers = false
    var selectedStoryAuthor: User? = nil

    var body: some MapContent {
        ForEach(reals.filter { !compactReelMarkers || selectedStoryId == $0.id }) { real in
            MapCircle(center: real.center, radius: real.radiusMeters)
                .foregroundStyle(Theme.neonPrimary.opacity(0.15))
                .stroke(Theme.neonPrimary, lineWidth: 2)
        }

        ForEach(reals) { real in
            Annotation("", coordinate: real.center) {
                let user = userProvider(real.userId)
                let isSelected = selectedStoryId == real.id
                let usesContentMarker = displayMode == .content || useTimelineStyle
                    || (compactReelMarkers && !isSelected)
                let isUnseen = isRealUnseen(real)
                let baseMarker: AnyView = {
                    if usesContentMarker {
                        return AnyView(
                            RealMapThumbnail(
                                real: real,
                                user: user,
                                size: 40,
                                isSelected: isSelected,
                                isUnseen: isUnseen
                            )
                        )
                    } else {
                        return AnyView(
                            RealAvatarMarker(
                                user: user,
                                isSelected: isSelected,
                                isUnseen: isUnseen
                            )
                        )
                    }
                }()
                let marker: AnyView = {
                    if let heroNamespace {
                        return AnyView(
                            baseMarker.matchedGeometryEffect(
                                id: "real-\(real.id)",
                                in: heroNamespace,
                                isSource: true
                            )
                        )
                    }
                    return baseMarker
                }()

                if let onTapReal {
                    marker
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTapReal(real)
                        }
                } else {
                    marker
                }
            }
        }

        // Draw POIs after reels so they sit above the reel markers.
        ForEach(ratedPOIs) { rated in
            let isSelected = selectedStoryId == rated.id
            let isUnseen = isPOIUnseen(rated)
            Annotation("", coordinate: rated.poi.coordinate) {
                let marker: AnyView = {
                    if isSelected, let selectedStoryAuthor {
                        return AnyView(RealAvatarMarker(user: selectedStoryAuthor,
                            isSelected: true, isUnseen: isUnseen))
                    } else if useTimelineStyle {
                        return AnyView(
                            UserMapMarker(category: rated.poi.category)
                                .frame(width: 24, height: 26)
                        )
                    } else if displayMode == .content {
                        return AnyView(
                            POIContentMapMarker(
                                category: rated.poi.category,
                                isSelected: isSelected,
                                isUnseen: isUnseen
                            )
                        )
                    } else {
                        return AnyView(
                            POICategoryMarker(
                                category: rated.poi.category,
                                count: rated.checkInPersonCount,
                                isRecentHighlight: isUnseen,
                                isSelected: isSelected,
                                showsCount: displayMode == .people
                            )
                        )
                    }
                }()

                if let onTapPOI {
                    marker
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTapPOI(rated)
                        }
                } else {
                    marker
                }
            }
        }

        ForEach(journeys) { journey in
            Annotation("", coordinate: journey.coordinate) {
                JourneyMapMarker(
                    user: userProvider(journey.userId),
                    label: "journey",
                    size: 52
                )
            }
        }

        if let userCoordinate {
            Annotation("", coordinate: userCoordinate) {
                CurrentLocationMarker()
            }
        }
    }
}

private struct POIContentMapMarker: View {
    let category: POICategory
    let isSelected: Bool
    let isUnseen: Bool

    var body: some View {
        ZStack {
            StoryStatusDiamondRing(
                size: outerSize,
                isUnseen: isUnseen,
                cornerRadius: 6,
                unreadLineWidth: statusRingLineWidth,
                seenLineWidth: statusRingLineWidth,
                unreadShadowRadius: 4
            )

            UserMapMarker(category: category)
                .frame(width: innerFrameSize, height: innerFrameSize)
        }
        .frame(width: outerSize + 8, height: outerSize + 8)
        .scaleEffect(isSelected ? 1.12 : 1)
    }

    private var outerSize: CGFloat {
        isSelected ? 36 : 32
    }

    private var innerFrameSize: CGFloat {
        isSelected ? 26 : 24
    }

    private var statusRingLineWidth: CGFloat {
        isSelected ? 2.2 : 2
    }
}

private struct CurrentLocationMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay {
                    Circle()
                        .stroke(Color.blue.opacity(0.28), lineWidth: 1)
                }

            Circle()
                .fill(Color.blue)
                .frame(width: 17, height: 17)
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                }
                .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: 44, height: 44)
        .allowsHitTesting(false)
    }
}

private struct RealAvatarMarker: View {
    let user: User?
    let isSelected: Bool
    let isUnseen: Bool

    private var initials: String {
        guard let handle = user?.handle else { return "?" }
        return String(handle.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack {
            StoryStatusCircleRing(
                diameter: ringDiameter,
                isUnseen: isUnseen,
                unreadLineWidth: 2.4,
                seenLineWidth: 1.35,
                unreadShadowRadius: 4
            )

            ZStack {
                backgroundFill

                if let url = user?.avatarURL {
                    MapImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty:
                            initialsView
                                .overlay {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                        default:
                            initialsView
                        }
                    }
                    .clipShape(Circle())
                } else {
                    initialsView
                }
            }
            .frame(width: markerDiameter, height: markerDiameter)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(isUnseen ? 0.35 : 0.24), lineWidth: 1)
            }
        }
        .frame(width: outerDiameter, height: outerDiameter)
    }

    private var markerDiameter: CGFloat {
        isSelected ? 66 : 60
    }

    private var ringDiameter: CGFloat {
        markerDiameter + 8
    }

    private var outerDiameter: CGFloat {
        markerDiameter + 18
    }

    private var initialsView: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if isUnseen {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.unreadRingColor.opacity(0.85),
                            Theme.unreadRingColor.opacity(0.35)
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 44
                    )
                )
        } else {
            Circle()
                .fill(Color.black.opacity(0.35))
        }
    }
}

private struct JourneyMapMarker: View {
    let user: User?
    let label: String
    let size: CGFloat

    private var initials: String {
        guard let handle = user?.handle else { return "JR" }
        return String(handle.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.neonAccent.opacity(0.9),
                                Theme.neonAccent.opacity(0.35)
                            ],
                            center: .center,
                            startRadius: 5,
                            endRadius: 40
                        )
                    )

                if let url = user?.avatarURL {
                    MapImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Color.gray.opacity(0.4)
                        default:
                            ProgressView()
                        }
                    }
                    .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 1.6)
            }
            .overlay {
                Circle()
                    .stroke(Theme.neonAccent, lineWidth: 2.4)
                    .frame(width: size + 8, height: size + 8)
            }
            .background {
                Circle()
                    .stroke(Theme.neonAccent.opacity(0.28), lineWidth: 3)
                    .frame(width: size + 12, height: size + 12)
            }

            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.6)
                }
                .offset(y: 8)
                .zIndex(1)
        }
        .frame(width: size, height: size + 18)
        .padding(4)
        .drawingGroup()
    }
}


private struct POICategoryMarker: View {
    let category: POICategory
    let count: Int
    let isRecentHighlight: Bool
    let isSelected: Bool
    let showsCount: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                StoryStatusDiamondRing(
                    size: ringSize,
                    isUnseen: isRecentHighlight,
                    cornerRadius: 8,
                    unreadLineWidth: statusRingLineWidth,
                    seenLineWidth: statusRingLineWidth,
                    unreadShadowRadius: isRecentHighlight ? 5 : 0
                )

                RoundedDiamond(cornerRadius: 7)
                    .fill(markerGradient)
                    .frame(width: markerSize, height: markerSize)

                RoundedDiamond(cornerRadius: 7)
                    .stroke(Color.white.opacity(isRecentHighlight ? 0.34 : 0.26), lineWidth: 1)
                    .frame(width: markerSize, height: markerSize)

                Image(systemName: category.symbolName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: ringSize + 8, height: ringSize + 8)

            if showsCount, count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(white: 0.15)))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: -2, y: -2)
            }
        }
        .padding(10)
    }

    private var markerGradient: LinearGradient {
        LinearGradient(
            colors: category.markerGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var statusRingLineWidth: CGFloat {
        isSelected ? 2.8 : 2.4
    }

    private var markerSize: CGFloat {
        isSelected ? 48 : 44
    }

    private var ringSize: CGFloat {
        markerSize + 12
    }
}

extension RatedPOI {
    var hasRecentPhotoShare: Bool {
        let recentThreshold = Date().addingTimeInterval(-StoryReadKeys.freshWindow)
        return checkIns.contains { checkIn in
            guard checkIn.activityDate > recentThreshold else { return false }
            return checkIn.media.contains { media in
                if case .photo = media.kind { return true }
                return false
            }
        }
    }
}

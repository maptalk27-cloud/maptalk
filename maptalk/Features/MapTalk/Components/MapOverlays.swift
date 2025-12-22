import MapKit
import SwiftUI

struct MapOverlays: MapContent {
    let ratedPOIs: [RatedPOI]
    let reals: [RealPost]
    let journeys: [JourneyPost]
    let userCoordinate: CLLocationCoordinate2D?
    let currentUser: User
    let onSelectPOI: (RatedPOI) -> Void
    let onSelectReal: (RealPost) -> Void
    let onSelectJourney: (JourneyPost) -> Void
    let onSelectUser: () -> Void
    let heroNamespace: Namespace.ID?
    let useTimelineStyle: Bool

    var body: some MapContent {
        ForEach(reals) { real in
            MapCircle(center: real.center, radius: real.radiusMeters)
                .foregroundStyle(Theme.neonPrimary.opacity(0.15))
                .stroke(Theme.neonPrimary, lineWidth: 2)
        }

        ForEach(reals) { real in
            Annotation("", coordinate: real.center) {
                Button {
                    onSelectReal(real)
                } label: {
                    let baseMarker: AnyView = {
                        if useTimelineStyle {
                            return AnyView(
                                RealMapThumbnail(
                                    real: real,
                                    user: PreviewData.user(for: real.userId),
                                    size: 40
                                )
                            )
                        } else {
                            return AnyView(RealAvatarMarker(user: PreviewData.user(for: real.userId)))
                        }
                    }()
                    if let heroNamespace {
                        baseMarker
                            .matchedGeometryEffect(id: "real-\(real.id)", in: heroNamespace, isSource: true)
                    } else {
                        baseMarker
                    }
                }
                .buttonStyle(.plain)
            }
        }

        // Draw POIs after reels so they sit above the reel markers.
        ForEach(ratedPOIs) { rated in
            let isRecent = rated.hasRecentPhotoShare
            Annotation("", coordinate: rated.poi.coordinate) {
                Button {
                    onSelectPOI(rated)
                } label: {
                    if useTimelineStyle {
                        UserMapMarker(category: rated.poi.category)
                            .frame(width: 24, height: 26)
                    } else {
                        POICategoryMarker(
                            category: rated.poi.category,
                            count: rated.checkIns.count,
                            isRecentHighlight: isRecent
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }

        ForEach(journeys) { journey in
            Annotation("", coordinate: journey.coordinate) {
                Button {
                    onSelectJourney(journey)
                } label: {
                    JourneyMapMarker(
                        user: PreviewData.user(for: journey.userId),
                        label: "journey",
                        size: 52
                    )
                }
                .buttonStyle(.plain)
            }
        }

        if let userCoordinate {
            Annotation("", coordinate: userCoordinate) {
                Button {
                    onSelectUser()
                } label: {
                    UserAvatarView(user: currentUser, size: 48)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct RealAvatarMarker: View {
    let user: User?

    private var initials: String {
        guard let handle = user?.handle else { return "?" }
        return String(handle.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.neonPrimary.opacity(0.85),
                            Theme.neonPrimary.opacity(0.35)
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 44
                    )
                )

            if let url = user?.avatarURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 60, height: 60)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.6)
        }
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary, lineWidth: 2.4)
        }
        .background {
            Circle()
                .stroke(Theme.neonPrimary.opacity(0.28), lineWidth: 3)
                .frame(width: 64, height: 64)
        }
        .padding(4)
        .drawingGroup()
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
                    AsyncImage(url: url) { phase in
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
            }
            .background {
                Circle()
                    .stroke(Theme.neonAccent.opacity(0.28), lineWidth: 3)
                    .frame(width: size + 4, height: size + 4)
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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(markerGradient)
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(45))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(isRecentHighlight ? 0.9 : 0.6), lineWidth: 1.6)
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(45))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(markerGlow.opacity(isRecentHighlight ? 1 : 0.6), lineWidth: 2.4)
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(45))

                Image(systemName: category.symbolName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(markerGlow.opacity(0.28), lineWidth: 3)
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(45))
            }
            .padding(10)
            .drawingGroup()

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(white: 0.15)))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: -6, y: -6)
            }
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
        category.markerGradientColors.last ?? Theme.neonPrimary
    }
}

extension RatedPOI {
    var hasRecentPhotoShare: Bool {
        let recentThreshold = Date().addingTimeInterval(-60 * 60 * 24)
        return checkIns.contains { checkIn in
            guard checkIn.createdAt >= recentThreshold else { return false }
            return checkIn.media.contains { media in
                if case .photo = media.kind { return true }
                return false
            }
        }
    }
}

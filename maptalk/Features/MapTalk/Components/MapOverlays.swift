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

    var body: some MapContent {
        ForEach(ratedPOIs) { rated in
            let isRecent = rated.hasRecentPhotoShare
            Annotation("", coordinate: rated.poi.coordinate) {
                Button {
                    onSelectPOI(rated)
                } label: {
                    POICategoryMarker(
                        category: rated.poi.category,
                        count: rated.checkIns.count,
                        isRecentHighlight: isRecent
                    )
                }
                .buttonStyle(.plain)
            }
        }

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
                    RealAvatarMarker(user: PreviewData.user(for: real.userId))
                }
                .buttonStyle(.plain)
            }
        }

        ForEach(journeys) { journey in
            Annotation("", coordinate: journey.coordinate) {
                Button {
                    onSelectJourney(journey)
                } label: {
                    JourneyMapMarker(user: PreviewData.user(for: journey.userId), label: "journey")
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
                .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
                .blendMode(.screen)
                .shadow(color: Theme.neonPrimary.opacity(0.6), radius: 12)
        }
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary, lineWidth: 2.4)
        }
        .modifier(Theme.neonGlow(Theme.neonPrimary))
    }
}

private struct JourneyMapMarker: View {
    let user: User?
    let label: String

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
                    .shadow(color: Theme.neonAccent.opacity(0.45), radius: 10, y: 4)

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
            .frame(width: 62, height: 62)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 2)
                    .blendMode(.screen)
                    .shadow(color: Theme.neonAccent.opacity(0.5), radius: 10)
            }
            .overlay {
                Circle()
                    .stroke(Theme.neonAccent, lineWidth: 2.4)
            }
        .modifier(Theme.neonGlow(Theme.neonAccent))

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
        .frame(width: 62, height: 62)
    }
}


private struct POICategoryMarker: View {
    let category: POICategory
    let count: Int
    let isRecentHighlight: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(markerGradient)
                .frame(width: 46, height: 46)
                .rotationEffect(.degrees(45))
                .shadow(color: markerGlow.opacity(0.45), radius: 12, y: 4)

            if isRecentHighlight {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.75), lineWidth: 3)
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(45))

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 6)
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(45))
                    .blur(radius: 3)
            }

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1.25)
                .frame(width: 46, height: 46)
                .rotationEffect(.degrees(45))

            Image(systemName: category.symbolName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
        .frame(width: 48, height: 48)
        .shadow(color: isRecentHighlight ? Color.orange.opacity(0.4) : .clear, radius: 14, y: 6)
        .overlay(alignment: .bottomTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.8)
                    }
                    .offset(x: 2, y: 6)
                    .shadow(color: markerGlow.opacity(0.4), radius: 4, y: 2)
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

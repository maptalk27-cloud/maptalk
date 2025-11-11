import MapKit
import SwiftUI

struct MapOverlays: MapContent {
    let ratedPOIs: [RatedPOI]
    let reals: [RealPost]
    let userCoordinate: CLLocationCoordinate2D?
    let onSelectPOI: (RatedPOI) -> Void
    let onSelectReal: (RealPost) -> Void

    var body: some MapContent {
        ForEach(ratedPOIs) { rated in
            Annotation("", coordinate: rated.poi.coordinate) {
                Button {
                    onSelectPOI(rated)
                } label: {
                    POICategoryMarker(category: rated.poi.category, count: rated.ratingCount)
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

        if let userCoordinate {
            Annotation("", coordinate: userCoordinate) {
                UserLocationMarker()
                    .allowsHitTesting(false)
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

private struct UserLocationMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.neonPrimary.opacity(0.9),
                            Theme.neonPrimary.opacity(0.25)
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 36
                    )
                )

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 1.2)
                }

            Image(systemName: "person.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: 48, height: 48)
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary, lineWidth: 2)
                .shadow(color: Theme.neonPrimary.opacity(0.5), radius: 10)
        }
        .modifier(Theme.neonGlow(Theme.neonPrimary))
    }
}

private struct POICategoryMarker: View {
    let category: POICategory
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(markerGradient)
                .frame(width: 46, height: 46)
                .rotationEffect(.degrees(45))
                .shadow(color: markerGlow.opacity(0.45), radius: 12, y: 4)

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

import MapKit
import SwiftUI

struct MapOverlays: MapContent {
    let ratedPOIs: [RatedPOI]
    let reals: [RealPost]
    let userCoordinate: CLLocationCoordinate2D?
    let onSelectPOI: (RatedPOI) -> Void
    let onSelectReal: (RealPost) -> Void
    let showCountryLabels: Bool

    var body: some MapContent {
        if showCountryLabels {
            ForEach(CountryLabel.majorSet) { label in
                Annotation("", coordinate: label.coordinate) {
                    CountryLabelBadge(name: label.displayName)
                        .allowsHitTesting(false)
                }
            }
        }

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

private struct CountryLabelBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.4), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

private struct CountryLabel: Identifiable {
    let id: String
    let displayName: String
    let coordinate: CLLocationCoordinate2D

    static let majorSet: [CountryLabel] = [
        .init(id: "usa", displayName: "United States", coordinate: .init(latitude: 39.5, longitude: -98.35)),
        .init(id: "can", displayName: "Canada", coordinate: .init(latitude: 61.0668, longitude: -107.9917)),
        .init(id: "bra", displayName: "Brazil", coordinate: .init(latitude: -10.0, longitude: -52.9)),
        .init(id: "mex", displayName: "Mexico", coordinate: .init(latitude: 23.6345, longitude: -102.5528)),
        .init(id: "arg", displayName: "Argentina", coordinate: .init(latitude: -38.4161, longitude: -63.6167)),
        .init(id: "uk", displayName: "United Kingdom", coordinate: .init(latitude: 54.7023, longitude: -3.2766)),
        .init(id: "fra", displayName: "France", coordinate: .init(latitude: 46.2276, longitude: 2.2137)),
        .init(id: "deu", displayName: "Germany", coordinate: .init(latitude: 51.1657, longitude: 10.4515)),
        .init(id: "rus", displayName: "Russia", coordinate: .init(latitude: 61.5240, longitude: 105.3188)),
        .init(id: "chn", displayName: "China", coordinate: .init(latitude: 35.8617, longitude: 104.1954)),
        .init(id: "ind", displayName: "India", coordinate: .init(latitude: 20.5937, longitude: 78.9629)),
        .init(id: "aus", displayName: "Australia", coordinate: .init(latitude: -25.2744, longitude: 133.7751)),
        .init(id: "jpn", displayName: "Japan", coordinate: .init(latitude: 36.2048, longitude: 138.2529)),
        .init(id: "kor", displayName: "South Korea", coordinate: .init(latitude: 35.9078, longitude: 127.7669)),
        .init(id: "idn", displayName: "Indonesia", coordinate: .init(latitude: -0.7893, longitude: 113.9213)),
        .init(id: "zaf", displayName: "South Africa", coordinate: .init(latitude: -30.5595, longitude: 22.9375)),
        .init(id: "egy", displayName: "Egypt", coordinate: .init(latitude: 26.8206, longitude: 30.8025)),
        .init(id: "sau", displayName: "Saudi Arabia", coordinate: .init(latitude: 23.8859, longitude: 45.0792)),
        .init(id: "tur", displayName: "Turkey", coordinate: .init(latitude: 38.9637, longitude: 35.2433)),
        .init(id: "ita", displayName: "Italy", coordinate: .init(latitude: 41.8719, longitude: 12.5674))
    ]
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
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var markerGlow: Color {
        gradientColors.last ?? Theme.neonPrimary
    }

    private var gradientColors: [Color] {
        switch category {
        case .viewpoint:
            return [Color.cyan, Color.blue]
        case .restaurant:
            return [Color.orange, Color.red]
        case .coffee:
            return [Color.brown, Color.orange.opacity(0.8)]
        case .nightlife:
            return [Color.purple, Theme.neonWarning]
        case .art:
            return [Color.pink, Color.orange]
        case .market:
            return [Color.green, Color.teal]
        }
    }
}

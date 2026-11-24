import SwiftUI

/// Shared place chrome for real check-ins. Persistence and optional actions
/// belong to the caller; this view never invents save or social state.
struct POIStoryPlaceHeading: View {
    let place: RatedPOI
    var onOpen: (() -> Void)? = nil
    var trailingAction: AnyView? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let onOpen {
                Button(action: onOpen) { placeIdentity }
                    .accessibilityLabel("View place: \(place.poi.name)")
                    .accessibilityIdentifier("poi.story.place.open.\(place.id.uuidString)")
            } else {
                placeIdentity
            }
            if let trailingAction { trailingAction }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.leading, -4)
        .offset(y: -4)
    }

    private var placeIdentity: some View {
        HStack(spacing: 11) {
            ExperienceDetailView.POIAvatar(
                category: place.poi.category,
                accentColor: place.poi.category.accentColor,
                size: 30
            )
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(place.poi.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if onOpen != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 5) {
                    Text(place.poi.category.displayName)
                    ForEach(ExperienceDetailView.poiEndorsementBadges(for: place)) { badge in
                        ExperienceDetailView.POIBadgeSummaryPill(badge: badge)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The selected visit owns its timestamp and directions. Optional real
/// interaction controls can be supplied without changing the pager's anchor.
struct POIStoryPlaybackFooter: View {
    let place: RatedPOI
    let publishedAt: Date
    var trailingActions: AnyView? = nil

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear.frame(height: 44).allowsHitTesting(false)
            if let trailingActions { trailingActions }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if let destination = MapDirectionsDestination(name: place.poi.name,
                   coordinate: place.poi.coordinate) {
                PlaceDirectionsButton(destination: destination)
                    .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(publishedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                .offset(y: -14)
                .allowsHitTesting(false)
                .accessibilityIdentifier("poi.story.visit.timestamp")
        }
    }
}

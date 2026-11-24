#if DEBUG
import SwiftUI

/// Place navigation stays secondary to the friend's current visit and expression.
struct POIPreviewFriendPlaceHeading: View {
    let place: RatedPOI
    let isSaved: Bool
    let onOpen: (() -> Void)?
    let onToggleSave: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let onOpen {
                Button(action: onOpen) {
                    placeIdentity
                }
                .accessibilityLabel("查看地点：\(place.poi.name)")
                .accessibilityIdentifier("poi.preview.friend-place.open.\(place.id.uuidString)")
            } else {
                placeIdentity
            }

            POIPreviewPlaceSaveButton(place: place, isSaved: isSaved,
                alignsToPlaceTitle: true, onToggle: onToggleSave)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        // Keep the existing place/bookmark alignment as expression moves to the author bar.
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

struct POIPreviewPlaceSaveButton: View {
    let place: RatedPOI
    let isSaved: Bool
    var alignsToPlaceTitle = false
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                // Align the glyph with the title, not the title + ratings block;
                // keep the complete 44-point touch target in the header row.
                .frame(width: 44, height: 44, alignment: alignsToPlaceTitle ? .top : .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isSaved ? "取消收藏" : "收藏")地点：\(place.poi.name)")
        .accessibilityValue(isSaved ? "已收藏" : "未收藏")
        .accessibilityHint("仅本地预览")
        .accessibilityIdentifier("poi.preview.friend-place.save.\(place.id.uuidString)")
    }
}
#endif

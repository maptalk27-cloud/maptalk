import SwiftUI

/// One pinned cover represents the posts in this browsing scope, not everyone
/// who has ever visited the coordinate. Original Posts remain individually selectable.
struct PostPlaceMapMarker: View {
    let post: RealPost
    let count: Int
    let isSelected: Bool

    var body: some View {
        VStack(spacing: -2) {
            ZStack {
                if count > 1 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.9))
                        .frame(width: 43, height: 43)
                        .rotationEffect(.degrees(7))
                        .offset(x: 3, y: -3)
                }
                PostMediaCover(attachments: post.attachments, side: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(3)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(isSelected ? Color.black.opacity(0.8) : .white, lineWidth: 1.5)
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(.black, in: Capsule())
                        .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
                        .offset(x: 4, y: 3)
                }
            }
            Image(systemName: "triangle.fill")
                .font(.system(size: 10))
                .rotationEffect(.degrees(180))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .frame(width: 58, height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(post.locationName ?? "Post location")
        .accessibilityValue(count == 1 ? "1 post" : "\(count) posts")
    }
}

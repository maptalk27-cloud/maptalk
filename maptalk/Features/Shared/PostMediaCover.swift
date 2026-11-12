import SwiftUI

/// One square cover for one Post. All media stay in publication order; this
/// collage does not change the original images or the card opened by the row.
struct PostMediaCover: View {
    let attachments: [RealPost.Attachment]
    let side: CGFloat
    private let gap: CGFloat = 1

    init(attachments: [RealPost.Attachment], side: CGFloat) {
        self.attachments = Array(attachments.lazy.filter {
            if case .emoji = $0.kind { return false }
            return true
        }.prefix(9))
        self.side = side
    }

    private var rows: [Int] {
        switch attachments.count {
        case 0: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        case 5: [2, 3]
        case 6: [3, 3]
        case 7: [2, 2, 3]
        case 8: [2, 3, 3]
        default: [3, 3, 3]
        }
    }

    var body: some View {
        Group {
            if attachments.isEmpty {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "text.alignleft")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            } else {
                let rowHeight = (side - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
                VStack(spacing: gap) {
                    ForEach(rows.indices, id: \.self) { row in
                        let start = rows.prefix(row).reduce(0, +)
                        let count = rows[row]
                        let width = (side - gap * CGFloat(count - 1)) / CGFloat(count)
                        HStack(spacing: gap) {
                            ForEach(start..<(start + count), id: \.self) { index in
                                tile(attachments[index], width: width, height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachments.isEmpty ? "Post preview"
            : attachments.count == 1 ? "1 media attachment" : "\(attachments.count) media attachments")
    }

    private func tile(_ attachment: RealPost.Attachment, width: CGFloat, height: CGFloat) -> some View {
        let url: URL?
        let isVideo: Bool
        switch attachment.kind {
        case let .photo(photo):
            url = photo
            isVideo = false
        case let .video(_, poster):
            url = poster
            isVideo = true
        case .emoji:
            url = nil
            isVideo = false
        }

        return ZStack {
            Color(.secondarySystemBackground)
            if let url {
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.system(size: min(width, height) * 0.28))
                            .foregroundStyle(.tertiary)
                    default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: min(14, min(width, height) * 0.28), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(min(6, min(width, height) * 0.12))
                    .background(.black.opacity(0.4), in: Circle())
            }
        }
    }
}

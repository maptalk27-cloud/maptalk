import SwiftUI

extension ExperienceDetailView {
    struct MediaDisplayItem: Identifiable, Hashable {
        enum Content: Hashable {
            case photo(URL)
            case video(url: URL, poster: URL?)
            case emoji(String)
        }

        let id: UUID
        let content: Content

        init(id: UUID = UUID(), content: Content) {
            self.id = id
            self.content = content
        }
    }

    struct FriendEngagement: Identifiable {
        enum Kind {
            case like
            case comment
            case rating
        }

        let id: UUID
        let userId: UUID?
        let kind: Kind
        let user: User?
        let message: String
        let badge: String?
        let timestamp: Date?
        let replies: [FriendEngagement]
        let endorsement: RatedPOI.Endorsement?
    }

    static func firstEmoji(in attachments: [RealPost.Attachment]) -> String? {
        attachments.compactMap { attachment -> String? in
            if case let .emoji(emoji) = attachment.kind {
                return emoji
            }
            return nil
        }.first
    }

    static func mediaCounts(for attachments: [RealPost.Attachment]) -> (photos: Int, videos: Int, emojis: Int) {
        attachments.reduce(into: (0, 0, 0)) { result, attachment in
            switch attachment.kind {
            case .photo:
                result.0 += 1
            case .video:
                result.1 += 1
            case .emoji:
                result.2 += 1
            }
        }
    }

    static func mediaDescriptor(for real: RealPost) -> String? {
        // Suppress derived “Shared X” descriptors; rely on explicit text or visibility badges elsewhere.
        return nil
    }
}

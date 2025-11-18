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
        let counts = mediaCounts(for: real.attachments)
        var segments: [String] = []

        if counts.photos > 0 {
            segments.append(counts.photos == 1 ? "1 photo" : "\(counts.photos) photos")
        }
        if counts.videos > 0 {
            segments.append(counts.videos == 1 ? "1 video" : "\(counts.videos) videos")
        }
        if counts.emojis > 0 {
            segments.append(counts.emojis == 1 ? "1 emoji" : "\(counts.emojis) emoji")
        }

        if segments.isEmpty {
            if let message = real.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               message.isEmpty == false {
                return "Shared a note"
            }
            return nil
        }

        return "Shared \(segments.joined(separator: " · "))"
    }
}

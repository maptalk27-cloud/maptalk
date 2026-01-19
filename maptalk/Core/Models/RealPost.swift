import CoreLocation
import Foundation

struct RealPost: Identifiable, Hashable {
    enum Visibility {
        case publicAll
        case friendsOnly
        case anonymous
    }

    struct Attachment: Identifiable, Hashable {
        struct VideoMetadata: Hashable {
            let width: Int
            let height: Int
            let duration: TimeInterval

            var aspectRatio: Double {
                guard height > 0 else { return 0 }
                return Double(width) / Double(height)
            }

            var isStandardLandscape: Bool {
                guard width > height else { return false }
                return aspectRatio >= 1.2 && aspectRatio <= 1.8
            }
        }

        enum Kind: Hashable {
            case photo(URL)
            case video(url: URL, poster: URL?)
            case emoji(String)
        }

        let id: UUID
        var kind: Kind
        var videoMetadata: VideoMetadata?

        init(id: UUID = UUID(), kind: Kind, videoMetadata: VideoMetadata? = nil) {
            self.id = id
            self.kind = kind
            self.videoMetadata = videoMetadata
        }
    }

    struct Comment: Identifiable, Hashable {
        struct Reply: Identifiable, Hashable {
            let id: UUID
            let userId: UUID
            var text: String
            var createdAt: Date

            init(id: UUID = UUID(), userId: UUID, text: String, createdAt: Date = .init()) {
                self.id = id
                self.userId = userId
                self.text = text
                self.createdAt = createdAt
            }
        }

        let id: UUID
        let userId: UUID
        var text: String
        var createdAt: Date
        var replies: [Reply]

        init(
            id: UUID = UUID(),
            userId: UUID,
            text: String,
            createdAt: Date = .init(),
            replies: [Reply] = []
        ) {
            self.id = id
            self.userId = userId
            self.text = text
            self.createdAt = createdAt
            self.replies = replies
        }
    }

    struct Metrics: Hashable {
        var likeCount: Int
        var commentCount: Int
    }

    let id: UUID
    let userId: UUID
    var center: CLLocationCoordinate2D
    var radiusMeters: CLLocationDistance
    var message: String?
    var attachments: [Attachment]
    var capsuleId: UUID? = nil
    var likes: [UUID]
    var comments: [Comment]
    var visibility: Visibility
    var createdAt: Date
    var expiresAt: Date

    var metrics: Metrics {
        Metrics(
            likeCount: likes.count,
            commentCount: comments.count
        )
    }

    static func == (lhs: RealPost, rhs: RealPost) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

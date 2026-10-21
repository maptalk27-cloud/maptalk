import Foundation

/// A local-only way to organize a person's own memories in MyMap.
/// It is intentionally not a publishable post.
struct JourneyFolder: Identifiable, Hashable, Codable {
    enum MemberReference: Hashable, Identifiable, Codable {
        case reel(UUID)
        case poi(UUID)

        var id: String {
            switch self {
            case let .reel(id):
                return "reel-\(id.uuidString)"
            case let .poi(id):
                return "poi-\(id.uuidString)"
            }
        }

        var referencedID: UUID {
            switch self {
            case let .reel(id), let .poi(id):
                return id
            }
        }
    }

    let id: UUID
    let userId: UUID
    var title: String
    /// The order reflects when memories were added to the private folder.
    var memberReferences: [MemberReference]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        title: String,
        memberReferences: [MemberReference] = [],
        createdAt: Date = .init(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.memberReferences = memberReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

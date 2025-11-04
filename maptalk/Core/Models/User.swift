import Foundation

struct User: Identifiable, Hashable {
    let id: UUID
    var handle: String
    var avatarURL: URL?
}


import Foundation

struct Rating: Identifiable, Hashable {
    enum Visibility {
        case publicAll
        case friendsOnly
        case anonymous
    }

    let id: UUID
    let userId: UUID
    let poiId: UUID
    var score: Int?
    var emoji: String?
    var text: String?
    var visibility: Visibility
    var createdAt: Date
}


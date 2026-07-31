import Foundation

struct ChatPreview: Identifiable, Hashable {
    let user: User
    let lastMessage: String
    let updatedAt: Date
    let unreadCount: Int

    var id: UUID { user.id }
}

import Combine
import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    let environment: AppEnvironment
    @Published var searchText = ""

    let conversations = PreviewData.sampleChatPreviews

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var filteredConversations: [ChatPreview] {
        let query = normalizedSearchQuery
        guard query.isEmpty == false else { return conversations }

        return conversations.filter {
            $0.user.handle.localizedCaseInsensitiveContains(query)
                || $0.lastMessage.localizedCaseInsensitiveContains(query)
        }
    }

    var matchedPeople: [User] {
        let query = normalizedSearchQuery
        guard query.isEmpty == false else { return [] }

        let conversationIDs = Set(conversations.map(\.user.id))
        return PreviewData.sampleFriends
            .filter { conversationIDs.contains($0.id) == false }
            .filter { $0.handle.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { $0 }
    }

    var suggestedPeople: [User] {
        let conversationIDs = Set(conversations.map(\.user.id))
        return PreviewData.sampleFriends
            .filter { conversationIDs.contains($0.id) == false }
            .prefix(6)
            .map { $0 }
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

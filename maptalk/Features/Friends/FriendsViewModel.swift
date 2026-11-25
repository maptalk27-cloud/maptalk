import Combine
import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    let environment: AppEnvironment
    @Published var searchText = ""
    @Published private(set) var isLoading = false
    @Published private(set) var issue: String?
    private var cancellables: Set<AnyCancellable> = []

    var usesBackend: Bool { environment.backend != nil }

    var conversations: [ChatPreview] {
        guard let backend = environment.backend else { return PreviewData.sampleChatPreviews }
        return backend.conversations.map { conversation in
            ChatPreview(user: backend.user(for: conversation.peer.id) ?? conversation.peer.user,
                lastMessage: conversation.lastMessage.text.isEmpty
                    ? "Photo or video reference" : conversation.lastMessage.text,
                updatedAt: conversation.updatedAt, unreadCount: 0)
        }
    }

    var hasMoreConversations: Bool { environment.backend?.hasMoreConversations == true }

    private var availablePeople: [User] {
        environment.backend?.knownMessagePeople ?? PreviewData.sampleFriends
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        environment.backend?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    func loadConversations(more: Bool = false) async {
        guard let backend = environment.backend, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.loadConversations(more: more)
            try Task.checkCancellation()
            issue = nil
        } catch is CancellationError { }
        catch { issue = ChatServicePresentation.errorMessage(error) }
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
        return availablePeople
            .filter { conversationIDs.contains($0.id) == false }
            .filter { $0.handle.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { $0 }
    }

    var suggestedPeople: [User] {
        let conversationIDs = Set(conversations.map(\.user.id))
        return availablePeople
            .filter { conversationIDs.contains($0.id) == false }
            .prefix(6)
            .map { $0 }
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

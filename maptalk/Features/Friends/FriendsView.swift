import SwiftUI

struct FriendsView: View {
    private static let searchRevealHeight: CGFloat = 54
    private static let chatListStartID = "chats.list-start"

    @StateObject var viewModel: FriendsViewModel
    @State private var composerDestination: ComposerDestination?
    @State private var selectedChatUser: User?
    @State private var didPositionChatList = false
    @FocusState private var isSearchFocused: Bool

    init(viewModel: @autoclosure @escaping () -> FriendsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { container in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            chatSearchBar

                            Color.clear
                                .frame(height: 14)
                                .id(Self.chatListStartID)
                                .onAppear {
                                    guard didPositionChatList == false else { return }

                                    DispatchQueue.main.async {
                                        var transaction = Transaction()
                                        transaction.disablesAnimations = true
                                        withTransaction(transaction) {
                                            proxy.scrollTo(Self.chatListStartID, anchor: .top)
                                        }

                                        DispatchQueue.main.async {
                                            didPositionChatList = true
                                        }
                                    }
                                }

                            LazyVStack(alignment: .leading, spacing: 14) {
                                if viewModel.filteredConversations.isEmpty == false {
                                    conversationsCard
                                }

                                if viewModel.matchedPeople.isEmpty == false {
                                    peopleSection
                                }

                                if viewModel.filteredConversations.isEmpty && viewModel.matchedPeople.isEmpty {
                                    Text("No chats or people found.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 30)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(
                            minHeight: container.size.height + Self.searchRevealHeight,
                            alignment: .top
                        )
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .background(Color(.systemGroupedBackground))
                    .opacity(didPositionChatList ? 1 : 0)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    composeMenu
                }
            }
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(item: $selectedChatUser) { user in
                ChatThreadView(user: user)
            }
            .sheet(item: $composerDestination) { destination in
                ChatPeoplePicker(
                    destination: destination,
                    people: viewModel.suggestedPeople
                ) { user in
                    composerDestination = nil
                    DispatchQueue.main.async {
                        selectedChatUser = user
                    }
                }
            }
        }
    }

    private var conversationsCard: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(viewModel.filteredConversations.enumerated()),
                id: \.element.id
            ) { index, conversation in
                NavigationLink {
                    ChatThreadView(user: conversation.user)
                } label: {
                    HStack(spacing: 8) {
                        ChatPreviewRow(conversation: conversation)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < viewModel.filteredConversations.count - 1 {
                    Divider()
                        .padding(.leading, 72)
                        .padding(.trailing, 12)
                }
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                ForEach(
                    Array(viewModel.matchedPeople.enumerated()),
                    id: \.element.id
                ) { index, user in
                    Button {
                        selectedChatUser = user
                    } label: {
                        PersonSearchRow(user: user, actionTitle: "Chat")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)

                    if index < viewModel.matchedPeople.count - 1 {
                        Divider()
                            .padding(.leading, 66)
                            .padding(.trailing, 12)
                    }
                }
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }

    private var chatSearchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("Search chats or people", text: $viewModel.searchText)
                .font(.subheadline)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("chats.search")

            if viewModel.searchText.isEmpty == false {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .frame(height: Self.searchRevealHeight)
    }

    private var composeMenu: some View {
        Menu {
            Button {
                composerDestination = .newChat
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }

            Button {
                composerDestination = .addFriend
            } label: {
                Label("Add friend", systemImage: "person.badge.plus")
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .tint(.black)
        .accessibilityLabel("Start a chat")
    }
}

private enum ComposerDestination: String, Identifiable {
    case newChat
    case addFriend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newChat: return "New chat"
        case .addFriend: return "Add friend"
        }
    }
}

private struct ChatPreviewRow: View {
    let conversation: ChatPreview

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(user: conversation.user, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.user.handle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(conversation.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(conversation.shortTimestamp)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if conversation.unreadCount > 0 {
                    Text(conversation.unreadCount.formatted())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.black, in: Circle())
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct PersonSearchRow: View {
    let user: User
    let actionTitle: String

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(user: user, size: 42)
            Text(user.handle)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Text(actionTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ChatAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        ZStack {
            if let avatarURL = user.avatarURL {
                MapImage(url: avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color(.separator).opacity(0.45), lineWidth: 1)
        }
    }

    private var fallback: some View {
        Text(String(user.handle.prefix(2)).uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
    }
}

private struct ChatPeoplePicker: View {
    @Environment(\.dismiss) private var dismiss

    let destination: ComposerDestination
    let people: [User]
    let onStartChat: (User) -> Void

    @State private var searchText = ""
    @State private var addedFriendIDs: Set<UUID> = []

    private var filteredPeople: [User] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return people }
        return people.filter { $0.handle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Suggested") {
                    ForEach(filteredPeople) { user in
                        Button {
                            select(user)
                        } label: {
                            PersonSearchRow(
                                user: user,
                                actionTitle: actionTitle(for: user)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func actionTitle(for user: User) -> String {
        switch destination {
        case .newChat:
            return "Chat"
        case .addFriend:
            return addedFriendIDs.contains(user.id) ? "Added" : "Add"
        }
    }

    private func select(_ user: User) {
        switch destination {
        case .newChat:
            dismiss()
            onStartChat(user)
        case .addFriend:
            addedFriendIDs.insert(user.id)
        }
    }
}

private extension ChatPreview {
    var shortTimestamp: String {
        let seconds = max(0, -updatedAt.timeIntervalSinceNow)
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(Int(seconds / 60))m"
        case ..<86_400:
            return "\(Int(seconds / 3_600))h"
        case ..<604_800:
            return "\(Int(seconds / 86_400))d"
        default:
            return updatedAt.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

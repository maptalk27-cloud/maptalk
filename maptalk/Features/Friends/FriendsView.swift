import SwiftUI

struct FriendsView: View {
    @StateObject var viewModel: FriendsViewModel
    @State private var composerDestination: ComposerDestination?
    @State private var selectedChatUser: User?
    @State private var isSearchPresented = false
    @State private var chatScrollOffset: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.filteredConversations) { conversation in
                        NavigationLink {
                            ChatThreadView(user: conversation.user)
                        } label: {
                            ChatPreviewRow(conversation: conversation)
                        }
                    }
                }

                if viewModel.matchedPeople.isEmpty == false {
                    Section("People") {
                        ForEach(viewModel.matchedPeople) { user in
                            Button {
                                selectedChatUser = user
                            } label: {
                                PersonSearchRow(user: user, actionTitle: "Chat")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if viewModel.filteredConversations.isEmpty && viewModel.matchedPeople.isEmpty {
                    Text("No chats or people found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                chatScrollOffset = offset

                if offset >= 28,
                   isSearchPresented,
                   isSearchFocused == false,
                   viewModel.searchText.isEmpty {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isSearchPresented = false
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard chatScrollOffset <= 2,
                              value.translation.height >= 34,
                              isSearchPresented == false
                        else { return }

                        withAnimation(.easeOut(duration: 0.18)) {
                            isSearchPresented = true
                        }
                    }
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                if isSearchPresented {
                    chatSearchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    composeMenu
                }
            }
            .onChange(of: isSearchFocused) { _, isFocused in
                if isFocused == false, viewModel.searchText.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        guard isSearchFocused == false,
                              viewModel.searchText.isEmpty
                        else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            isSearchPresented = false
                        }
                    }
                }
            }
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
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
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
                AsyncImage(url: avatarURL) { phase in
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

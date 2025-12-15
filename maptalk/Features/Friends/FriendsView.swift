import SwiftUI

struct FriendsView: View {
    @StateObject var viewModel: FriendsViewModel
    @Environment(\.appEnv) private var environment

    var body: some View {
        NavigationStack {
            List {
                Section("Chats") {
                    ForEach(PreviewData.sampleFriends.prefix(10), id: \.id) { friend in
                        HStack(spacing: 12) {
                            UserAvatarView(user: friend, size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(friend.handle)
                                    .font(.headline)
                                Text("View their map journal.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Friends")
        }
    }
}

import SwiftUI

struct FriendsView: View {
    @StateObject var viewModel: FriendsViewModel
    @Environment(\.appEnv) private var environment
    @State private var selectedFriend: User?

    var body: some View {
        NavigationStack {
            List {
                Section("Chats") {
                    ForEach(PreviewData.sampleFriends.prefix(10), id: \.id) { friend in
                        Button {
                            selectedFriend = friend
                        } label: {
                            HStack(spacing: 12) {
                                ProfileAvatarView(user: friend, size: 44)
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
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Friends")
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedFriend != nil },
                set: { if $0 == false { selectedFriend = nil } }
            )
        ) {
            if let friend = selectedFriend {
                NavigationStack {
                    ProfileHomeView(
                        viewModel: ProfileViewModel(environment: environment, context: .friend(friend))
                    )
                }
                .ignoresSafeArea()
            }
        }
    }
}

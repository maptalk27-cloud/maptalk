import SwiftUI

struct FriendsView: View {
    @StateObject var viewModel: FriendsViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Chats") {
                    ForEach(PreviewData.sampleFriends.prefix(10), id: \.id) { friend in
                        NavigationLink(destination: ChatThreadView()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(friend.handle)
                                    .font(.headline)
                                Text("Tap to say hi.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Friends")
        }
    }
}

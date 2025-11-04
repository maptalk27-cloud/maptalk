import SwiftUI

struct FriendsView: View {
    @StateObject var viewModel: FriendsViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Chats") {
                    ForEach(PreviewData.sampleRatings, id: \.id) { rating in
                        NavigationLink(destination: ChatThreadView()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    PreviewData.user(for: rating.userId)?.handle
                                        ?? "Friend \(rating.userId.uuidString.prefix(4))"
                                )
                                    .font(.headline)
                                Text(rating.text ?? "Emoji \(rating.emoji ?? "😎")")
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

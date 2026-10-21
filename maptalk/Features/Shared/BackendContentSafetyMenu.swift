import SwiftUI

/// Adds safety actions to the existing expanded card; never replaces its layout.
struct BackendContentSafetyMenu: View {
    struct Post: Identifiable {
        let id: UUID
        let ownerID: UUID
        let title: String
    }
    let store: BackendStore
    let posts: [Post]
    @Environment(\.dismiss) private var dismiss
    @State private var reportTarget: Post?
    @State private var blockTarget: Post?
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Menu {
            if posts.count == 1, let post = posts.first {
                actions(for: post)
            } else {
                ForEach(posts) { post in
                    Menu(post.title) { actions(for: post) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .disabled(working)
        .accessibilityLabel("Post options")
        .accessibilityIdentifier("post.safety.options")
        .confirmationDialog("Report this post", isPresented: Binding(get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } }), titleVisibility: .visible) {
            ForEach(["Inappropriate content", "Harassment or privacy", "Spam or misleading content"], id: \.self) { reason in
                Button(reason) {
                    guard let post = reportTarget else { return }
                    reportTarget = nil
                    run {
                        try await store.api.report(memoryID: post.id, reason: reason)
                        message = "Report sent. The test organizer will review it."
                    }
                }
            }
        }
        .confirmationDialog("Block this person?", isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }), titleVisibility: .visible) {
            Button("Block person", role: .destructive) {
                guard let post = blockTarget else { return }
                blockTarget = nil
                run {
                    try await store.blockUser(id: post.ownerID)
                    dismiss()
                }
            }
        } message: { Text("You won't see each other's posts.") }
        .alert("MapTalk", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private func actions(for post: Post) -> some View {
        Button("Report post", systemImage: "flag") { reportTarget = post }
        Button("Block person", systemImage: "person.crop.circle.badge.minus", role: .destructive) { blockTarget = post }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await action() }
            catch { message = error.localizedDescription }
        }
    }
}

import SwiftUI

/// One existing options button: manage our own record or report someone else's.
struct BackendContentSafetyMenu: View {
    struct Post: Identifiable {
        let id: UUID
        let ownerID: UUID
        let title: String
    }
    @ObservedObject var store: BackendStore
    let posts: [Post]
    var onCaptionEdited: (BackendMemory) -> Void = { _ in }
    var onEditorVisibilityChanged: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var reportTarget: Post?
    @State private var blockTarget: Post?
    @State private var message: String?
    @State private var working = false
    @State private var deleteTarget: Post?
    @State private var editTarget: CaptionEdit?

    private struct CaptionEdit: Identifiable {
        let memory: BackendMemory
        var id: UUID { memory.id }
    }

    private var ownPosts: [Post] {
        posts.filter { $0.ownerID == store.user.id && store.ownedMemories[$0.id]?.ownerId == store.user.id }
    }

    private var otherPosts: [Post] { posts.filter { $0.ownerID != store.user.id } }

    var body: some View {
        Menu {
            if ownPosts.count == 1, let post = ownPosts.first {
                ownActions(for: post)
            } else {
                ForEach(ownPosts) { post in
                    Menu(post.title) { ownActions(for: post) }
                }
            }
            if !ownPosts.isEmpty && !otherPosts.isEmpty { Divider() }
            if otherPosts.count == 1, let post = otherPosts.first {
                actions(for: post)
            } else {
                ForEach(otherPosts) { post in
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
        .sheet(item: $editTarget) { target in
            BackendCaptionEditor(store: store, memory: target.memory, onSaved: onCaptionEdited)
                .onAppear { onEditorVisibilityChanged(true) }
                .onDisappear { onEditorVisibilityChanged(false) }
        }
        .confirmationDialog("Delete this post?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible, presenting: deleteTarget) { post in
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                run { try await store.deletePost(memoryID: post.id) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("This removes your post from MyMap and the shared map. Other people's check-ins stay.")
        }
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

    @ViewBuilder private func ownActions(for post: Post) -> some View {
        if let memory = store.ownedMemories[post.id], memory.ownerId == store.user.id {
            if memory.kind == "reel" {
                Button("Edit caption", systemImage: "pencil") { editTarget = CaptionEdit(memory: memory) }
                    .disabled(store.pendingPublications[post.id] != nil || store.pendingMemoryMutations.contains(post.id))
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = post }
                .disabled(store.pendingMemoryMutations.contains(post.id))
        }
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

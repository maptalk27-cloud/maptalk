import SwiftUI

/// One stable submission identity survives a timeout. Editing the text creates
/// a different comment; retrying unchanged text never creates a second one.
struct ExperienceCommentDraft {
    struct Submission: Equatable {
        let id: UUID
        let text: String
    }

    var text = ""
    private var lastSubmission: Submission?
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedText.isEmpty && trimmedText.utf16.count <= 1_000 }

    mutating func submission() -> Submission? {
        guard isValid else { return nil }
        if lastSubmission?.text != trimmedText {
            lastSubmission = Submission(id: UUID(), text: trimmedText)
        }
        return lastSubmission
    }

    mutating func didSend(_ submission: Submission) {
        guard lastSubmission == submission else { return }
        if trimmedText == submission.text { text = "" }
        lastSubmission = nil
    }
}

extension ExperienceDetailView.Mode {
    var commentTarget: BackendCommentTarget? {
        switch self {
        case let .real(post, _) where post.visibility != .privateOnly: return .memory(post.id)
        case let .poi(place): return .place(place.id)
        default: return nil
        }
    }
}

/// Only the number observes the live discussion cache; card layout and the
/// active feed do not need to be rebuilt when someone leaves a comment.
struct ExperienceCommentCount: View {
    let target: BackendCommentTarget?
    let fallback: String
    @Environment(\.appEnv) private var environment

    var body: some View {
        if let target, let store = environment.backend {
            LiveCommentCount(store: store, target: target, fallback: fallback)
        } else {
            Text(fallback)
        }
    }

    private struct LiveCommentCount: View {
        @ObservedObject var store: BackendStore
        let target: BackendCommentTarget
        let fallback: String

        var body: some View {
            let count = store.cachedCommentCount(for: target)
            Text(count.map { $0 >= 100 ? "100+" : String($0) } ?? fallback)
        }
    }
}

/// The expanded card's existing discussion, with a text-only entry point.
/// No camera, location prompt, check-in or separate comments sheet is involved.
struct BackendCommentThread: View {
    @ObservedObject var store: BackendStore
    let target: BackendCommentTarget
    let onUserSelected: (User) -> Void
    @State private var draft = ExperienceCommentDraft()
    @State private var isLoading = false
    @State private var isSending = false
    @State private var loadFailed = false
    @State private var sendError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        if store.canComment(on: target) {
            VStack(alignment: .leading, spacing: 16) {
                if !entries.isEmpty {
                    ExperienceDetailView.CommentThreadList(entries: entries, onUserSelected: onUserSelected)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Add a comment…", text: $draft.text, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .tint(.white)
                            .lineLimit(1...4)
                            .focused($isFocused)
                            .disabled(isSending)
                            .padding(.vertical, 12)
                            .padding(.leading, 16)
                            .accessibilityIdentifier("experience.comment.input")

                        Button(action: send) {
                            Group {
                                if isSending { ProgressView().tint(.white) }
                                else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                            }
                            .foregroundStyle(.white.opacity(draft.isValid ? 1 : 0.35))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!draft.isValid || isSending)
                        .accessibilityLabel("Send comment")
                        .accessibilityIdentifier("experience.comment.send")
                    }
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }

                    if draft.trimmedText.utf16.count > 1_000 {
                        Text("Keep your comment under 1,000 characters.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    } else if let sendError {
                        Text(sendError)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .accessibilityIdentifier("experience.comment.error")
                    }

                    if loadFailed {
                        Button("Couldn't load comments. Retry") { Task { await load() } }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .disabled(isLoading)
                    }
                }
                .padding(.horizontal, ExperienceDetailView.ExperienceSheetLayout.engagementHorizontalInset)
            }
            .task(id: target) { await load() }
        }
    }

    private var entries: [FriendEngagement] {
        store.comments(for: target).map { comment in
            FriendEngagement(id: comment.id, userId: comment.userId, kind: .comment,
                user: store.user(for: comment.userId) ?? comment.author.user,
                message: comment.text, badge: nil, timestamp: comment.createdAt, replies: [], endorsement: nil)
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.loadComments(for: target)
            loadFailed = false
        } catch {
            if !(error is CancellationError) { loadFailed = true }
        }
    }

    private func send() {
        guard !isSending, let submission = draft.submission() else { return }
        isSending = true
        sendError = nil
        Task {
            defer { isSending = false }
            do {
                try await store.addComment(to: target, text: submission.text, requestID: submission.id)
                draft.didSend(submission)
                isFocused = false
            } catch {
                if !(error is CancellationError) {
                    sendError = "Couldn't send. Your comment is still here — try again."
                }
            }
        }
    }
}

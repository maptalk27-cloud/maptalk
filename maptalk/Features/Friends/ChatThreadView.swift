import SwiftUI

struct ChatThreadView: View {
    @Environment(\.appEnv) private var environment
    let user: User
    let replyContext: BackendMessageContext?

    init(user: User, replyContext: BackendMessageContext? = nil) {
        self.user = user
        self.replyContext = replyContext
    }

    var body: some View {
        Group {
            if let backend = environment.backend {
                RealChatThreadView(store: backend, user: user, replyContext: replyContext)
                    .id("\(backend.user.id)-\(user.id)")
            } else {
                MockChatThreadView(user: user)
            }
        }
    }
}

private struct RealChatThreadView: View {
    @ObservedObject var store: BackendStore
    let user: User
    @State private var draft = ""
    @State private var reference: BackendMessageContext?
    @State private var messages: [BackendDirectMessage] = []
    @State private var nextCursor: String?
    @State private var didLoad = false
    @State private var loadedOlderPages = false
    @State private var isLoading = false
    @State private var isSending = false
    @State private var issue: String?
    @State private var pendingSend: PendingSend?

    private struct PendingSend {
        let id: UUID
        let text: String
        let context: BackendMessageContext?
    }

    init(store: BackendStore, user: User, replyContext: BackendMessageContext?) {
        self.store = store
        self.user = user
        _reference = State(initialValue: replyContext)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if nextCursor != nil {
                        Button("Load older messages") { Task { await load(older: true) } }
                            .disabled(isLoading)
                    }
                    if isLoading { ProgressView().padding(8) }
                    if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !didLoad {
                            Button("Try again") { Task { await load() } }.disabled(isLoading)
                        }
                    }
                    if didLoad && messages.isEmpty {
                        VStack(spacing: 8) {
                            Text("No messages yet.").font(.headline)
                            Text("Say hi to @\(user.handle)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }
                    ForEach(messages) { message in
                        messageBubble(message).id(message.id)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .refreshable { await load() }
            .safeAreaInset(edge: .bottom) { composer }
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .navigationTitle("@\(user.handle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { if !didLoad { await load() } }
    }

    private func messageBubble(_ message: BackendDirectMessage) -> some View {
        let isMine = message.senderId == store.user.id
        return VStack(alignment: .leading, spacing: 7) {
            if let context = message.context {
                ChatMessageReference(store: store, context: context)
            }
            if !message.text.isEmpty { Text(message.text).font(.body).textSelection(.enabled) }
            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).opacity(0.65)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(isMine ? Color.white : Color.primary)
        .background(isMine ? Color.black : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let reference {
                HStack {
                    ChatMessageReference(store: store, context: reference)
                    Spacer()
                    Button { self.reference = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Remove photo reference")
                        .disabled(isSending)
                }
            }
            HStack(spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .disabled(isSending)
                Button { Task { await send() } } label: {
                    Group {
                        if isSending { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.black : Color.secondary, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference != nil)
    }

    private func load(older: Bool = false) async {
        guard !isLoading, !older || nextCursor != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let cursor = older ? nextCursor : nil
            let page = try await store.loadDirectMessages(with: user.id, cursor: cursor)
            try Task.checkCancellation()
            guard cursor == nil || page.nextCursor != cursor else {
                throw BackendClientError.message("Couldn't load older messages. Please retry.")
            }
            merge(page.items)
            if older || !loadedOlderPages { nextCursor = page.nextCursor }
            if older { loadedOlderPages = true }
            didLoad = true
            issue = nil
        } catch is CancellationError { }
        catch { issue = ChatServicePresentation.errorMessage(error) }
    }

    private func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: PendingSend
        if let pendingSend, pendingSend.text == text, pendingSend.context == reference {
            request = pendingSend
        } else {
            request = PendingSend(id: UUID(), text: text, context: reference)
            pendingSend = request
        }
        isSending = true
        defer { isSending = false }
        do {
            let saved = try await store.sendDirectMessage(to: user.id, id: request.id,
                text: request.text, context: request.context)
            merge([saved])
            draft = ""
            reference = nil
            pendingSend = nil
            issue = nil
        } catch is CancellationError { }
        catch { issue = ChatServicePresentation.errorMessage(error) }
    }

    private func merge(_ incoming: [BackendDirectMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in incoming { byID[message.id] = message }
        messages = byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }
}

private struct ChatMessageReference: View {
    @ObservedObject var store: BackendStore
    let context: BackendMessageContext

    private var thumbnail: URL? {
        let snapshot = store.cachedSnapshot(for: [context.memoryId], publicOnly: true)
        guard let visit = snapshot.pois.flatMap(\.checkIns).first(where: { $0.id == context.memoryId }),
              let media = visit.media.first(where: { $0.id == context.mediaId }) else { return nil }
        switch media.kind {
        case let .photo(url): return url
        case let .video(_, poster): return poster
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail {
                MapImage(url: thumbnail) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() }
                    else { Image(systemName: "photo") }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo.on.rectangle")
            }
            Text("Photo or video reference").font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

enum ChatServicePresentation {
    static func errorMessage(_ error: Error) -> String {
        if case let BackendClientError.http(status, _, _) = error, status == 404 || status == 405 {
            return "Messages need a server update. Please try again after the update."
        }
        return error.localizedDescription
    }
}

private struct MockChatThreadView: View {
    let user: User

    @State private var draft = ""
    @State private var sentMessages: [SentMessage] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if sentMessages.isEmpty {
                    VStack(spacing: 8) {
                        Text("No messages yet.")
                            .font(.headline)
                        Text("Say hi to @\(user.handle)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .padding(.horizontal, 24)
                } else {
                    LazyVStack(alignment: .trailing, spacing: 10) {
                        ForEach(sentMessages) { message in
                            Text(message.text)
                                .font(.body)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) {
                composer
            }
            .onChange(of: sentMessages.count) { _, _ in
                guard let lastID = sentMessages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .navigationTitle("@\(user.handle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(draftIsEmpty ? Color.secondary : Color.black, in: Circle())
            }
            .disabled(draftIsEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }
        sentMessages.append(.init(text: text))
        draft = ""
    }
}

private struct SentMessage: Identifiable {
    let id = UUID()
    let text: String
}

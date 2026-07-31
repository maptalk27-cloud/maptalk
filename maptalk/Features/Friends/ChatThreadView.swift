import SwiftUI

struct ChatThreadView: View {
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

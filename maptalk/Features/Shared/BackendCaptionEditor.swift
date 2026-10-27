import SwiftUI

/// Changes just the authored caption. The original post, location, attachments
/// and publication time stay intact, including when the save has to be retried.
struct BackendCaptionEditor: View {
    @ObservedObject var store: BackendStore
    let memory: BackendMemory
    let onSaved: (BackendMemory) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(store: BackendStore, memory: BackendMemory, onSaved: @escaping (BackendMemory) -> Void) {
        self.store = store
        self.memory = memory
        self.onSaved = onSaved
        _caption = State(initialValue: memory.caption)
    }

    private var canSave: Bool {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return !saving && text != memory.caption && text.utf16.count <= 2200
            && (!text.isEmpty || !memory.media.isEmpty)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(saving)
                Spacer()
                Text("Edit caption").font(.headline)
                Spacer()
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .overlay { if saving { ProgressView().tint(.primary) } }
            }
            .tint(.primary)
            TextEditor(text: $caption)
                .focused($isFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("post.caption.editor")
                .disabled(saving)
        }
        .padding(24)
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .onAppear { isFocused = true }
        .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved = try await store.updateCaption(memoryID: memory.id, caption: caption)
                onSaved(saved)
                dismiss()
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
}

import Combine
import SwiftUI

struct UserMapView: View {
    @StateObject var viewModel: UserMapViewModel

    init(viewModel: @autoclosure @escaping () -> UserMapViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            UserMapHomeView(
                user: viewModel.identity.user,
                region: viewModel.mapRegion,
                records: UserMapRecord.make(
                    reels: viewModel.reels,
                    footprints: viewModel.footprints
                ),
                journeyProvider: { id in
                    viewModel.journeyCatalog.first { $0.id == id }
                },
                journeyFolders: viewModel.journeyFolders,
                reels: viewModel.reels,
                footprints: viewModel.footprints,
                canEditJourneyFolders: viewModel.canEditJourneyFolders,
                deletesPublishedPosts: viewModel.deletesPublishedPosts,
                pendingPublications: viewModel.pendingPublications,
                onRetryPublication: { viewModel.retryPendingPublications(id: $0) },
                onCreateJourneyFolder: { title, references in
                    viewModel.createJourneyFolder(
                        title: title,
                        memberReferences: references
                    )
                },
                onSaveJourneyFolder: { folder in
                    viewModel.saveJourneyFolder(folder)
                },
                onDeleteJourneyFolder: { id in
                    viewModel.deleteJourneyFolder(id: id)
                },
                onRemoveFromMyMap: { reference in
                    viewModel.removeFromMyMap(reference)
                },
                onMapUserNavigation: { viewModel.cancelInitialEmptyMapLocation() },
                userProvider: userProvider
            )
            .refreshable { await viewModel.refreshFromBackend() }
        }
        .onAppear { viewModel.requestInitialEmptyMapLocationIfNeeded() }
        .task { await viewModel.refreshFromBackend(force: false) }
        .alert("MyMap", isPresented: Binding(
            get: { viewModel.issue != nil },
            set: { if $0 == false { viewModel.issue = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.issue = nil }
        } message: {
            Text(viewModel.issue ?? "")
        }
    }

    private var userProvider: (UUID) -> User? {
        { id in
            viewModel.userProvider(for: id)
        }
    }
}

/// One native context menu shared by the existing MyMap and Profile rows.
/// It does not change card layout or the separate MyMap swipe action.
extension View {
    func backendPostActions(for reference: JourneyFolder.MemberReference?, ownerID: UUID) -> some View {
        modifier(BackendPostActions(reference: reference, ownerID: ownerID))
    }
}

private struct BackendPostActions: ViewModifier {
    @Environment(\.appEnv) private var environment
    let reference: JourneyFolder.MemberReference?
    let ownerID: UUID

    @ViewBuilder
    func body(content: Content) -> some View {
        if let store = environment.backend, ownerID == store.user.id, let reference {
            content.modifier(ConnectedPostActions(store: store, reference: reference))
        } else {
            content
        }
    }
}

/// Only state used by row menus. Observing BackendStore itself also redraws
/// every visible archive row on each upload-progress callback.
@MainActor
final class BackendPostActionState: ObservableObject {
    @Published private(set) var memories: [BackendMemory] = []
    @Published private(set) var publishingIDs: Set<UUID> = []
    @Published private(set) var mutatingIDs: Set<UUID> = []
    private var subscriptions = Set<AnyCancellable>()

    init(store: BackendStore, reference: JourneyFolder.MemberReference) {
        bind(store: store, reference: reference)
    }

    func bind(store: BackendStore, reference: JourneyFolder.MemberReference) {
        subscriptions.removeAll()
        store.manageableMemoriesPublisher(for: reference)
            .sink { [weak self] memories in
                guard let self else { return }
                self.memories = memories
                updateAvailability(publishing: Set(store.pendingPublications.keys), mutating: store.pendingMemoryMutations)
            }
            .store(in: &subscriptions)
        store.$pendingPublications.map { Set($0.keys) }.removeDuplicates()
            .sink { [weak self] in
                self?.updateAvailability(publishing: $0, mutating: store.pendingMemoryMutations)
            }
            .store(in: &subscriptions)
        store.$pendingMemoryMutations.removeDuplicates()
            .sink { [weak self] in
                self?.updateAvailability(publishing: Set(store.pendingPublications.keys), mutating: $0)
            }
            .store(in: &subscriptions)
    }

    private func updateAvailability(publishing: Set<UUID>, mutating: Set<UUID>) {
        let ids = Set(memories.map(\.id))
        let publishing = publishing.intersection(ids)
        let mutating = mutating.intersection(ids)
        if publishingIDs != publishing { publishingIDs = publishing }
        if mutatingIDs != mutating { mutatingIDs = mutating }
    }
}

private struct ConnectedPostActions: ViewModifier {
    let store: BackendStore
    let reference: JourneyFolder.MemberReference
    @StateObject private var actionState: BackendPostActionState
    @State private var pendingAction: PostAction?
    @State private var errorMessage: String?
    @State private var editingMemory: BackendMemory?

    init(store: BackendStore, reference: JourneyFolder.MemberReference) {
        self.store = store
        self.reference = reference
        _actionState = StateObject(wrappedValue: BackendPostActionState(store: store, reference: reference))
    }

    private struct PostAction {
        let memory: BackendMemory
        let deletes: Bool
        var title: String { deletes ? "Delete this post?" : "Make this post private?" }
        var buttonTitle: String { deletes ? "Delete post" : "Make private" }
        var message: String {
            if deletes {
                return "This permanently deletes this post from MyMap and the shared map. Other check-ins at this place are kept."
            }
            return "Only you will be able to access this post. It leaves the shared map and your public profile. This does not change other check-ins at this place."
        }
    }

    private var memories: [BackendMemory] { actionState.memories }

    func body(content: Content) -> some View {
        content
            .onChangeCompat(of: reference) { newReference in
                actionState.bind(store: store, reference: newReference)
            }
            .contextMenu {
                if memories.count == 1, let memory = memories.first {
                    actions(for: memory)
                } else {
                    ForEach(memories, id: \.id) { memory in
                        Menu {
                            actions(for: memory)
                        } label: {
                            Label(memory.activityDate.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()),
                                  systemImage: memory.visibility == "public" ? "globe" : "lock")
                        }
                    }
                }
            }
            .background {
                // Closed row actions must not add sheet/dialog preference
                // hosts to every cell that List measures while scrolling.
                // Keep the row itself stable; only mount the presentation host
                // after a menu action actually needs it.
                if editingMemory != nil || pendingAction != nil || errorMessage != nil {
                    presentationHost
                }
            }
    }

    private var presentationHost: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { editingMemory != nil }, set: { if !$0 { editingMemory = nil } })) {
                if let memory = editingMemory {
                    BackendCaptionEditor(store: store, memory: memory, onSaved: { _ in })
                }
            }
            .confirmationDialog(pendingAction?.title ?? "Post", isPresented: Binding(
                get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
            ), titleVisibility: .visible, presenting: pendingAction) { action in
                Button(action.buttonTitle, role: action.deletes ? .destructive : nil) {
                    Task {
                        do {
                            if action.deletes { try await store.deletePost(memoryID: action.memory.id) }
                            else { try await store.makePrivate(memoryID: action.memory.id) }
                        } catch {
                            if !(error is CancellationError) { errorMessage = error.localizedDescription }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { action in
                Text(action.message)
            }
            .alert("Couldn't update post", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private func actions(for memory: BackendMemory) -> some View {
        if memory.kind == "reel" {
            Button("Edit caption", systemImage: "pencil") { editingMemory = memory }
                .disabled(actionState.publishingIDs.contains(memory.id) || actionState.mutatingIDs.contains(memory.id))
        }
        if memory.moderationStatus == "pending" {
            Text("Pending review")
        } else if memory.moderationStatus == "rejected" {
            Text("Not approved for sharing")
        }
        if memory.visibility == "public" {
            Button("Make private", systemImage: "lock") {
                pendingAction = PostAction(memory: memory, deletes: false)
            }
            .disabled(actionState.mutatingIDs.contains(memory.id))
        }
        Button("Delete post", systemImage: "trash", role: .destructive) {
            pendingAction = PostAction(memory: memory, deletes: true)
        }
        .disabled(actionState.mutatingIDs.contains(memory.id))
    }
}

import SwiftUI

/// A Collection is only a named, private folder of memories. MyMap remains
/// the one place to find and add memories, so this view stays deliberately
/// quiet: browse, add, remove, rename, or delete the folder.
@MainActor
struct JourneyFolderDetailView: View {
    let folder: JourneyFolder
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let onAddMemories: (JourneyFolder) -> Void
    let onOpenMemory: (UserMapRecord) -> Void
    let onSave: (JourneyFolder) -> Void
    let onDelete: (UUID) -> Void

    @State private var workingFolder: JourneyFolder
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isConfirmingDeletion = false

    init(
        folder: JourneyFolder,
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        onAddMemories: @escaping (JourneyFolder) -> Void,
        onOpenMemory: @escaping (UserMapRecord) -> Void = { _ in },
        onSave: @escaping (JourneyFolder) -> Void,
        onDelete: @escaping (UUID) -> Void = { _ in }
    ) {
        self.folder = folder
        self.reels = reels
        self.footprints = footprints
        self.onAddMemories = onAddMemories
        self.onOpenMemory = onOpenMemory
        self.onSave = onSave
        self.onDelete = onDelete
        _workingFolder = State(initialValue: folder)
    }

    var body: some View {
        List {
            if memberRecords.isEmpty {
                ContentUnavailableView(
                    "No memories yet",
                    systemImage: "folder",
                    description: Text("Tap + to add from MyMap.")
                )
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(memberRecords) { record in
                        Button {
                            onOpenMemory(record)
                        } label: {
                            UserMapRecordCard(record: record)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                removeFromCollection(record)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .tint(.red)
                            .accessibilityLabel("Remove from collection")
                        }
                        .accessibilityIdentifier("mymap.collection-memory.\(record.id.uuidString)")
                    }
                } header: {
                    Text(memoryCountLabel)
                        .textCase(nil)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("mymap.collection-list.\(workingFolder.id.uuidString)")
        .navigationTitle(workingFolder.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    onAddMemories(workingFolder)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add memories")

                Menu {
                    Button("Rename", systemImage: "pencil") {
                        renameDraft = workingFolder.title
                        isRenaming = true
                    }

                    Button("Delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Collection options")
            }
        }
        .alert("Rename collection", isPresented: $isRenaming) {
            TextField("Collection name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: rename)
        }
        .confirmationDialog(
            "Delete this collection?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete collection", role: .destructive) {
                delete(workingFolder.id)
            }
        } message: {
            Text("The original POIs and Reels will stay in MyMap.")
        }
        .onChange(of: folder) { _, updatedFolder in
            workingFolder = updatedFolder
        }
    }

    private var memoryCountLabel: String {
        memberRecords.count == 1 ? "1 memory" : "\(memberRecords.count) memories"
    }

    private var memberRecords: [UserMapRecord] {
        workingFolder.memberReferences.compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(id: reel.id, timestamp: reel.createdAt, kind: .reel(reel))
            case let .poi(id):
                guard let footprint = footprints.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(
                    id: footprint.id,
                    timestamp: footprint.latestVisit ?? .distantPast,
                    kind: .poi(footprint.ratedPOI)
                )
            }
        }
    }

    private func save(_ updatedFolder: JourneyFolder) {
        workingFolder = updatedFolder
        onSave(updatedFolder)
    }

    private func rename() {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }

        var renamedFolder = workingFolder
        renamedFolder.title = title
        renamedFolder.updatedAt = .now
        save(renamedFolder)
    }

    /// This only removes a reference from this private folder. The original
    /// memory remains available in MyMap and anywhere it was published.
    private func removeFromCollection(_ record: UserMapRecord) {
        let reference: JourneyFolder.MemberReference
        switch record.kind {
        case let .reel(reel):
            reference = .reel(reel.id)
        case let .poi(rated):
            reference = .poi(rated.id)
        case .journey:
            return
        }

        var updatedFolder = workingFolder
        updatedFolder.memberReferences.removeAll { $0 == reference }
        guard updatedFolder.memberReferences.count != workingFolder.memberReferences.count else { return }
        updatedFolder.updatedAt = .now
        save(updatedFolder)
    }

    private func delete(_ id: UUID) {
        onDelete(id)
    }
}

@MainActor
private struct JourneyFolderCover: View {
    let records: [UserMapRecord]
    let size: CGFloat

    var body: some View {
        ZStack {
            if records.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: size, height: size)
                    .background(Color(.tertiarySystemFill))
            } else {
                Color(.tertiarySystemFill)

                ForEach(Array(records.prefix(4).enumerated()), id: \.element.id) { index, record in
                    MemoryThumbnail(record: record, size: size * 0.64, cornerRadius: size * 0.16)
                        .offset(
                            x: index.isMultiple(of: 2) ? -size * 0.16 : size * 0.16,
                            y: index < 2 ? -size * 0.16 : size * 0.16
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

/// The private collection directory reached from MyMap's folder button.
/// It is deliberately just a directory: selecting and adding memories stays
/// in the main MyMap list, where search and filters already live.
@MainActor
struct JourneyCollectionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folders: [JourneyFolder]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    @Binding var selectedFolder: JourneyFolder?
    let onCreate: (String) -> JourneyFolder?
    let onAddMemories: (JourneyFolder) -> Void
    let onOpenMemory: (UserMapRecord) -> Void
    let onSave: (JourneyFolder) -> Void
    let onDelete: (UUID) -> Void

    @State private var isCreatingCollection = false
    @State private var newCollectionTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    ContentUnavailableView(
                        "No collections yet",
                        systemImage: "folder",
                        description: Text("Tap + to make a folder.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(folders) { folder in
                        collectionRow(for: folder)
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newCollectionTitle = ""
                        isCreatingCollection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New collection")
                    .accessibilityIdentifier("mymap.collections-add")
                }
            }
            .alert("New collection", isPresented: $isCreatingCollection) {
                TextField("Collection name", text: $newCollectionTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create", action: createCollection)
            }
            .accessibilityIdentifier("mymap.collections-screen")
            .navigationDestination(item: $selectedFolder) { folder in
                JourneyFolderDetailView(
                    folder: folder,
                    reels: reels,
                    footprints: footprints,
                    onAddMemories: { folder in
                        onAddMemories(folder)
                    },
                    onOpenMemory: onOpenMemory,
                    onSave: { updatedFolder in
                        selectedFolder = updatedFolder
                        onSave(updatedFolder)
                    },
                    onDelete: { folderID in
                        selectedFolder = nil
                        onDelete(folderID)
                    }
                )
            }
        }
    }

    private func createCollection() {
        let title = newCollectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = onCreate(title.isEmpty ? "Untitled Collection" : title) else { return }
        selectedFolder = folder
    }

    private func collectionRow(for folder: JourneyFolder) -> some View {
        Button {
            selectedFolder = folder
        } label: {
            HStack(spacing: 12) {
                JourneyFolderCover(records: records(for: folder), size: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(memoryCountLabel(for: folder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete(folder.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            .accessibilityLabel("Delete collection")
        }
        .accessibilityLabel("Open \(folder.title)")
        .accessibilityValue(memoryCountLabel(for: folder))
        .accessibilityIdentifier("mymap.collection-folder.\(folder.id.uuidString)")
    }

    private func records(for folder: JourneyFolder) -> [UserMapRecord] {
        folder.memberReferences.compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(id: reel.id, timestamp: reel.createdAt, kind: .reel(reel))
            case let .poi(id):
                guard let footprint = footprints.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(
                    id: footprint.id,
                    timestamp: footprint.latestVisit ?? .distantPast,
                    kind: .poi(footprint.ratedPOI)
                )
            }
        }
    }

    private func memoryCountLabel(for folder: JourneyFolder) -> String {
        let count = records(for: folder).count
        return count == 1 ? "1 memory" : "\(count) memories"
    }
}

/// A compact destination picker used by MyMap's swipe action. It behaves like
/// moving a file: choose a folder, or make one, with no extra configuration.
@MainActor
struct JourneyFolderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folders: [JourneyFolder]
    let references: [JourneyFolder.MemberReference]
    let onSelect: (UUID) -> Void
    let onCreate: (String) -> Void

    @State private var isCreatingCollection = false
    @State private var newCollectionTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    ContentUnavailableView(
                        "No collections yet",
                        systemImage: "folder",
                        description: Text("Tap + to make one.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(folders) { folder in
                        destinationRow(folder)
                    }
                }
            }
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newCollectionTitle = ""
                        isCreatingCollection = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("New collection")
                }
            }
            .alert("New collection", isPresented: $isCreatingCollection) {
                TextField("Collection name", text: $newCollectionTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create", action: createCollection)
            }
        }
    }

    private func destinationRow(_ folder: JourneyFolder) -> some View {
        let additions = additions(to: folder)

        return Button {
            onSelect(folder.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Text(folder.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if additions == 0 {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(additions == 0)
        .opacity(additions == 0 ? 0.45 : 1)
    }

    private func createCollection() {
        let title = newCollectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(title.isEmpty ? "Untitled Collection" : title)
        dismiss()
    }

    private func additions(to folder: JourneyFolder) -> Int {
        references.filter { folder.memberReferences.contains($0) == false }.count
    }
}

import SwiftUI

/// A Highlight is a named, private collection of memories. MyMap remains
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
            Section {
                if memberRecords.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "rectangle.stack",
                        description: Text("Tap + to add from MyMap.")
                    )
                    .listRowSeparator(.hidden)
                } else {
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
                            .accessibilityLabel("Remove from highlight")
                        }
                        .accessibilityIdentifier("mymap.collection-memory.\(record.id.uuidString)")
                    }
                }
            } header: {
                HStack {
                    Text(memoryCountLabel)
                    Spacer()
                    Label("Only you", systemImage: "lock")
                }
                .textCase(nil)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
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
                .accessibilityLabel("Highlight options")
            }
        }
        .alert("Rename highlight", isPresented: $isRenaming) {
            TextField("Highlight name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: rename)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete this highlight?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete highlight", role: .destructive) {
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
                return UserMapRecord(id: reel.id, timestamp: reel.activityDate, kind: .reel(reel))
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
private struct PrivateHighlightCover: View {
    let records: [UserMapRecord]
    let size: CGFloat

    var body: some View {
        ZStack {
            if let record = records.first {
                MemoryThumbnail(
                    record: record,
                    size: size - 8,
                    cornerRadius: (size - 8) / 2,
                    showsKindBadge: false
                )
            } else {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: size * 0.3, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: size - 8, height: size - 8)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A visible entrance to the same private folders, not a second Story feed.
/// The parent places this inside its List so it scrolls away with the memories.
@MainActor
struct PrivateHighlightShelf: View {
    let folders: [JourneyFolder]
    let recordsForFolder: (JourneyFolder) -> [UserMapRecord]
    let onOpen: (JourneyFolder) -> Void
    let onSeeAll: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Highlights")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if folders.isEmpty == false {
                    Button(action: onSeeAll) {
                        Text("See all")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all highlights")
                    .accessibilityIdentifier("mymap.collections-entry")
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(folders) { folder in
                        let records = recordsForFolder(folder)
                        Button {
                            onOpen(folder)
                        } label: {
                            VStack(spacing: 7) {
                                PrivateHighlightCover(records: records, size: 64)
                                title(folder.title)
                            }
                            .frame(width: 80)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(folder.title)")
                        .accessibilityValue("\(records.count == 1 ? "1 memory" : "\(records.count) memories"), Only you")
                        .accessibilityIdentifier("mymap.highlight.\(folder.id.uuidString)")
                    }

                    Button(action: onCreate) {
                        VStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.primary)
                                .frame(width: 64, height: 64)
                                .background(Color(.secondarySystemBackground), in: Circle())
                            title("New")
                        }
                        .frame(width: 80)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New highlight")
                    .accessibilityIdentifier("mymap.highlights-new")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mymap.highlights-shelf")
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }
}

/// The private Highlights directory reached from MyMap.
/// It is deliberately just a directory: selecting and adding memories stays
/// in the main MyMap list, where search and filters already live.
@MainActor
struct JourneyCollectionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Root {
        case directory
        case highlight
    }

    @Binding var root: Root
    let folders: [JourneyFolder]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    @Binding var selectedFolder: JourneyFolder?
    let onCreate: (String) -> JourneyFolder?
    let onOpenFolder: (JourneyFolder) -> Void
    let onAddMemories: (JourneyFolder) -> Void
    let onOpenMemory: (UserMapRecord) -> Void
    let onSave: (JourneyFolder) -> Void
    let onDelete: (UUID) -> Void

    @State private var isCreatingCollection = false
    @State private var newCollectionTitle = ""

    var body: some View {
        NavigationStack {
            switch root {
            case .highlight:
                if let folder = selectedFolder {
                    folderDetail(folder)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { dismiss() }
                                    .accessibilityIdentifier("mymap.highlight-close")
                            }
                        }
                }
            case .directory:
                directory
            }
        }
    }

    private var directory: some View {
        List {
            if folders.isEmpty {
                ContentUnavailableView(
                    "No highlights yet",
                    systemImage: "rectangle.stack",
                    description: Text("Keep memories together. Only you can see your highlights.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(folders) { folder in
                    collectionRow(for: folder)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Highlights")
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
                .accessibilityLabel("New highlight")
                .accessibilityIdentifier("mymap.collections-add")
            }
        }
        .alert("New highlight", isPresented: $isCreatingCollection) {
            TextField("Highlight name", text: $newCollectionTitle)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: createCollection)
        }
        .accessibilityIdentifier("mymap.collections-screen")
    }

    private func folderDetail(_ folder: JourneyFolder) -> some View {
        JourneyFolderDetailView(
            folder: folder,
            reels: reels,
            footprints: footprints,
            onAddMemories: onAddMemories,
            onOpenMemory: onOpenMemory,
            onSave: { updatedFolder in
                selectedFolder = updatedFolder
                onSave(updatedFolder)
            },
            onDelete: { folderID in
                onDelete(folderID)
                switch root {
                case .directory:
                    selectedFolder = nil
                case .highlight:
                    dismiss()
                }
            }
        )
    }

    private func createCollection() {
        let title = newCollectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = onCreate(title.isEmpty ? "Untitled Highlight" : title) else { return }
        onOpenFolder(folder)
    }

    private func collectionRow(for folder: JourneyFolder) -> some View {
        Button {
            onOpenFolder(folder)
        } label: {
            HStack(spacing: 12) {
                PrivateHighlightCover(records: records(for: folder), size: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(memoryCountLabel(for: folder)) · \(Image(systemName: "lock")) Only you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
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
            .accessibilityLabel("Delete highlight")
        }
        .accessibilityLabel("Open \(folder.title)")
        .accessibilityValue("\(memoryCountLabel(for: folder)), Only you")
        .accessibilityIdentifier("mymap.collection-folder.\(folder.id.uuidString)")
    }

    private func records(for folder: JourneyFolder) -> [UserMapRecord] {
        folder.memberReferences.compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(id: reel.id, timestamp: reel.activityDate, kind: .reel(reel))
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

/// A compact destination picker for MyMap's selected memories. Adding stores
/// references only: choose a folder, or make one, without moving originals.
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
                        "No highlights yet",
                        systemImage: "rectangle.stack",
                        description: Text("Tap + to make one.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(folders) { folder in
                        destinationRow(folder)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Add to highlight")
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
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New highlight")
                    .accessibilityIdentifier("mymap.picker-new-collection")
                }
            }
            .alert("New highlight", isPresented: $isCreatingCollection) {
                TextField("Highlight name", text: $newCollectionTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create", action: createCollection)
            }
            .accessibilityIdentifier("mymap.collection-picker")
        }
    }

    private func destinationRow(_ folder: JourneyFolder) -> some View {
        let additions = additions(to: folder)

        return Button {
            onSelect(folder.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
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
        .accessibilityIdentifier("mymap.collection-destination.\(folder.id.uuidString)")
    }

    private func createCollection() {
        let title = newCollectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(title.isEmpty ? "Untitled Highlight" : title)
        dismiss()
    }

    private func additions(to folder: JourneyFolder) -> Int {
        references.filter { folder.memberReferences.contains($0) == false }.count
    }
}

import MapKit
import SwiftUI

/// The owner-only workspace for a Journey folder.
///
/// A Journey is deliberately an organizing surface, rather than another kind
/// of post: its members still live as their original POIs and Reels, while this
/// view only remembers their order and the small amount of context the owner
/// adds around them.
@MainActor
struct JourneyFolderDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case list = "List"
        case map = "Map"

        var id: Self { self }
    }

    let folder: JourneyFolder
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let onSave: (JourneyFolder) -> Void
    let onDelete: (UUID) -> Void

    @State private var workingFolder: JourneyFolder
    @State private var displayMode: DisplayMode = .list
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isEditing = false
    @State private var selectedRecord: UserMapRecord?
    @StateObject private var capsulePresentation: MapExperiencePresentation

    init(
        folder: JourneyFolder,
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        onSave: @escaping (JourneyFolder) -> Void,
        onDelete: @escaping (UUID) -> Void = { _ in }
    ) {
        self.folder = folder
        self.reels = reels
        self.footprints = footprints
        self.onSave = onSave
        self.onDelete = onDelete
        _workingFolder = State(initialValue: folder)
        _capsulePresentation = StateObject(
            wrappedValue: MapExperiencePresentation(compactDetent: Self.memberCapsuleDetent)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                folderHeader

                Picker("Journey view", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Journey view")

                Group {
                    if memberRecords.isEmpty {
                        emptyState
                    } else if displayMode == .list {
                        memoriesList
                    } else {
                        memoriesMap
                    }
                }
                .animation(.snappy(duration: 0.28), value: displayMode)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    isEditing = true
                }
                .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $isEditing) {
            JourneyFolderEditorSheet(
                folder: workingFolder,
                reels: reels,
                footprints: footprints,
                onSave: save,
                onDelete: delete
            )
        }
        .sheet(isPresented: $capsulePresentation.isPresented, onDismiss: {
            if capsulePresentation.didDismiss() == false {
                selectedRecord = nil
            }
        }) {
            if selectedRecord != nil {
                memberCapsule
                    .id(capsulePresentation.contentRevision)
                    .mapExperienceSheetChrome(
                        compactDetent: Self.memberCapsuleDetent,
                        selection: $capsulePresentation.detent
                    )
            }
        }
        .onChange(of: folder) { _, updatedFolder in
            // A save made elsewhere should be reflected if this workspace is
            // still visible, but do not interrupt a local edit in progress.
            guard isEditing == false else { return }
            workingFolder = updatedFolder
        }
        .onChange(of: memberRecords.map(\.id)) { _, _ in
            // MapKit's automatic camera is the least surprising response when
            // a memory is added, removed, or reordered into a new geography.
            mapPosition = .automatic
            if let selectedRecord,
               memberRecords.contains(where: { $0.id == selectedRecord.id }) == false {
                self.selectedRecord = nil
                capsulePresentation.dismiss()
            }
        }
    }

    private var folderHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            JourneyFolderCover(records: memberRecords, size: 78)

            VStack(alignment: .leading, spacing: 6) {
                Label("Private folder", systemImage: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(workingFolder.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(folderSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var folderSummary: String {
        let memories = memberRecords.count == 1 ? "1 memory" : "\(memberRecords.count) memories"
        guard let start = workingFolder.timelineStart else { return memories }
        return "\(memories) · Starts \(start.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var memoriesList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(memberRecords.enumerated()), id: \.element.id) { index, record in
                Button {
                    openMemory(record)
                } label: {
                    JourneyFolderMemoryRow(record: record, index: index + 1)
                }
                .buttonStyle(.plain)

                if index < memberRecords.count - 1 {
                    Divider()
                        .padding(.leading, 76)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var memoriesMap: some View {
        Map(position: $mapPosition, interactionModes: .all) {
            ForEach(memberRecords) { record in
                Annotation(record.title, coordinate: record.coordinate) {
                    Button {
                        openMemory(record)
                    } label: {
                        JourneyFolderMapMarker(record: record)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(record.title)
                }
            }
        }
        .mapStyle(.standard)
        .frame(height: 390)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .accessibilityLabel("Map of memories in \(workingFolder.title)")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text("Start building this journey")
                .font(.headline)

            Text("Add the POIs and Reels you want to keep together. The originals stay exactly where they are.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Add memories") {
                isEditing = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 28)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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

    /// A folder stays an organizer, but revisiting one of its members uses the
    /// same compact capsule and full-detail gesture as MyMap and MapTalk.
    private func openMemory(_ record: UserMapRecord) {
        selectedRecord = record
        withAnimation(.snappy(duration: 0.28)) {
            displayMode = .map
        }
        capsulePresentation.presentNewContent()
    }

    private var memberSequenceItems: [ExperienceDetailView.SequencePager.Item] {
        memberRecords.compactMap { record in
            switch record.kind {
            case let .reel(reel):
                return .init(id: record.id, mode: .real(reel, PreviewData.user(for: reel.userId)))
            case let .poi(rated):
                return .init(id: record.id, mode: .poi(rated))
            case .journey:
                return nil
            }
        }
    }

    private var memberSequenceSelection: Binding<UUID> {
        Binding(
            get: {
                if let selectedRecord,
                   memberSequenceItems.contains(where: { $0.id == selectedRecord.id }) {
                    return selectedRecord.id
                }
                return memberSequenceItems.first?.id ?? UUID()
            },
            set: { identifier in
                guard let record = memberRecords.first(where: { $0.id == identifier }) else { return }
                selectedRecord = record
            }
        )
    }

    @ViewBuilder
    private var memberCapsule: some View {
        if memberSequenceItems.isEmpty {
            MapJourneyEmptyCapsule()
        } else {
            MapExperienceCapsule(
                pager: .init(items: memberSequenceItems),
                selection: memberSequenceSelection,
                isExpanded: capsulePresentation.isExpanded,
                onCollapsedTap: capsulePresentation.expand,
                userProvider: { PreviewData.user(for: $0) }
            )
        }
    }

    private func delete(_ id: UUID) {
        onDelete(id)
        dismiss()
    }

    private static let memberCapsuleDetent = PresentationDetent.fraction(0.35)
}

@MainActor
private struct JourneyFolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let onSave: (JourneyFolder) -> Void
    let onDelete: (UUID) -> Void

    @State private var draft: JourneyFolder
    @State private var isPickingMemories = false
    @State private var isConfirmingDeletion = false

    init(
        folder: JourneyFolder,
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        onSave: @escaping (JourneyFolder) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        self.reels = reels
        self.footprints = footprints
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: folder)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Journey title", text: $draft.title, axis: .vertical)
                        .lineLimit(1...2)
                } header: {
                    Text("Name")
                } footer: {
                    Text("This is only for your MyMap. It is not a post.")
                }

                Section("Timeline") {
                    Toggle(
                        "Set a start time",
                        isOn: Binding(
                            get: { draft.timelineStart != nil },
                            set: { isEnabled in
                                draft.timelineStart = isEnabled ? (draft.timelineStart ?? .now) : nil
                            }
                        )
                    )

                    if draft.timelineStart != nil {
                        DatePicker(
                            "Starts",
                            selection: Binding(
                                get: { draft.timelineStart ?? .now },
                                set: { draft.timelineStart = $0 }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section {
                    if draft.memberReferences.isEmpty {
                        Text("No memories yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(draft.memberReferences) { reference in
                            JourneyFolderEditorMemoryRow(
                                reference: reference,
                                record: record(for: reference)
                            )
                        }
                        .onDelete { offsets in
                            draft.memberReferences.remove(atOffsets: offsets)
                        }
                        .onMove { source, destination in
                            draft.memberReferences.move(fromOffsets: source, toOffset: destination)
                        }
                    }

                    Button {
                        isPickingMemories = true
                    } label: {
                        Label("Add memories", systemImage: "plus")
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    if draft.memberReferences.count > 1 {
                        Text("Drag to arrange the order you want to revisit them.")
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Private draft")
                                .font(.subheadline.weight(.semibold))
                            Text("Use this space to shape a future Reel. It never changes anything you have already published.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Status")
                } footer: {
                    Text("When you are ready, publishing will create a new Reel from this Journey.")
                }
            }
            .navigationTitle("Edit Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if draft.memberReferences.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.title = title.isEmpty ? "Untitled Journey" : title
                        draft.updatedAt = .now
                        onSave(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Delete Journey", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.bar)
            }
            .confirmationDialog(
                "Delete this Journey?",
                isPresented: $isConfirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete Journey", role: .destructive) {
                    onDelete(draft.id)
                    dismiss()
                }
            } message: {
                Text("The original POIs and Reels will stay in MyMap.")
            }
            .sheet(isPresented: $isPickingMemories) {
                JourneyFolderMemoryPicker(
                    reels: reels,
                    footprints: footprints,
                    selectedReferences: Set(draft.memberReferences),
                    onDone: applySelection
                )
            }
        }
    }

    private func record(for reference: JourneyFolder.MemberReference) -> UserMapRecord? {
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

    private func applySelection(_ selection: Set<JourneyFolder.MemberReference>) {
        // Keep the owner's existing order. Newly selected records naturally
        // append, so selecting an item never reshuffles a journey by surprise.
        let retained = draft.memberReferences.filter(selection.contains)
        let existing = Set(retained)
        let additions = availableReferences.filter { selection.contains($0) && existing.contains($0) == false }
        draft.memberReferences = retained + additions
    }

    private var availableReferences: [JourneyFolder.MemberReference] {
        reels.map { .reel($0.id) } + footprints.map { .poi($0.id) }
    }

}

@MainActor
private struct JourneyFolderMemoryPicker: View {
    @Environment(\.dismiss) private var dismiss

    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let onDone: (Set<JourneyFolder.MemberReference>) -> Void

    @State private var selection: Set<JourneyFolder.MemberReference>

    init(
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        selectedReferences: Set<JourneyFolder.MemberReference>,
        onDone: @escaping (Set<JourneyFolder.MemberReference>) -> Void
    ) {
        self.reels = reels
        self.footprints = footprints
        self.onDone = onDone
        _selection = State(initialValue: selectedReferences)
    }

    var body: some View {
        NavigationStack {
            List {
                if reels.isEmpty == false {
                    Section("Reels") {
                        ForEach(reels) { reel in
                            selectionRow(
                                reference: .reel(reel.id),
                                record: UserMapRecord(id: reel.id, timestamp: reel.createdAt, kind: .reel(reel))
                            )
                        }
                    }
                }

                if footprints.isEmpty == false {
                    Section("POIs") {
                        ForEach(footprints) { footprint in
                            selectionRow(
                                reference: .poi(footprint.id),
                                record: UserMapRecord(
                                    id: footprint.id,
                                    timestamp: footprint.latestVisit ?? .distantPast,
                                    kind: .poi(footprint.ratedPOI)
                                )
                            )
                        }
                    }
                }
            }
            .navigationTitle("Add memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onDone(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func selectionRow(
        reference: JourneyFolder.MemberReference,
        record: UserMapRecord
    ) -> some View {
        Button {
            if selection.contains(reference) {
                selection.remove(reference)
            } else {
                selection.insert(reference)
            }
        } label: {
            HStack(spacing: 12) {
                MemoryThumbnail(record: record, size: 46, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(record.kind.journeyFolderMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: selection.contains(reference) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection.contains(reference) ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private struct JourneyFolderMemoryRow: View {
    let record: UserMapRecord
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            MemoryThumbnail(record: record, size: 52, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(record.kind.journeyFolderMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
    }
}

@MainActor
private struct JourneyFolderEditorMemoryRow: View {
    let reference: JourneyFolder.MemberReference
    let record: UserMapRecord?

    var body: some View {
        HStack(spacing: 12) {
            if let record {
                MemoryThumbnail(record: record, size: 38, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .lineLimit(1)
                    Text(record.kind.journeyFolderMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                Text("Unavailable memory")
                    .foregroundStyle(.secondary)
            }
        }
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

@MainActor
private struct JourneyFolderMapMarker: View {
    let record: UserMapRecord

    var body: some View {
        switch record.kind {
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
        case .reel:
            MemoryThumbnail(record: record, size: 40, cornerRadius: 12)
                .shadow(color: Color.black.opacity(0.22), radius: 5, y: 3)
        case .journey:
            EmptyView()
        }
    }
}

private extension UserMapRecord.Kind {
    var journeyFolderMetadata: String {
        switch self {
        case let .poi(rated):
            return "POI · \(rated.poi.category.displayName)"
        case .reel:
            return "Reel"
        case .journey:
            return "Journey"
        }
    }
}

/// A quiet, separate shelf above MyMap's chronological memory stream.
/// Journeys intentionally do not participate in search, filtering, or map
/// pins; they are a way to revisit a hand-picked set of existing memories.
@MainActor
struct JourneyFolderShelf: View {
    let folders: [JourneyFolder]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let onOpen: (JourneyFolder) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Journeys")
                        .font(.title3.weight(.bold))
                    Text("Private collections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create Journey")
            }

            if folders.isEmpty {
                Button(action: onCreate) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, height: 42)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Make your first Journey")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Keep a few memories together, privately.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(folders) { folder in
                            Button {
                                onOpen(folder)
                            } label: {
                                JourneyFolderShelfCard(
                                    folder: folder,
                                    records: records(for: folder)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(folder.title)")
                        }

                        Button(action: onCreate) {
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 34, height: 34)
                                    .background(Color(.tertiarySystemFill), in: Circle())
                                Text("New")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 82, height: 130)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create Journey")
                    }
                }
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
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
}

@MainActor
private struct JourneyFolderShelfCard: View {
    let folder: JourneyFolder
    let records: [UserMapRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            JourneyFolderCover(records: records, size: 72)

            Text(folder.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(records.count == 1 ? "1 memory" : "\(records.count) memories")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 146, height: 154, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The decision sheet shown after selecting memories at MyMap's root. Its two
/// choices are intentionally clear: place them in an existing folder or make
/// a new private folder. It never presents a publish action.
@MainActor
struct JourneyFolderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folders: [JourneyFolder]
    let memoryCount: Int
    let onSelect: (UUID) -> Void
    let onCreate: (String) -> Void

    @State private var title = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("New Journey") {
                    TextField("A name for this Journey", text: $title)
                        .textInputAutocapitalization(.words)

                    Button {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(cleanTitle.isEmpty ? "Untitled Journey" : cleanTitle)
                        dismiss()
                    } label: {
                        Label("Create Journey", systemImage: "folder.badge.plus")
                    }
                }

                if memoryCount > 0, folders.isEmpty == false {
                    Section("Add to an existing Journey") {
                        ForEach(folders) { folder in
                            Button {
                                onSelect(folder.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 34, height: 34)
                                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(folder.memberReferences.count == 1 ? "1 memory" : "\(folder.memberReferences.count) memories")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 0)
                                    Image(systemName: "plus")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(memoryCount == 0 ? "New Journey" : "Add to Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var summary: String {
        if memoryCount == 0 {
            return "A private place to arrange memories you want to revisit together."
        }
        return memoryCount == 1
            ? "Keep this memory with a private Journey. It will stay in your regular MyMap too."
            : "Keep these \(memoryCount) memories with a private Journey. They will stay in your regular MyMap too."
    }
}

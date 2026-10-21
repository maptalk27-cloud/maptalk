import SwiftUI
import PhotosUI
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: UserProfileViewModel
    @State private var isEditingProfile = false
    private let showsCloseButton: Bool
    private let showsSettingsButton: Bool

    init(
        viewModel: @autoclosure @escaping () -> UserProfileViewModel,
        showsCloseButton: Bool = false,
        showsSettingsButton: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.showsCloseButton = showsCloseButton
        self.showsSettingsButton = showsSettingsButton
    }

    var body: some View {
        profileChrome
            .task { await viewModel.refreshFromBackend(force: false) }
            .alert("Profile", isPresented: Binding(
                get: { viewModel.issue != nil },
                set: { if $0 == false { viewModel.issue = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.issue = nil }
            } message: {
                Text(viewModel.issue ?? "")
            }
            .sheet(isPresented: $isEditingProfile) {
                if viewModel.hasConnectedAccount {
                    ConnectedEditProfileSheet(user: viewModel.user) { handle, avatar in
                        try await viewModel.saveConnectedProfile(handle: handle, avatarData: avatar)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                } else {
                    EditProfileSheet(draft: viewModel.makeDraft()) { draft in
                        viewModel.saveProfile(draft)
                    }
                    .presentationDetents([.medium])
                }
            }
    }

    @ViewBuilder
    private var profileChrome: some View {
        if showsCloseButton {
            profileContent
                .overlay(alignment: .topLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .padding(.top, 12)
                    .padding(.leading, 24)
                }
                .toolbar(.hidden, for: .navigationBar)
        } else if showsSettingsButton {
            profileContent
                .overlay(alignment: .topTrailing) {
                    NavigationLink {
                        MySettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("profile.settings")
                    .padding(.top, 12)
                    .padding(.trailing, 24)
                }
                .toolbar(.hidden, for: .navigationBar)
        } else {
            profileContent
                .navigationTitle(viewModel.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var profileContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                profileHeader
                statsRow
                actionRow
                historySection
            }
            .padding(.horizontal, 24)
            .padding(.top, showsCloseButton || showsSettingsButton ? 64 : 24)
            .padding(.bottom, 40)
        }
        .refreshable { await viewModel.refreshFromBackend() }
        .background(Color(.systemBackground))
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                PlainProfileAvatar(user: viewModel.user, size: 78)

                VStack(alignment: .leading, spacing: 5) {
                    Text("@\(viewModel.user.handle)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !viewModel.persona.baseCity.isEmpty {
                        Text(viewModel.persona.baseCity)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            if !viewModel.persona.bio.isEmpty {
                Text(viewModel.persona.bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statsRow: some View {
        let stats = viewModel.stats
        return HStack(spacing: 0) {
            ProfileStatCell(value: stats.following, title: "Following")
            ProfileStatDivider()
            ProfileStatCell(value: stats.poi, title: "POI")
            ProfileStatDivider()
            ProfileStatCell(value: stats.reels, title: "Reel")
        }
        .padding(.vertical, 4)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            if viewModel.canEditProfile {
                Button {
                    isEditingProfile = true
                } label: {
                    ProfileActionLabel(title: "Edit", systemImage: "square.and.pencil", style: .quiet)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.edit")
            } else if !viewModel.hasConnectedAccount {
                HStack(spacing: 12) {
                    NavigationLink {
                        ChatThreadView(user: viewModel.user)
                    } label: {
                        ProfileActionLabel(title: "Message", systemImage: "message.fill", style: .quiet)
                    }
                    .buttonStyle(.plain)

                    Button { } label: {
                        ProfileActionLabel(title: "Follow", systemImage: "plus", style: .quiet)
                    }
                    .buttonStyle(.plain)
                }
            }

            NavigationLink {
                ProfileMapDestination(
                    environment: viewModel.environment,
                    context: viewModel.context,
                    initialStoryId: nil
                )
            } label: {
                ProfileActionLabel(title: "View Map", systemImage: "map", style: viewModel.isCurrentUser ? .primary : .quiet)
            }
            .buttonStyle(.plain)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.historyActivities.isEmpty {
                if viewModel.isRefreshing {
                    ProgressView()
                        .padding(.vertical, 12)
                } else if viewModel.hasLoadFailure {
                    Button("Couldn't load map history. Try again") {
                        Task { await viewModel.refreshFromBackend() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                } else {
                    Text("No map history yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.historyActivities) { item in
                        NavigationLink {
                            ProfileMapDestination(
                                environment: viewModel.environment,
                                context: viewModel.context,
                                initialStoryId: item.id
                            )
                        } label: {
                            HistoryActivityRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .backendPostActions(for: postReference(for: item), ownerID: viewModel.user.id)

                        if item.id != viewModel.historyActivities.last?.id {
                            Rectangle()
                                .fill(Color(.separator).opacity(0.35))
                                .frame(height: 1)
                                .padding(.leading, 78)
                        }
                    }
                }
            }
        }
    }

    private func postReference(for item: UserProfileViewModel.HistoryActivity) -> JourneyFolder.MemberReference {
        switch item.kind {
        case let .reel(reel): return .reel(reel.id)
        case let .poi(footprint): return .poi(footprint.id)
        }
    }
}

private struct PlainProfileAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        ZStack {
            if let url = user.avatarURL {
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color(.separator).opacity(0.45), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        Text(String(user.handle.prefix(2)).uppercased())
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
    }
}

private struct ProfileStatCell: View {
    let value: Int
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProfileStatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.35))
            .frame(width: 1, height: 26)
    }
}

private struct ProfileActionLabel: View {
    enum Style {
        case primary
        case quiet
    }

    let title: String
    let systemImage: String
    let style: Style

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(style == .primary ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style == .primary ? Color.clear : Color(.separator).opacity(0.45), lineWidth: 1)
            }
    }

    private var background: Color {
        switch style {
        case .primary:
            return Color.black
        case .quiet:
            return Color(.secondarySystemBackground)
        }
    }
}

private struct HistoryActivityRow: View {
    let item: UserProfileViewModel.HistoryActivity

    var body: some View {
        HStack(spacing: 12) {
            RecentPreview(preview: item.preview)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct RecentPreview: View {
    let preview: UserProfileViewModel.HistoryActivity.Preview

    var body: some View {
        ZStack {
            switch preview {
            case let .image(url):
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        fallbackIcon("photo.fill")
                    }
                }
            case let .video(poster):
                if let poster {
                    MapImage(url: poster) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .empty:
                            ProgressView()
                        default:
                            fallbackIcon("play.fill")
                        }
                    }
                } else {
                    fallbackIcon("play.fill")
                }

                Image(systemName: "play.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.52), in: Circle())
            case let .category(category):
                ZStack {
                    LinearGradient(
                        colors: category.markerGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: category.symbolName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
        }
    }

    private func fallbackIcon(_ systemName: String) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Connected accounts only edit the two fields supported by the server.
struct ConnectedEditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var handle: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarDraft = ProfileAvatarDraft()
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var issue: String?
    @State private var importGeneration = UUID()
    @State private var saveTask: Task<Void, Never>?
    private let originalUser: User
    private let onSave: @MainActor (String, Data?) async throws -> Void

    init(user: User, onSave: @escaping @MainActor (String, Data?) async throws -> Void) {
        originalUser = user
        _handle = State(initialValue: user.handle)
        self.onSave = onSave
    }

    private var cleanHandle: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSave: Bool {
        !isSaving && !isImporting && avatarDraft.source == nil
            && cleanHandle.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil
            && (cleanHandle != originalUser.handle || avatarDraft.photo != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .frame(width: 64, alignment: .leading)
                    .disabled(isSaving)
                    .accessibilityIdentifier("profile.edit.cancel")
                Spacer()
                Text("Edit Profile").font(.headline)
                Spacer()
                Button {
                    saveTask = Task { await save() }
                } label: {
                    Group {
                        if isSaving { ProgressView().tint(.black) }
                        else { Text("Save").fontWeight(.semibold) }
                    }
                    .frame(width: 64, alignment: .trailing)
                }
                .disabled(!canSave)
                .accessibilityIdentifier("profile.edit.save")
            }
            .font(.subheadline)
            .frame(height: 52)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images,
                        preferredItemEncoding: .compatible) {
                        VStack(spacing: 10) {
                            ZStack {
                                if let photo = avatarDraft.photo {
                                    Image(uiImage: UIImage(cgImage: photo.preview.image))
                                        .resizable().scaledToFill()
                                        .frame(width: 88, height: 88)
                                        .clipShape(Circle())
                                } else {
                                    PlainProfileAvatar(user: originalUser, size: 88)
                                }
                                if isImporting {
                                    Circle().fill(.black.opacity(0.25))
                                    ProgressView().tint(.white)
                                }
                            }
                            .frame(width: 88, height: 88)
                            Text(isImporting ? "Preparing photo…" : "Change photo")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || isImporting)
                    .accessibilityIdentifier("profile.edit.photo")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Username").font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Text("@").foregroundStyle(.secondary)
                            TextField("Username", text: $handle)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .disabled(isSaving)
                                .accessibilityIdentifier("profile.edit.username")
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                        Text("3–32 letters, numbers or underscores.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let issue {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("profile.edit.error")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemBackground))
        .tint(.primary)
        .interactiveDismissDisabled(isSaving)
        .task(id: selectedPhoto) { await importPhoto() }
        .fullScreenCover(item: $avatarDraft.source) { source in
            ProfileAvatarCropView(source: source, onCancel: {
                avatarDraft.cancelCrop()
            }, onConfirm: { photo in
                avatarDraft.confirm(photo)
            })
        }
        .onDisappear { saveTask?.cancel() }
    }

    private func importPhoto() async {
        guard let selectedPhoto else { return }
        let generation = UUID()
        importGeneration = generation
        isImporting = true
        issue = nil
        defer {
            if importGeneration == generation {
                isImporting = false
                self.selectedPhoto = nil
            }
        }
        do {
            guard let imported = try await selectedPhoto.loadTransferable(type: ImportedProfilePhoto.self) else {
                throw ProfilePhotoImportError.unreadable
            }
            try Task.checkCancellation()
            guard importGeneration == generation else { return }
            avatarDraft.begin(imported.source)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, importGeneration == generation else { return }
            issue = error.localizedDescription
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        issue = nil
        defer { isSaving = false }
        do {
            try await submitProfile(handle: cleanHandle, avatarData: avatarDraft.photo?.jpegData)
            try Task.checkCancellation()
            dismiss()
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }

    // Keep the callback's actor isolation explicit across its stored-function
    // boundary. Tests exercise this same path as the Save button.
    @MainActor
    func submitProfile(handle: String, avatarData: Data?) async throws {
        try await onSave(handle, avatarData)
    }
}

nonisolated private enum ProfilePhotoImportError: LocalizedError {
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This photo couldn't be opened. Please choose another photo."
        case .tooLarge: return "This photo is too large. Please choose a smaller photo."
        }
    }
}

nonisolated private struct ImportedProfilePhoto: Transferable, Sendable {
    let source: ProfileAvatarCropSource

    static var transferRepresentation: some TransferRepresentation {
        // Import a file rather than loading an unbounded original into main-thread memory.
        // The picker-owned URL stays valid until this awaited import has finished.
        FileRepresentation(importedContentType: .image) { received in
            let source = try await ProfileAvatarProcessor.shared.prepareSource(at: received.file)
            return ImportedProfilePhoto(source: source)
        }
    }
}

private struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserProfileViewModel.ProfileDraft
    let onSave: (UserProfileViewModel.ProfileDraft) -> Void

    init(
        draft: UserProfileViewModel.ProfileDraft,
        onSave: @escaping (UserProfileViewModel.ProfileDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Handle", text: $draft.handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Base city", text: $draft.baseCity)
                }

                Section("Profile") {
                    TextField("Bio", text: $draft.bio, axis: .vertical)
                        .lineLimit(3...5)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ProfileMapDestination: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MapTalkViewModel
    private let initialStoryId: UUID?

    init(
        environment: AppEnvironment,
        context: UserMapViewModel.Context,
        initialStoryId: UUID?
    ) {
        self.initialStoryId = initialStoryId
        _viewModel = StateObject(
            wrappedValue: MapTalkViewModel(
                environment: environment,
                scope: .user(context.isCurrentUser ? environment.currentUser : context.user)
            )
        )
    }

    var body: some View {
        MapTalkView(viewModel: viewModel, initialStoryId: initialStoryId)
            .overlay(alignment: .topLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.leading, 18)
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
    }
}

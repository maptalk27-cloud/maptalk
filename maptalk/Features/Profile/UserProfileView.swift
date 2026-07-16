import SwiftUI

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: UserProfileViewModel
    @State private var isEditingProfile = false
    private let showsCloseButton: Bool

    init(viewModel: UserProfileViewModel, showsCloseButton: Bool = false) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        profileChrome
            .sheet(isPresented: $isEditingProfile) {
                EditProfileSheet(draft: viewModel.makeDraft()) { draft in
                    viewModel.saveProfile(draft)
                }
                .presentationDetents([.medium])
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
                    .padding(.top, 12)
                    .padding(.leading, 24)
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
            .padding(.top, showsCloseButton ? 64 : 24)
            .padding(.bottom, 40)
        }
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

                    Text(viewModel.persona.baseCity)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Text(viewModel.persona.bio)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
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
            if viewModel.isCurrentUser {
                Button {
                    isEditingProfile = true
                } label: {
                    ProfileActionLabel(title: "Edit", systemImage: "square.and.pencil", style: .quiet)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    NavigationLink {
                        ChatThreadView()
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
                Text("No map history yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
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
}

private struct PlainProfileAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        ZStack {
            if let url = user.avatarURL {
                AsyncImage(url: url) { phase in
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
                AsyncImage(url: url) { phase in
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
                    AsyncImage(url: poster) { phase in
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
            wrappedValue: MapTalkViewModel(environment: environment, scope: .user(context.user))
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

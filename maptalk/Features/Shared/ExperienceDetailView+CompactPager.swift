import SwiftUI

typealias MediaDisplayItem = ExperienceDetailView.MediaDisplayItem
typealias FriendEngagement = ExperienceDetailView.FriendEngagement

struct CompactRealCard: View {
    enum Style {
        case standard
        case collapsed
    }

    let real: RealPost
    let user: User?
    let userProvider: (UUID) -> User?
    let style: Style
    let displayNameOverride: String?
    let avatarCategory: POICategory?
    let suppressContent: Bool
    let hideHeader: Bool
    let hideMedia: Bool
    let useTallLayout: Bool

    @State private var isLightboxPresented = false
    @State private var lightboxSelection: UUID

    init(
        real: RealPost,
        user: User?,
        style: Style = .standard,
        displayNameOverride: String? = nil,
        avatarCategory: POICategory? = nil,
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        suppressContent: Bool = false,
        hideHeader: Bool = false,
        hideMedia: Bool = false,
        useTallLayout: Bool = false
    ) {
        self.real = real
        self.user = user
        self.userProvider = userProvider
        self.style = style
        self.displayNameOverride = displayNameOverride
        self.avatarCategory = avatarCategory
        self.suppressContent = suppressContent
        self.hideHeader = hideHeader
        self.hideMedia = hideMedia
        self.useTallLayout = useTallLayout
        _lightboxSelection = State(initialValue: real.attachments.first?.id ?? UUID())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showHeader && isSingleVideoDetail == false {
                avatarView
                    .alignmentGuide(.top) { $0[.top] }
                    .padding(.trailing, 10)
            }

            VStack(alignment: .leading, spacing: style == .collapsed ? 6 : 12) {
                if showHeader && isSingleVideoDetail == false {
                    userNameRow
                }

                if suppressContent == false {
                    if isSingleVideoDetail == false {
                        contentText
                    }

                    if shouldShowMedia {
                        mediaRow
                    }

                    if let capsule = capsuleJourney {
                        CapsuleAttachmentCard(
                            journey: capsule,
                            userProvider: userProvider,
                            style: style
                        )
                    }
                }

                if useSplitLayout {
                    Spacer(minLength: 0)
                }

                if isSingleVideoDetail == false {
                    footerRow
                }
            }
            .frame(maxHeight: useSplitLayout ? .infinity : nil, alignment: .top)
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: useSplitLayout ? .infinity : nil,
            alignment: .topLeading
        )
        .fullScreenCover(isPresented: $isLightboxPresented) {
            if lightboxItems.isEmpty == false {
                ExperienceDetailView.MediaLightbox(
                    items: lightboxItems,
                    selection: $lightboxSelection,
                    accentColor: lightboxAccentColor,
                    isPresented: $isLightboxPresented
                )
            }
        }
    }

    private var horizontalPadding: CGFloat {
        style == .collapsed ? 16 : 24
    }

    private var verticalPadding: CGFloat {
        if isSingleVideoDetail {
            return 0
        }
        if style == .collapsed {
            return 6
        }
        return 22
    }

    private var headerTopPadding: CGFloat {
        if isSingleVideoDetail {
            return 0
        }
        if hideHeader {
            return 14
        }
        if style == .collapsed {
            return 14
        }
        return 40
    }

    private var avatarSize: CGFloat {
        style == .collapsed ? 34 : 40
    }

    private var mediaHeight: CGFloat {
        if style == .collapsed {
            return hideHeader ? 112 : 96
        }
        return 120
    }

    private var mediaSpacing: CGFloat { 10 }

    private var standardTileSize: CGFloat { 88 }

    private var showHeader: Bool { hideHeader == false }

    private var lightboxItems: [MediaDisplayItem] {
        real.attachments.map { attachment in
            switch attachment.kind {
            case let .photo(url):
                return MediaDisplayItem(id: attachment.id, content: .photo(url))
            case let .video(url, poster):
                return MediaDisplayItem(
                    id: attachment.id,
                    content: .video(url: url, poster: poster, metadata: attachment.videoMetadata)
                )
            case let .emoji(emoji):
                return MediaDisplayItem(id: attachment.id, content: .emoji(emoji))
            }
        }
    }

    private var lightboxAccentColor: Color {
        switch real.visibility {
        case .publicAll:
            return Theme.neonPrimary
        case .friendsOnly:
            return Theme.neonAccent
        case .anonymous:
            return Theme.neonWarning
        }
    }

    private var maxVisibleMediaCount: Int {
        style == .collapsed ? 3 : 9
    }

    private var isSinglePhoto: Bool {
        guard real.attachments.count == 1,
              let attachment = real.attachments.first,
              case .photo = attachment.kind else {
            return false
        }
        return true
    }

    private var isSingleVideo: Bool {
        guard real.attachments.count == 1,
              let attachment = real.attachments.first,
              case .video = attachment.kind else {
            return false
        }
        return true
    }

    private var isSingleVideoDetail: Bool {
        style == .standard && isSingleVideo
    }

    private var singlePhotoHeight: CGFloat { 160 }

    private var singleVideoLeadingInset: CGFloat {
        if isSingleVideoDetail {
            return horizontalPadding
        }
        return showHeader ? (avatarSize + 10 + horizontalPadding) : horizontalPadding
    }

    private var singleVideoTrailingInset: CGFloat { horizontalPadding }

    private var overflowCount: Int {
        max(0, real.attachments.count - maxVisibleMediaCount)
    }

    private var textLineLimit: Int {
        style == .collapsed ? 1 : 3
    }

    private var userNameRow: some View {
        Text(displayName)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatarView: some View {
        Group {
            if let category = avatarCategory {
                POICategoryAvatar(category: category, size: avatarSize)
            } else if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.gray
                    default:
                        ProgressView()
                    }
                }
            } else {
                Color.gray.opacity(0.4)
                    .overlay {
                        Text(displayInitials)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    private var displayName: String {
        displayNameOverride ?? user?.handle ?? "Unknown user"
    }

    private var displayInitials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "??" }
        return String(trimmed.prefix(2)).uppercased()
    }

    private var contentText: some View {
        Text(trimmedMessage ?? fallbackDescription)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(textLineLimit)
    }

    private var trimmedMessage: String? {
        let text = real.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private var fallbackDescription: String {
        if let descriptor = ExperienceDetailView.mediaDescriptor(for: real) {
            return descriptor
        }
        return "\(real.visibility.displayName) drop"
    }

    private var hasMedia: Bool {
        real.attachments.isEmpty == false
    }

    private var capsuleJourney: JourneyPost? {
        guard let capsuleId = real.capsuleId else { return nil }
        return PreviewData.journey(for: capsuleId)
    }

    private var shouldShowMedia: Bool {
        hasMedia && hideMedia == false
    }

    private var useSplitLayout: Bool {
        style == .collapsed && useTallLayout
    }

    private var collageSources: [RealPost.Attachment?] {
        guard hasMedia else { return [] }
        return Array(real.attachments.prefix(maxVisibleMediaCount)).map { Optional($0) }
    }

    @ViewBuilder
    private func collageTile(for attachment: RealPost.Attachment?) -> some View {
        if let attachment {
            attachmentThumbnail(for: attachment)
        } else if let text = trimmedMessage {
            previewTextCard(text)
        } else {
            previewFallback(symbol: "sparkles")
        }
    }

    @ViewBuilder
    private var mediaRow: some View {
        if isSingleVideoDetail {
            singleVideoRow
        } else if isSinglePhoto {
            singlePhotoRow
        } else if style == .collapsed {
            collapsedMediaStrip
        } else {
            standardMediaGrid
        }
    }

    private var singlePhotoRow: some View {
        Group {
            if let attachment = real.attachments.first {
                if case let .photo(url) = attachment.kind {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .empty:
                            ProgressView()
                        case .failure:
                            previewFallback(symbol: "photo")
                        @unknown default:
                            previewFallback(symbol: "photo")
                        }
                    }
                    .frame(height: singlePhotoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleMediaTap(for: attachment)
                    }
                }
            }
        }
    }

    private var singleVideoRow: some View {
        Group {
            if let attachment = real.attachments.first,
               case let .video(url, poster) = attachment.kind {
                let containerAspectRatio: CGFloat = 9.0 / 16.0
                let ratioValue = CGFloat(attachment.videoMetadata?.aspectRatio ?? 0)
                let videoAspectRatio = ratioValue > 0 ? ratioValue : (16.0 / 9.0)
                let shouldFit = videoAspectRatio > containerAspectRatio
                ExperienceDetailView.AutoPlayVideoView(
                    url: url,
                    poster: poster,
                    accentColor: lightboxAccentColor,
                    mode: ExperienceDetailView.MediaCardView.Mode.card,
                    usesAspectFit: shouldFit,
                    isMuted: false
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(containerAspectRatio, contentMode: .fit)
                .background(Color.white)
                .clipped()
                .padding(.leading, -singleVideoLeadingInset)
                .padding(.trailing, -singleVideoTrailingInset)
                .overlay(singleVideoOverlay)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleMediaTap(for: attachment)
                }
            }
        }
    }

    private var singleVideoOverlay: some View {
        let textLeadingInset = showHeader ? (avatarSize + 10) : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if showHeader {
                    avatarView
                        .padding(.leading, -singleVideoLeadingInset)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    if suppressContent == false {
                        contentText
                    }
                }
            }

            Spacer(minLength: 0)
            footerRow
                .padding(.leading, textLeadingInset)
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.leading, singleVideoLeadingInset)
        .padding(.trailing, singleVideoTrailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var collapsedMediaStrip: some View {
        GeometryReader { proxy in
            let visibleCount = max(min(collageSources.count, 3), 1)
            let totalSpacing = mediaSpacing * CGFloat(visibleCount - 1)
            let calculatedWidth = max((proxy.size.width - totalSpacing) / CGFloat(visibleCount), 0)
            let size = min(calculatedWidth, mediaHeight).rounded(.down)

            HStack(spacing: mediaSpacing) {
                ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                    collageTile(for: element.element)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .trailing) {
                            collapsedOverflowOverlay(for: element.offset, tileSize: size)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleMediaTap(for: element.element)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: mediaHeight)
    }

    private var standardMediaGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(standardTileSize), spacing: mediaSpacing, alignment: .leading), count: 3)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: mediaSpacing) {
            ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                collageTile(for: element.element)
                    .frame(width: standardTileSize, height: standardTileSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .trailing) {
                        standardOverflowOverlay(for: element.offset, tileSize: standardTileSize)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleMediaTap(for: element.element)
                    }
            }
        }
    }

    private var footerRow: some View {
        HStack {
            Text(real.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 10) {
                metricsPill(
                    symbol: "heart.fill",
                    text: ExperienceDetailView.formatCount(real.metrics.likeCount)
                )
                metricsPill(
                    symbol: "bubble.right.fill",
                    text: ExperienceDetailView.formatCount(real.metrics.commentCount)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func handleMediaTap(for attachment: RealPost.Attachment?) {
        guard let first = lightboxItems.first else { return }
        if let attachment, let match = lightboxItems.first(where: { $0.id == attachment.id }) {
            lightboxSelection = match.id
        } else {
            lightboxSelection = first.id
        }
        isLightboxPresented = true
    }

    private func collapsedOverflowOverlay(for index: Int, tileSize: CGFloat) -> some View {
        Group {
            if style == .collapsed,
               overflowCount > 0,
               index == maxVisibleMediaCount - 1 {
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: tileSize * 0.65)
                        .offset(x: tileSize * 0.175)
                    Text("+\(overflowCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
            }
        }
    }

    private func standardOverflowOverlay(for index: Int, tileSize: CGFloat) -> some View {
        Group {
            if style == .standard,
               overflowCount > 0,
               index == maxVisibleMediaCount - 1 {
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                    Text("+\(overflowCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func metricsPill(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule(style: .continuous))
    }

    struct POICategoryAvatar: View {
        let category: POICategory
        let size: CGFloat

        var body: some View {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: category.markerGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: category.markerGradientColors.last?.opacity(0.5) ?? .black.opacity(0.5), radius: 6, y: 3)

                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.2)

                Image(systemName: category.symbolName)
                    .font(.system(size: max(size * 0.38, 14), weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .frame(width: size, height: size)
        }
    }


    @ViewBuilder
    private func attachmentThumbnail(for attachment: RealPost.Attachment) -> some View {
        switch attachment.kind {
        case let .photo(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    ProgressView()
                case .failure:
                    previewFallback(symbol: "photo")
                @unknown default:
                    previewFallback(symbol: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        case let .video(_, poster):
            ZStack {
                if let poster {
                    AsyncImage(url: poster) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty:
                            ProgressView()
                        case .failure:
                            previewFallback(symbol: "play.rectangle.fill")
                        @unknown default:
                            previewFallback(symbol: "play.rectangle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay { Color.black.opacity(0.25) }
                } else {
                    previewFallback(symbol: "play.rectangle.fill")
                }

                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.neonPrimary)
                            .offset(x: 1.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            }
        case let .emoji(emoji):
            LinearGradient(
                colors: [Theme.neonPrimary.opacity(0.85), Theme.neonAccent.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Text(emoji)
                    .font(.system(size: 48))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
        }
    }

    private func previewFallback(symbol: String) -> some View {
        LinearGradient(
            colors: [Theme.neonPrimary.opacity(0.35), Color.black.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func previewTextCard(_ text: String) -> some View {
        LinearGradient(
            colors: [Theme.neonPrimary.opacity(0.28), Theme.neonAccent.opacity(0.22)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(12)
        }
    }

    private struct CapsuleAttachmentCard: View {
        let journey: JourneyPost
        let userProvider: (UUID) -> User?
        let style: CompactRealCard.Style

        private let avatarSize: CGFloat = 34

        var body: some View {
            JourneyAvatarStack(
                journey: journey,
                userProvider: userProvider,
                avatarSize: avatarSize,
                maxRows: style == .collapsed ? 2 : nil
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
    }

    private var avatarBadge: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.gray
                    default:
                        ProgressView()
                    }
                }
            } else {
                Text(user?.handle.prefix(2).uppercased() ?? "??")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.65), lineWidth: 1)
        }
        .background(
            Circle()
                .fill(Color.black.opacity(0.35))
                .blur(radius: 0.5)
        )
    }
}

struct FriendEngagementList: View {
    let title: String
    let entries: [FriendEngagement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))

            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    FriendEngagementRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, ExperienceDetailView.ExperienceSheetLayout.engagementHorizontalInset)
    }
}

struct FriendEngagementRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestampText {
                        Text(timestampText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }

            if let badgeText = entry.badge {
                Text(badgeText)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule(style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var avatar: some View {
        ZStack {
            if let url = entry.user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            overlayBadge
                .offset(x: 6, y: 6)
        }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.3))
    }

    private var initials: String {
        guard let handle = entry.user?.handle else { return "??" }
        return String(handle.prefix(2)).uppercased()
    }

    @ViewBuilder
    private var overlayBadge: some View {
        if let endorsement = entry.endorsement {
            Circle()
                .fill(Color.black.opacity(0.8))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: ExperienceDetailView.endorsementIconName(for: endorsement))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ExperienceDetailView.endorsementColor(for: endorsement))
                }
        } else {
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(iconColor)
                }
        }
    }

    private var iconName: String {
        switch entry.kind {
        case .like:
            return "heart.fill"
        case .comment:
            return "text.bubble.fill"
        case .rating:
            return "star.fill"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .like:
            return Theme.neonPrimary
        case .comment:
            return .white
        case .rating:
            return Theme.neonAccent
        }
    }

    private var timestampText: String? {
        entry.timestamp?.formatted(.relative(presentation: .named))
    }
}

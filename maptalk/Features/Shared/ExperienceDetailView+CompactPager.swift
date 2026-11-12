import SwiftUI

typealias MediaDisplayItem = ExperienceDetailView.MediaDisplayItem
typealias FriendEngagement = ExperienceDetailView.FriendEngagement

private struct SingleVideoViewport: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content.frame(maxWidth: .infinity).frame(height: max(1, height))
        } else {
            content.frame(maxWidth: .infinity).aspectRatio(3.0 / 4.0, contentMode: .fit)
        }
    }
}

struct CompactRealCard: View {
    enum Style {
        case standard
        case collapsed
    }

    let real: RealPost
    let user: User?
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let style: Style
    let displayNameOverride: String?
    let avatarCategory: POICategory?
    let suppressContent: Bool
    let hideHeader: Bool
    let hideMedia: Bool
    let useTallLayout: Bool
    let usesNeutralAppearance: Bool
    let singleVideoViewportHeight: CGFloat?
    let isPlaybackActive: Bool
    let onUserSelected: ((User) -> Void)?
    let onCapsuleTap: ((JourneyPost) -> Void)?

    @State private var isLightboxPresented = false
    @State private var lightboxSelection: UUID
    @State private var capsuleOverlayHeight: CGFloat = 0
    @Environment(\.friendStoryOnMediaReady) private var onMediaReady
    @Environment(\.friendStoryExpectedMedia) private var expectedMedia
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @Environment(\.postMediaLayoutReference) private var postMediaLayoutReference
    @Environment(\.openPostEngagement) private var openPostEngagement
    @Environment(\.postSheetDesign) private var postSheetDesign
    @Environment(\.postCardPalette) private var postCardPalette
    @ScaledMetric(relativeTo: .body) private var editorialCaptionLineHeight: CGFloat = 23
    @State private var childPresentationID = UUID()

    init(
        real: RealPost,
        user: User?,
        style: Style = .standard,
        displayNameOverride: String? = nil,
        avatarCategory: POICategory? = nil,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { PreviewData.journey(for: $0) },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        suppressContent: Bool = false,
        hideHeader: Bool = false,
        hideMedia: Bool = false,
        useTallLayout: Bool = false,
        usesNeutralAppearance: Bool = false,
        singleVideoViewportHeight: CGFloat? = nil,
        isPlaybackActive: Bool = true,
        onUserSelected: ((User) -> Void)? = nil,
        onCapsuleTap: ((JourneyPost) -> Void)? = nil
    ) {
        self.real = real
        self.user = user
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.style = style
        self.displayNameOverride = displayNameOverride
        self.avatarCategory = avatarCategory
        self.suppressContent = suppressContent
        self.hideHeader = hideHeader
        self.hideMedia = hideMedia
        self.useTallLayout = useTallLayout
        self.usesNeutralAppearance = usesNeutralAppearance
        self.singleVideoViewportHeight = singleVideoViewportHeight
        self.isPlaybackActive = isPlaybackActive
        self.onUserSelected = onUserSelected
        self.onCapsuleTap = onCapsuleTap
        _lightboxSelection = State(initialValue: real.attachments.first?.id ?? UUID())
    }

    var body: some View {
        Group {
            if usesNeutralAppearance && !isSingleVideo {
                if postSheetDesign == .notebook {
                    notebookPostContent
                } else if postSheetDesign == .editorial {
                    editorialPostContent
                } else {
                    postCardContent
                }
            } else if isSingleVideoDetail {
                singleVideoRow
            } else {
                regularCardContent
            }
        }
        .onChangeCompat(of: isLightboxPresented) { presented in
            childPresentationChanged?(childPresentationID, presented)
        }
        .onDisappear {
            if !isLightboxPresented { childPresentationChanged?(childPresentationID, false) }
        }
        .fullScreenCover(isPresented: $isLightboxPresented) {
            if lightboxItems.isEmpty == false {
                ExperienceDetailView.MediaLightbox(
                    items: lightboxItems,
                    selection: $lightboxSelection,
                    accentColor: lightboxAccentColor,
                    isPresented: $isLightboxPresented
                )
                .environment(\.friendStoryPlaybackEnabled, true)
                .environment(\.friendStoryExpectedMedia, [])
                .environment(\.friendStoryOnMediaReady, nil)
                .environment(\.friendStoryChildPresentationChanged, nil)
            }
        }
    }

    private var notebookPostContent: some View {
        let reference = postMediaLayoutReference.cardSize(for: real.id, count: postAttachmentCount)
        return PostNotebookPageLayout(
            isCompact: useSplitLayout,
            referenceHeight: reference.map { max(0, $0.height - 32) },
            minimumCaptionHeight: editorialCaptionLineHeight
        ) {
            if showHeader {
                HStack(spacing: 12) {
                    profileButton {
                        HStack(spacing: 8) {
                            avatarView
                                .scaleEffect(28 / avatarSize)
                                .frame(width: 28, height: 28)
                            Text(displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    postTimestamp.padding(.trailing, 24)
                }
                .postEditorialRole(.author)
            }
            if !suppressContent {
                if let caption = trimmedMessage {
                    Text(caption)
                        .font(shouldShowMedia ? .body : .title3)
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("experience.real.caption.\(real.id.uuidString)")
                        .postEditorialRole(.caption)
                }
                if shouldShowMedia { notebookPostPhotos.postEditorialRole(.photos) }
            }
            editorialPostActions.postEditorialRole(.actions)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: reference?.width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: useSplitLayout ? .infinity : nil, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard useSplitLayout else { return }
            postMediaLayoutReference.recordCard(size, for: real.id, count: postAttachmentCount)
        }
    }

    private var notebookPostPhotos: some View {
        let sources = Array(collageSources.prefix(3))
        let extraCount = max(0, postAttachmentCount - sources.count)
        return PostNotebookPhotoLayout {
            ForEach(Array(sources.enumerated()), id: \.offset) { element in
                Color(uiColor: .secondarySystemBackground)
                    .overlay { collageTile(for: element.element) }
                    .overlay(alignment: .bottomTrailing) {
                        if extraCount > 0, element.offset == sources.count - 1 {
                            Text("+\(extraCount)")
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.48), in: Capsule())
                                .padding(7)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let attachment = extraCount > 0 && element.offset == sources.count - 1
                            ? real.attachments.dropFirst(3).first ?? element.element
                            : element.element
                        handleMediaTap(for: attachment)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(extraCount > 0 && element.offset == sources.count - 1
                        ? "View \(extraCount) more photos"
                        : "View attachment \(element.offset + 1) of \(postAttachmentCount)")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // Opt-in alternative: the sheet itself is the page. The original Moments-
    // style column below stays intact for a direct side-by-side comparison.
    private var editorialPostContent: some View {
        let reference = postMediaLayoutReference.cardSize(for: real.id, count: postAttachmentCount)
        return PostEditorialPageLayout(
            isCompact: useSplitLayout,
            referenceHeight: reference.map { max(0, $0.height - 26) },
            previewCaptionHeight: editorialCaptionLineHeight * 2
        ) {
            if showHeader {
                profileButton {
                    HStack(spacing: 10) {
                        avatarView
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .accessibilityIdentifier("experience.real.author.\(real.id.uuidString)")
                            postTimestamp
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, 32)
                    .contentShape(Rectangle())
                }
                .postEditorialRole(.author)
            }
            if !suppressContent {
                if let caption = trimmedMessage {
                    Text(caption)
                        .font(shouldShowMedia ? .body : .title3)
                        .foregroundStyle(.primary)
                        .lineSpacing(shouldShowMedia ? 2 : 4)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("experience.real.caption.\(real.id.uuidString)")
                        .postEditorialRole(.caption)
                }
                if shouldShowMedia {
                    editorialPostPhotos.postEditorialRole(.photos)
                }
            }
            editorialPostActions.postEditorialRole(.actions)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(width: reference?.width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: useSplitLayout ? .infinity : nil, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard useSplitLayout else { return }
            postMediaLayoutReference.recordCard(size, for: real.id, count: postAttachmentCount)
        }
    }

    private var editorialPostActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if !suppressContent, let capsule = capsuleJourney { postBubble(capsule) }
                Spacer(minLength: 0)
                editorialPostEngagement
            }
            // Large accessibility text can use another row without shrinking
            // the tap areas or colliding with the existing Bubble.
            VStack(alignment: .leading, spacing: 8) {
                if !suppressContent, let capsule = capsuleJourney { postBubble(capsule) }
                editorialPostEngagement.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var editorialPostEngagement: some View {
        HStack(spacing: 4) {
            postEngagementButton(.likes, symbol: "heart", count: real.metrics.likeCount)
            postEngagementButton(.comments, symbol: "bubble.right", count: real.metrics.commentCount)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var editorialPostPhotos: some View {
        let sources = Array(collageSources.prefix(6))
        let extraCount = max(0, postAttachmentCount - sources.count)
        return PostEditorialPhotoLayout {
            ForEach(Array(sources.enumerated()), id: \.offset) { element in
                Color(uiColor: .secondarySystemBackground)
                    .overlay { collageTile(for: element.element) }
                    .overlay {
                        if extraCount > 0, element.offset == sources.count - 1 {
                            Rectangle().fill(.black.opacity(0.35))
                            Text("+\(extraCount)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let attachment = extraCount > 0 && element.offset == sources.count - 1
                            ? real.attachments.dropFirst(6).first ?? element.element
                            : element.element
                        handleMediaTap(for: attachment)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(extraCount > 0 && element.offset == sources.count - 1
                        ? "View \(extraCount) more photos"
                        : "View attachment \(element.offset + 1) of \(postAttachmentCount)")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // Posts have one reading column, like a Moments entry. Keep this separate
    // from the POI/video presentation, but reuse the same media and actions.
    private var postCardContent: some View {
        let reference = postMediaLayoutReference.cardSize(for: real.id, count: postAttachmentCount)
        let isRefined = postSheetDesign == .refined
        let isPhotoOnly = isRefined && trimmedMessage == nil && shouldShowMedia
        let columnLayout = isRefined
            ? AnyLayout(PostRefinedColumnLayout(
                isCompact: useSplitLayout,
                referenceHeight: reference.map { max(0, $0.height - 26) },
                previewCaptionHeight: editorialCaptionLineHeight * 2,
                leadingInset: showHeader ? avatarSize + 10 : 0
            ))
            : AnyLayout(PostContentColumnLayout(
                isCompact: useSplitLayout,
                minimumHeight: style == .standard ? max(0, (reference?.height ?? 0) - 26) : 0
            ))
        let readingColumn = columnLayout {
                if showHeader {
                    userNameRow
                        // The expanded card's overflow menu uses this same
                        // quiet corner; leave it free in both states.
                        .padding(.trailing, 36)
                        .frame(minHeight: isPhotoOnly ? avatarSize : nil, alignment: .top)
                        .postContentRole(.header)
                }
                if !suppressContent {
                    if let caption = trimmedMessage {
                        postCaptionContent(caption)
                            .postContentRole(.caption)
                    }
                    if shouldShowMedia {
                        postMedia
                            // Refined measures its media in the full sheet's
                            // coordinate space; the original keeps its gutter.
                            .padding(.trailing, !isRefined && showHeader ? avatarSize + 10 : 0)
                            .postContentRole(.media)
                    }
                }
                // An absent Bubble gives its space back to the caption. The
                // footer remains pinned to the same bottom edge either way.
                if !suppressContent, let capsule = capsuleJourney {
                    HStack {
                        Spacer(minLength: 0)
                        postBubble(capsule)
                    }
                    .frame(height: 44)
                    .postContentRole(.capsule)
                }

                postFooterRow
                    .postContentRole(.footer)
        }
        return Group {
            if isRefined {
                readingColumn.overlay(alignment: .topLeading) {
                    if showHeader { profileButton { avatarView } }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if showHeader { profileButton { avatarView } }
                    readingColumn
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(width: reference?.width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: useSplitLayout ? .infinity : nil, alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard useSplitLayout else { return }
            postMediaLayoutReference.recordCard(size, for: real.id, count: postAttachmentCount)
        }
    }

    private func postCaptionContent(_ caption: String) -> some View {
        Text(caption)
            .font(.subheadline)
            .foregroundStyle(postCardPalette.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            // The column already subtracts photos, Bubble and the footer.
            // Let Text fit whole lines into that remaining height instead of
            // imposing another arbitrary line cap. Expanded text is unbounded.
            .lineLimit(nil)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: style == .standard && postSheetDesign != .refined)
            .accessibilityIdentifier("experience.real.caption.\(real.id.uuidString)")
    }

    private var postTimestamp: some View {
        Text(real.cardDisplayDate.formatted(.relative(presentation: .named)))
            .font(.caption2)
            .foregroundStyle(postCardPalette.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("experience.real.timestamp.\(real.id.uuidString)")
    }

    private var postFooterRow: some View {
        HStack(spacing: 12) {
            postTimestamp
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                postEngagementButton(.likes, symbol: "heart", count: real.metrics.likeCount)
                postEngagementButton(.comments, symbol: "bubble.right", count: real.metrics.commentCount)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func postEngagementButton(_ section: PostEngagementSection, symbol: String, count: Int) -> some View {
        Button { openPostEngagement?(real.id, section) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                ExperienceCommentCount(
                    target: section == .comments && real.visibility != .privateOnly ? .memory(real.id) : nil,
                    fallback: ExperienceDetailView.formatCount(count)
                )
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
            }
            .foregroundStyle(postCardPalette.primary.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(minWidth: 60, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PostEngagementButtonStyle())
        .accessibilityLabel(section == .likes ? "View likes" : "View comments")
        .accessibilityIdentifier("experience.real.\(section.rawValue).\(real.id.uuidString)")
    }

    private func postBubble(_ capsule: JourneyPost) -> some View {
        CapsuleAttachmentCard(
            journey: capsule,
            userProvider: userProvider,
            style: .collapsed,
            usesNeutralAppearance: true,
            isCompact: true,
            maxVisibleCount: 2,
            onTap: onCapsuleTap
        )
        // Include the shared capsule's leading bleed in collision measurement.
        .padding(.leading, 8)
        .fixedSize()
        .shadow(color: .black.opacity(postCardPalette == .black ? 0.16 : 0.04), radius: 4, y: 1)
    }

    @ViewBuilder
    private var postMedia: some View {
        if postSheetDesign == .refined {
            refinedPostMedia
        } else if isSinglePhoto {
            postSinglePhoto
        } else {
            PostPhotoGridLayout {
                ForEach(Array(collageSources.enumerated()), id: \.offset) { element in
                    // The overlay gives the image a bounded proposal. A photo's
                    // intrinsic dimensions must never determine a grid cell.
                    Color(uiColor: .secondarySystemBackground)
                        .overlay { collageTile(for: element.element) }
                        .overlay {
                            if style == .collapsed, overflowCount > 0,
                               element.offset == maxVisibleMediaCount - 1 {
                                Rectangle().fill(.black.opacity(0.38))
                                Text("+\(overflowCount)")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .allowsHitTesting(false)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if style == .collapsed, overflowCount > 0,
                               element.offset == maxVisibleMediaCount - 1 {
                                handleMediaTap(for: real.attachments.dropFirst(maxVisibleMediaCount).first ?? element.element)
                            } else {
                                handleMediaTap(for: element.element)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(style == .collapsed && overflowCount > 0 && element.offset == maxVisibleMediaCount - 1
                            ? "View \(overflowCount) more photos"
                            : "View attachment \(element.offset + 1) of \(postAttachmentCount)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("experience.real.media.\(real.id.uuidString).\(element.offset)")
                }
            }
        }
    }

    @ViewBuilder
    private var refinedPostMedia: some View {
        if isSinglePhoto {
            PostRefinedSinglePhotoLayout(
                centersPhoto: trimmedMessage == nil,
                naturalWidthInset: trimmedMessage == nil && showHeader ? (avatarSize + 10) * 2 : 0
            ) {
                // A single picture is not a collage tile: retain the original
                // reading-column size. Only extreme ratios use a bounded
                // preview window; the lightbox still receives the full source.
                postSinglePhoto
            }
        } else {
            refinedPostPhotoGrid
        }
    }

    private var refinedPostPhotoGrid: some View {
        // Both detents show the same composition. The existing lightbox still
        // holds every attachment, including those behind the +N tile.
        let sources = Array(collageSources.prefix(6))
        let extraCount = max(0, postAttachmentCount - sources.count)
        return PostRefinedPhotoLayout(
            centersGroup: trimmedMessage == nil,
            naturalWidthInset: trimmedMessage == nil && showHeader ? (avatarSize + 10) * 2 : 0
        ) {
            ForEach(Array(sources.enumerated()), id: \.offset) { element in
                Color(uiColor: .secondarySystemBackground)
                    .overlay { collageTile(for: element.element) }
                    .overlay {
                        if extraCount > 0, element.offset == sources.count - 1 {
                            postPhotoOverflow(extraCount)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let attachment = extraCount > 0 && element.offset == sources.count - 1
                            ? real.attachments.dropFirst(6).first ?? element.element
                            : element.element
                        handleMediaTap(for: attachment)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(extraCount > 0 && element.offset == sources.count - 1
                        ? "View \(extraCount) more photos"
                        : "View attachment \(element.offset + 1) of \(postAttachmentCount)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("experience.real.media.\(real.id.uuidString).\(element.offset)")
            }
        }
    }

    private func postPhotoOverflow(_ count: Int) -> some View {
        ZStack {
            if postCardPalette == .black {
                LinearGradient(colors: [.black.opacity(0.28), postCardPalette.background.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Rectangle().fill(.black.opacity(0.38))
            }
            Text("+\(count)")
                .font(.title3.weight(postCardPalette == .black ? .medium : .semibold))
                .foregroundStyle(postCardPalette == .black ? postCardPalette.primary : .white)
        }
        .allowsHitTesting(false)
    }

    private var postSinglePhoto: some View {
        Group {
            if let attachment = real.attachments.first, case let .photo(url) = attachment.kind {
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        if postSheetDesign == .refined {
                            PostSinglePhotoViewportLayout {
                                image.resizable().scaledToFit()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .onAppear { onMediaReady?() }
                        } else {
                            image.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .onAppear { onMediaReady?() }
                        }
                    case .failure:
                        postPhotoPlaceholder(failed: true)
                    default:
                        postPhotoPlaceholder(failed: false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { handleMediaTap(for: attachment) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("View photo")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("experience.real.photo.\(real.id.uuidString).\(attachment.id.uuidString)")
            } else {
                postPhotoPlaceholder(failed: false)
            }
        }
    }

    private func postPhotoPlaceholder(failed: Bool) -> some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var regularCardContent: some View {
        HStack(alignment: .top, spacing: 0) {
            if showHeader && isSingleVideoDetail == false {
                profileButton {
                    avatarView
                }
                    .alignmentGuide(.top) { $0[.top] }
                    .padding(.trailing, 10)
            }

            VStack(alignment: .leading, spacing: style == .collapsed ? (usesNeutralAppearance ? 8 : 6) : 12) {
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

                    if let capsule = capsuleJourney, usesCompactCapsule == false {
                        CapsuleAttachmentCard(
                            journey: capsule,
                            userProvider: userProvider,
                            style: style,
                            usesNeutralAppearance: usesNeutralAppearance,
                            isCompact: usesInlineNeutralCapsule,
                            maxVisibleCount: usesInlineNeutralCapsule ? 3 : nil,
                            onTap: onCapsuleTap
                        )
                        // Compact capsules bleed 8pt left; compensate so the
                        // attachment surface aligns with the photo, not the footer.
                        .padding(.leading, usesInlineNeutralCapsule ? 8 : 0)
                        .frame(maxWidth: style == .standard ? 280 : nil, alignment: .leading)
                    }
                }

                if useSplitLayout {
                    Spacer(minLength: 0)
                }

                if isSingleVideoCollapsed, let capsule = capsuleJourney {
                    CapsuleAttachmentCard(
                        journey: capsule,
                        userProvider: userProvider,
                        style: style,
                        usesNeutralAppearance: usesNeutralAppearance,
                        isCompact: true,
                        maxVisibleCount: 3,
                        onTap: onCapsuleTap
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                if isSingleVideoDetail == false {
                    if shouldOverlayCapsuleOnSinglePhoto {
                        footerRowWithCapsuleOverlay
                    } else {
                        footerRow
                    }
                }
            }
            .frame(maxHeight: useSplitLayout ? .infinity : nil, alignment: .top)
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .padding(.bottom, isSingleVideoCollapsed ? fullBleedVideoBottomPadding : 0)
        .frame(
            maxWidth: .infinity,
            maxHeight: useSplitLayout ? .infinity : nil,
            alignment: .topLeading
        )
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
        usesNeutralAppearance ? 36 : (style == .collapsed ? 34 : 40)
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
        case .privateOnly:
            return Color.white.opacity(0.82)
        }
    }

    private var maxVisibleMediaCount: Int {
        usesNeutralAppearance ? (style == .collapsed ? 6 : 9) : (style == .collapsed ? 3 : 9)
    }

    private var postAttachmentCount: Int {
        min(9, expectedMedia.isEmpty ? real.attachments.count : expectedMedia.count)
    }

    private var isSinglePhoto: Bool {
        if !expectedMedia.isEmpty {
            return expectedMedia.count == 1 && expectedMedia.first?.kind == .photo
        }
        guard real.attachments.count == 1,
              let attachment = real.attachments.first,
              case .photo = attachment.kind else {
            return false
        }
        return true
    }

    private var isSingleVideo: Bool {
        if !expectedMedia.isEmpty {
            return expectedMedia.count == 1 && expectedMedia.first?.kind == .video
        }
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

    private var isSingleVideoCollapsed: Bool {
        style == .collapsed && isSingleVideo && useSplitLayout
    }

    private var usesCompactCapsule: Bool {
        isSingleVideoDetail || isSingleVideoCollapsed || shouldOverlayCapsuleOnSinglePhoto
    }

    private var shouldOverlayCapsuleOnSinglePhoto: Bool {
        !usesNeutralAppearance && isSinglePhoto && capsuleJourney != nil && style == .collapsed
    }

    private var usesInlineNeutralCapsule: Bool {
        usesNeutralAppearance && style == .collapsed && !isSingleVideoCollapsed
    }

    private var minimumSinglePhotoHeight: CGFloat {
        // Make room for the attachment row without enlarging the map sheet or
        // pushing engagement controls offscreen. Plain photo posts stay large.
        usesInlineNeutralCapsule && capsuleJourney != nil ? 160 : singlePhotoHeight
    }

    // Give the neutral Post's photo more of the existing card, rather than
    // increasing the sheet height or cropping it. This also absorbs the large
    // empty gap above the footer while keeping its controls in a stable place.
    private var singlePhotoHeight: CGFloat { usesNeutralAppearance ? 192 : 160 }

    private var singleVideoLeadingInset: CGFloat {
        if isSingleVideoDetail {
            return horizontalPadding
        }
        return showHeader ? (avatarSize + 10 + horizontalPadding) : horizontalPadding
    }

    private var singleVideoTrailingInset: CGFloat { horizontalPadding }

    // Only the Posts viewport extends under the home indicator. Keep its
    // controls inset while letting the video itself reach the sheet edge.
    private var fullBleedVideoBottomPadding: CGFloat {
        singleVideoViewportHeight == nil ? 0 : 24
    }

    private var overflowCount: Int {
        max(0, (expectedMedia.isEmpty ? real.attachments.count : expectedMedia.count) - maxVisibleMediaCount)
    }

    private var textLineLimit: Int {
        style == .collapsed ? 1 : 3
    }

    private var userNameRow: some View {
        profileButton {
            Text(displayName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(usesNeutralAppearance ? postCardPalette.primary : .white)
                .lineLimit(usesNeutralAppearance ? 1 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("experience.real.author.\(real.id.uuidString)")
        }
    }

    private var avatarView: some View {
        Group {
            if let category = avatarCategory {
                POICategoryAvatar(category: category, size: avatarSize)
            } else if let url = user?.avatarURL {
                MapImage(url: url) { phase in
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName) avatar")
        .accessibilityIdentifier("experience.real.avatar.\(real.id.uuidString)")
    }

    private var displayName: String {
        displayNameOverride ?? user?.handle ?? "Unknown user"
    }

    private var displayInitials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "??" }
        return String(trimmed.prefix(2)).uppercased()
    }

    @ViewBuilder
    private func profileButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let user, avatarCategory == nil, let onUserSelected {
            Button {
                onUserSelected(user)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    @ViewBuilder
    private var contentText: some View {
        if let caption = PostCaption.visibleText(real.message) {
            Text(caption)
                .font(.subheadline.weight(usesNeutralAppearance ? .regular : .semibold))
                .foregroundStyle(usesNeutralAppearance ? Color.primary : .white)
                .lineLimit(textLineLimit)
                .accessibilityIdentifier("experience.real.caption.\(real.id.uuidString)")
        }
    }

    private var trimmedMessage: String? { PostCaption.visibleText(real.message) }

    private var hasMedia: Bool {
        !expectedMedia.isEmpty || !real.attachments.isEmpty
    }

    private var capsuleJourney: JourneyPost? {
        guard let capsuleId = real.capsuleId else { return nil }
        return journeyProvider(capsuleId)
    }

    private var shouldShowMedia: Bool {
        hasMedia && hideMedia == false
    }

    private var useSplitLayout: Bool {
        style == .collapsed && useTallLayout
    }

    private var collageSources: [RealPost.Attachment?] {
        guard hasMedia else { return [] }
        if !expectedMedia.isEmpty {
            let available = Dictionary(real.attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return expectedMedia.prefix(maxVisibleMediaCount).map { available[$0.id] }
        }
        return Array(real.attachments.prefix(maxVisibleMediaCount)).map { Optional($0) }
    }

    @ViewBuilder
    private func collageTile(for attachment: RealPost.Attachment?) -> some View {
        if let attachment {
            attachmentThumbnail(for: attachment)
        } else if !expectedMedia.isEmpty {
            loadingMediaTile
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
                    MapImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                                .onAppear { onMediaReady?() }
                        case .empty:
                            ProgressView()
                        case .failure:
                            previewFallback(symbol: "photo")
                        @unknown default:
                            previewFallback(symbol: "photo")
                        }
                    }
                    .frame(minHeight: minimumSinglePhotoHeight,
                           idealHeight: singlePhotoHeight, maxHeight: singlePhotoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleMediaTap(for: attachment)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("View photo")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("experience.real.photo.\(real.id.uuidString).\(attachment.id.uuidString)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !expectedMedia.isEmpty {
                loadingMediaTile.frame(minHeight: minimumSinglePhotoHeight,
                    idealHeight: singlePhotoHeight, maxHeight: singlePhotoHeight)
            }
        }
    }

    private var singleVideoRow: some View {
        Group {
            if let attachment = real.attachments.first,
               case let .video(url, poster) = attachment.kind {
                ExperienceDetailView.AutoPlayVideoView(
                    url: url,
                    poster: poster,
                    accentColor: lightboxAccentColor,
                    mode: ExperienceDetailView.MediaCardView.Mode.card,
                    usesAspectFit: false,
                    isMuted: false,
                    isPlaybackActive: isPlaybackActive && !isLightboxPresented
                )
                .modifier(SingleVideoViewport(height: singleVideoViewportHeight))
                .background(Color.black)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    handleMediaTap(for: attachment)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Play video")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("experience.real.video.\(real.id.uuidString)")
                // The text/footer are visual-only. Leaving their full-size
                // overlay hit-testable blocks the pager's horizontal drag.
                .overlay(singleVideoOverlay)
                // Only the compact Journey capsule itself is interactive; it
                // stays above the video's tap target without swallowing swipes.
                .overlay(alignment: .bottomLeading) {
                    singleVideoJourneyCapsuleOverlay
                }
            } else if !expectedMedia.isEmpty {
                loadingMediaTile.modifier(SingleVideoViewport(height: singleVideoViewportHeight))
            }
        }
    }

    private var singleVideoOverlay: some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if showHeader {
                    avatarView
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("experience.real.author.\(real.id.uuidString)")
                    if suppressContent == false {
                        contentText
                    }
                }
            }

            Spacer(minLength: 0)
            footerRow
        }
        .padding(.top, 12)
        .padding(.bottom, 12 + fullBleedVideoBottomPadding)
        .padding(.leading, singleVideoLeadingInset)
        .padding(.trailing, singleVideoTrailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var singleVideoJourneyCapsuleOverlay: some View {
        if let capsule = capsuleJourney {
            CapsuleAttachmentCard(
                journey: capsule,
                userProvider: userProvider,
                style: style,
                usesNeutralAppearance: usesNeutralAppearance,
                isOverMedia: true,
                isCompact: true,
                maxVisibleCount: 3,
                onTap: onCapsuleTap
            )
            .padding(.leading, singleVideoLeadingInset)
            .padding(.trailing, singleVideoTrailingInset)
            .padding(.bottom, 42 + fullBleedVideoBottomPadding)
            .allowsHitTesting(onCapsuleTap != nil)
        }
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
                        .overlay(alignment: .trailing) {
                            collapsedOverflowOverlay(for: element.offset, tileSize: size)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .overlay(alignment: .trailing) {
                        standardOverflowOverlay(for: element.offset, tileSize: standardTileSize)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleMediaTap(for: element.element)
                    }
            }
        }
    }

    private var footerRow: some View {
        HStack {
            Text(real.cardDisplayDate.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(usesNeutralAppearance ? Color.secondary : .white.opacity(0.7))
                .lineLimit(usesNeutralAppearance ? 1 : nil)
                .accessibilityIdentifier("experience.real.timestamp.\(real.id.uuidString)")

            Spacer()

            engagementMetrics
        }
        .frame(maxWidth: .infinity)
    }

    private var engagementMetrics: some View {
        HStack(spacing: 10) {
            metricsPill(
                symbol: "heart.fill",
                text: ExperienceDetailView.formatCount(real.metrics.likeCount)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(real.metrics.likeCount) likes")
            .accessibilityIdentifier("experience.real.likes.\(real.id.uuidString)")
            metricsPill(
                symbol: "bubble.right.fill",
                text: ExperienceDetailView.formatCount(real.metrics.commentCount),
                commentTarget: real.visibility == .privateOnly ? nil : .memory(real.id)
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var footerRowWithCapsuleOverlay: some View {
        footerRow
            .overlay(alignment: .topTrailing) {
            if let capsule = capsuleJourney {
                CapsuleAttachmentCard(
                    journey: capsule,
                    userProvider: userProvider,
                    style: style,
                    usesNeutralAppearance: usesNeutralAppearance,
                    isOverMedia: true,
                    isCompact: true,
                    maxVisibleCount: 3,
                    onTap: onCapsuleTap
                )
                .background(CapsuleOverlayHeightReader())
                .offset(y: -(max(capsuleOverlayHeight, 0) + 4))
            }
        }
        .onPreferenceChange(CapsuleOverlayHeightPreferenceKey.self) { newValue in
            if abs(newValue - capsuleOverlayHeight) > 0.5 {
                capsuleOverlayHeight = newValue
            }
        }
    }

    private struct CapsuleOverlayHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct CapsuleOverlayHeightReader: View {
        var body: some View {
            GeometryReader { proxy in
                Color.clear.preference(key: CapsuleOverlayHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    private func handleMediaTap(for attachment: RealPost.Attachment?) {
        guard expectedMedia.isEmpty || attachment != nil else { return }
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
                        .fill(Color.black.opacity(usesNeutralAppearance ? 0.4 : 0.55))
                        .frame(width: tileSize, height: tileSize)
                    Text("+\(overflowCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(usesNeutralAppearance ? 0 : 0.35), radius: 4, y: 2)
                }
                .allowsHitTesting(false)
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

    @ViewBuilder
    private func metricsPill(symbol: String, text: String, commentTarget: BackendCommentTarget? = nil) -> some View {
        if usesNeutralAppearance {
            metricLabel(symbol: symbol, text: text, commentTarget: commentTarget)
                .padding(.vertical, 4)
        } else {
            metricLabel(symbol: symbol, text: text, commentTarget: commentTarget)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule(style: .continuous))
        }
    }

    private func metricLabel(symbol: String, text: String, commentTarget: BackendCommentTarget?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: usesNeutralAppearance ? symbol.replacingOccurrences(of: ".fill", with: "") : symbol)
                .font(.caption.weight(.semibold))
            ExperienceCommentCount(target: commentTarget, fallback: text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(usesNeutralAppearance ? Color.secondary : .white.opacity(0.85))
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
            MapImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .onAppear { onMediaReady?() }
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
                if !usesNeutralAppearance {
                    LinearGradient(
                        colors: [.black.opacity(0.05), .black.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        case let .video(_, poster):
            ZStack {
                if let poster {
                    MapImage(url: poster) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                                .onAppear { onMediaReady?() }
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
                    .overlay { Color.black.opacity(usesNeutralAppearance ? 0 : 0.25) }
                } else {
                    previewFallback(symbol: "play.rectangle.fill")
                }

                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(usesNeutralAppearance ? Color.black.opacity(0.8) : Theme.neonPrimary)
                            .offset(x: 1.5)
                    }
                    .shadow(color: .black.opacity(usesNeutralAppearance ? 0.12 : 0.35), radius: 6, y: 3)
            }
        case let .emoji(emoji):
            Group {
                if usesNeutralAppearance {
                    Color(uiColor: .secondarySystemBackground)
                } else {
                    LinearGradient(
                        colors: [Theme.neonPrimary.opacity(0.85), Theme.neonAccent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .overlay {
                Text(emoji)
                    .font(.system(size: 48))
                    .shadow(color: .black.opacity(usesNeutralAppearance ? 0 : 0.3), radius: 6, y: 3)
            }
        }
    }

    @ViewBuilder
    private func previewFallback(symbol: String) -> some View {
        if usesNeutralAppearance {
            Color(uiColor: .secondarySystemBackground).overlay {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            }
        } else {
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
    }

    private var loadingMediaTile: some View {
        ProgressView()
            .tint(usesNeutralAppearance ? .secondary : .white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(usesNeutralAppearance ? Color(uiColor: .secondarySystemBackground) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Loading media")
    }

    private func previewTextCard(_ text: String) -> some View {
        Group {
            if usesNeutralAppearance {
                Color(uiColor: .secondarySystemBackground)
            } else {
                LinearGradient(
                    colors: [Theme.neonPrimary.opacity(0.28), Theme.neonAccent.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .topLeading) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(usesNeutralAppearance ? Color.primary : .white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(12)
        }
    }

    private struct CapsuleAttachmentCard: View {
        let journey: JourneyPost
        let userProvider: (UUID) -> User?
        let style: CompactRealCard.Style
        let usesNeutralAppearance: Bool
        let isOverMedia: Bool
        let isCompact: Bool
        let maxVisibleCount: Int?
        let onTap: ((JourneyPost) -> Void)?
        @Environment(\.postCardPalette) private var postCardPalette

        init(
            journey: JourneyPost,
            userProvider: @escaping (UUID) -> User?,
            style: CompactRealCard.Style,
            usesNeutralAppearance: Bool = false,
            isOverMedia: Bool = false,
            isCompact: Bool = false,
            maxVisibleCount: Int? = nil,
            onTap: ((JourneyPost) -> Void)? = nil
        ) {
            self.journey = journey
            self.userProvider = userProvider
            self.style = style
            self.usesNeutralAppearance = usesNeutralAppearance
            self.isOverMedia = isOverMedia
            self.isCompact = isCompact
            self.maxVisibleCount = maxVisibleCount
            self.onTap = onTap
        }

        var body: some View {
            label
        }

        private var label: some View {
            JourneyAttachmentCapsule(
                journey: journey,
                userProvider: userProvider,
                isCompact: isCompact,
                isCollapsed: style == .collapsed,
                maxVisibleCount: maxVisibleCount,
                appearance: postCardPalette == .black ? .postDark
                    : usesNeutralAppearance ? (isOverMedia ? .mediaOverlay : .neutral) : .standard,
                onTap: onTap.map { handler in { handler(journey) } }
            )
        }
    }

    private var avatarBadge: some View {
        Group {
            if let url = user?.avatarURL {
                MapImage(url: url) { phase in
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
                MapImage(url: url) { phase in
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

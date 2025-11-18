import SwiftUI

// MARK: - Real detail sections

extension ExperienceDetailView {
struct LikesAvatarGrid: View {
    let entries: [FriendEngagement]
    let iconName: String
    let storyContributors: [ExperienceDetailView.POIStoryContributor]
    let accentColor: Color

    @State private var viewerState: POIStoryViewerState?

    private let columns: [GridItem] = {
        let availableWidth = UIScreen.main.bounds.width - (ExperienceSheetLayout.engagementHorizontalInset * 2) - 16
        let count = 6
        let spacing: CGFloat = 8
        let totalSpacing = spacing * CGFloat(count - 1)
        let tileWidth = max((availableWidth - totalSpacing) / CGFloat(count), 34)
        return Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: count)
    }()
    private let leadingInset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    if let info = contributorInfo(for: entry.userId) {
                        Button {
                            viewerState = POIStoryViewerState(contributorIndex: info.index)
                        } label: {
                            AvatarSquare(
                                user: entry.user,
                                endorsement: entry.endorsement,
                                highlight: highlightStyle(for: info.contributor)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        AvatarSquare(user: entry.user, endorsement: entry.endorsement)
                    }
                }
            }
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ExperienceSheetLayout.engagementHorizontalInset)
        .fullScreenCover(item: $viewerState) { state in
            POIStoryViewer(
                contributors: storyContributors,
                initialIndex: state.contributorIndex,
                accentColor: accentColor
            ) {
                viewerState = nil
            }
            .preferredColorScheme(.dark)
        }
    }

    private func contributorInfo(for userId: UUID?) -> (contributor: ExperienceDetailView.POIStoryContributor, index: Int)? {
        guard let userId, let index = storyIndexMap[userId], storyContributors.indices.contains(index) else {
            return nil
        }
        return (storyContributors[index], index)
    }

    private func highlightStyle(for contributor: ExperienceDetailView.POIStoryContributor) -> AvatarSquare.HighlightStyle {
        let delta = Date().timeIntervalSince(contributor.mostRecent)
        if delta <= recentStoryWindow {
            return .recent(accent: accentColor)
        }
        return .past(accent: accentColor)
    }

    private var recentStoryWindow: TimeInterval { 60 * 60 * 24 }

    private var storyIndexMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, contributor) in storyContributors.enumerated() {
            map[contributor.id] = index
        }
        return map
    }
}

struct POIStoryViewerState: Identifiable {
    let contributorIndex: Int
    var id: Int { contributorIndex }
}

struct POIStoryViewer: View {
    let contributors: [ExperienceDetailView.POIStoryContributor]
    let initialIndex: Int
    let accentColor: Color
    let onClose: () -> Void

    @State private var contributorIndex: Int
    @State private var itemIndex: Int = 0
    @State private var contributorTransitionDirection: ContributorTransitionDirection = .none
    @State private var dragOffset: CGFloat = 0
    @State private var dragCompletion: DragCompletion?

    init(
        contributors: [ExperienceDetailView.POIStoryContributor],
        initialIndex: Int,
        accentColor: Color,
        onClose: @escaping () -> Void
    ) {
        self.contributors = contributors
        self.initialIndex = initialIndex
        self.accentColor = accentColor
        self.onClose = onClose
        _contributorIndex = State(initialValue: min(max(initialIndex, 0), max(contributors.count - 1, 0)))
    }

    var body: some View {
        GeometryReader { geometry in
            let contributor = currentContributor
            ZStack {
                Color.black.ignoresSafeArea(.all)

                if let contributor {
            storyStage(width: geometry.size.width, contributor: contributor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(contributorTransition)
                .gesture(contributorDragGesture(containerWidth: geometry.size.width))
                } else {
                    Color.black
                        .ignoresSafeArea(.all)
                        .onAppear {
                            onClose()
                        }
                }
            }
        }
    }

    private var currentContributor: ExperienceDetailView.POIStoryContributor? {
        guard contributors.indices.contains(contributorIndex) else { return nil }
        return contributors[contributorIndex]
    }

    private var contributorTransition: AnyTransition {
        contributorTransitionDirection.transition
    }

    private var contributorTransitionAnimation: Animation {
        .spring(response: 0.55, dampingFraction: 0.85, blendDuration: 0.18)
    }

    private func storyStage(width: CGFloat, contributor: ExperienceDetailView.POIStoryContributor) -> some View {
        let offset = dragOffsetForDisplay(width: width)
        let progress = dragProgress(width: width)
        let direction = activeDragDirection
        let preview = previewContributor
        let headerContext = headerDisplayContext(
            current: contributor,
            preview: preview,
            direction: direction,
            progress: progress
        )
        let preloadTargets = preloadContributors(around: contributor)

        let activeCard = storyCard(for: contributor, direction: .none)
            .scaleEffect(direction == .none ? 1 : (1 - 0.05 * progress))
            .rotation3DEffect(
                .degrees(
                    direction == .forward
                        ? Double(-18 * progress)
                        : direction == .backward
                            ? Double(18 * progress)
                            : 0
                ),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.85
            )
            .offset(x: offset)
            .opacity(direction == .none ? 1 : (1 - 0.4 * Double(progress)))

        return ZStack {
            ForEach(preloadTargets, id: \.id) { target in
                storyCard(for: target, direction: .none)
                    .opacity(0)
                    .allowsHitTesting(false)
            }

            activeCard

            if let preview {
                storyCard(for: preview, direction: direction)
                    .offset(x: previewOffset(width: width))
                    .rotation3DEffect(
                        .degrees(
                            direction == .forward
                                ? Double(12 * (1 - progress))
                                : direction == .backward
                                    ? Double(-12 * (1 - progress))
                                    : 0
                        ),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.9
                    )
                    .opacity(Double(progress))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            header(for: headerContext.contributor, activeItem: headerContext.item)
                .padding(.top, 60)
                .padding(.horizontal, 20)
        }
    }

    private func preloadContributors(
        around contributor: ExperienceDetailView.POIStoryContributor
    ) -> [ExperienceDetailView.POIStoryContributor] {
        guard let index = contributors.firstIndex(where: { $0.id == contributor.id }) else { return [] }
        var targets: [ExperienceDetailView.POIStoryContributor] = []
        let neighborIndices = [index - 1, index + 1]
        for idx in neighborIndices {
            if contributors.indices.contains(idx) {
                targets.append(contributors[idx])
            }
        }
        return targets
    }

    private func headerDisplayContext(
        current: ExperienceDetailView.POIStoryContributor,
        preview: ExperienceDetailView.POIStoryContributor?,
        direction: ContributorTransitionDirection,
        progress: CGFloat
    ) -> (contributor: ExperienceDetailView.POIStoryContributor, item: ExperienceDetailView.POIStoryContributor.Item?) {
        if progress > 0.5,
           direction != .none,
           let preview {
            let index = activeItemIndex(for: preview, direction: direction)
            return (preview, contributorItem(preview, at: index))
        }

        let index = activeItemIndex(for: current, direction: .none)
        return (current, contributorItem(current, at: index))
    }

    private func storyCard(
        for contributor: ExperienceDetailView.POIStoryContributor,
        direction: ContributorTransitionDirection
    ) -> some View {
        let activeIndex = activeItemIndex(for: contributor, direction: direction)

        return mediaContent(for: contributor, itemIndex: activeIndex)
            .overlay {
                if direction == .none {
                    storyNavigationOverlay
                }
            }
            .overlay(alignment: .top) {
                storyProgress(for: contributor, activeIndex: activeIndex)
                    .padding(.top, 28)
                    .padding(.horizontal, 20)
            }
            .overlay(alignment: .bottom) {
                actionBar
                    .padding(.horizontal, 24)
            }
    }

    private func mediaContent(
        for contributor: ExperienceDetailView.POIStoryContributor,
        itemIndex: Int
    ) -> some View {
        GeometryReader { proxy in
            ZStack {
                if let item = contributorItem(contributor, at: itemIndex) {
                    MediaCardView(item: item.media, accentColor: accentColor, mode: .lightbox)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Color.black
                }
            }
        }
    }

    private func storyProgress(
        for contributor: ExperienceDetailView.POIStoryContributor,
        activeIndex: Int
    ) -> some View {
        let clampedIndex = min(activeIndex, max(contributor.items.count - 1, 0))
        return HStack(spacing: 4) {
            ForEach(contributor.items.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= clampedIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(height: 4)
            }
        }
    }

    private func header(
        for contributor: ExperienceDetailView.POIStoryContributor,
        activeItem: ExperienceDetailView.POIStoryContributor.Item?
    ) -> some View {
        HStack(spacing: 12) {
            POIStoryAvatarView(contributor: contributor)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(contributor.user?.handle ?? "Friend")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                if let timestamp = activeItem?.timestamp {
                    Text(timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 24) {
            storyActionButton(icon: "heart", label: "Like")
            storyActionButton(icon: "bubble.left.and.bubble.right", label: "Message")
            storyActionButton(icon: "paperplane", label: "Share")
        }
    }

    private func storyActionButton(icon: String, label: String) -> some View {
        Button { } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(label)
                    .font(.caption2.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var storyNavigationOverlay: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    goToPreviousItem()
                }
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    goToNextItem()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func goToNextItem() {
        guard let contributor = currentContributor else { return }
        if contributor.items.indices.contains(itemIndex + 1) {
            itemIndex += 1
        } else {
            goToNextContributor()
        }
    }

    private func goToPreviousItem() {
        if itemIndex > 0 {
            itemIndex -= 1
        } else {
            goToPreviousContributor()
        }
    }

    private func goToNextContributor(animated: Bool = true) {
        guard let targetIndex = targetIndex(for: .forward) else {
            onClose()
            return
        }
        changeContributor(to: targetIndex, direction: .forward, animated: animated)
    }

    private func goToPreviousContributor(animated: Bool = true) {
        guard let targetIndex = targetIndex(for: .backward) else {
            onClose()
            return
        }
        changeContributor(to: targetIndex, direction: .backward, animated: animated)
    }

    private func changeContributor(
        to newIndex: Int,
        direction: ContributorTransitionDirection,
        animated: Bool
    ) {
        guard contributors.indices.contains(newIndex) else { return }
        let newItemIndex: Int
        switch direction {
        case .forward, .none:
            newItemIndex = 0
        case .backward:
            newItemIndex = max(contributors[newIndex].items.count - 1, 0)
        }

        let updateState = {
            contributorIndex = newIndex
            itemIndex = newItemIndex
        }

        if animated {
            contributorTransitionDirection = direction
            withAnimation(contributorTransitionAnimation) {
                updateState()
            }
        } else {
            contributorTransitionDirection = .none
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                updateState()
            }
        }
    }

    private func contributorDragGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard dragCompletion == nil else { return }
                dragOffset = clampedDragOffset(value.translation.width, limit: containerWidth)
            }
            .onEnded { value in
                guard dragCompletion == nil else { return }
                finishDrag(
                    translation: clampedDragOffset(value.translation.width, limit: containerWidth),
                    predicted: clampedDragOffset(value.predictedEndTranslation.width, limit: containerWidth),
                    width: containerWidth
                )
            }
    }

    private func finishDrag(translation: CGFloat, predicted: CGFloat, width: CGFloat) {
        let direction: ContributorTransitionDirection
        if translation < -2 {
            direction = .forward
        } else if translation > 2 {
            direction = .backward
        } else {
            direction = .none
        }

        guard direction != .none else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.15)) {
                dragOffset = 0
            }
            return
        }

        guard targetIndex(for: direction) != nil else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.15)) {
                dragOffset = 0
            }
            return
        }

        let threshold = max(60, width * 0.25)
        let shouldAdvance = abs(translation) > threshold || abs(predicted - translation) > threshold
        if shouldAdvance {
            commitDrag(direction: direction, containerWidth: width)
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.15)) {
                dragOffset = 0
            }
        }
    }

    private func commitDrag(direction: ContributorTransitionDirection, containerWidth: CGFloat) {
        guard let targetIndex = targetIndex(for: direction) else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.15)) {
                dragOffset = 0
            }
            return
        }
        dragCompletion = DragCompletion(direction: direction, targetIndex: targetIndex)
        let targetOffset = direction == .forward ? -containerWidth : containerWidth
        withAnimation(.easeInOut(duration: 0.22)) {
            dragOffset = targetOffset
        }
        let delay = DispatchTime.now() + .milliseconds(240)
        DispatchQueue.main.asyncAfter(deadline: delay) { [direction] in
            guard dragCompletion?.targetIndex == targetIndex else { return }
            changeContributor(to: targetIndex, direction: direction, animated: false)
            dragOffset = 0
            dragCompletion = nil
        }
    }

    private func clampedDragOffset(_ translation: CGFloat, limit: CGFloat) -> CGFloat {
        let maximum = max(1, limit)
        return min(max(translation, -maximum), maximum)
    }

    private func dragOffsetForDisplay(width: CGFloat) -> CGFloat {
        clampedDragOffset(dragOffset, limit: width)
    }

    private func dragProgress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(abs(dragOffsetForDisplay(width: width)) / width, 1)
    }

    private func previewOffset(width: CGFloat) -> CGFloat {
        guard activeDragDirection != .none else { return 0 }
        let base = activeDragDirection == .forward ? width : -width
        return base + dragOffsetForDisplay(width: width)
    }

    private var previewContributor: ExperienceDetailView.POIStoryContributor? {
        guard let targetIndex = targetIndex(for: activeDragDirection) else { return nil }
        return contributors[targetIndex]
    }

    private func targetIndex(for direction: ContributorTransitionDirection) -> Int? {
        switch direction {
        case .forward:
            let next = contributorIndex + 1
            return contributors.indices.contains(next) ? next : nil
        case .backward:
            let previous = contributorIndex - 1
            return contributors.indices.contains(previous) ? previous : nil
        case .none:
            return nil
        }
    }

    private var activeDragDirection: ContributorTransitionDirection {
        if let completion = dragCompletion {
            return completion.direction
        }
        if dragOffset < -2 {
            return .forward
        } else if dragOffset > 2 {
            return .backward
        } else {
            return .none
        }
    }

    private func contributorItem(
        _ contributor: ExperienceDetailView.POIStoryContributor,
        at index: Int
    ) -> ExperienceDetailView.POIStoryContributor.Item? {
        guard contributor.items.indices.contains(index) else { return nil }
        return contributor.items[index]
    }

    private func activeItemIndex(
        for contributor: ExperienceDetailView.POIStoryContributor,
        direction: ContributorTransitionDirection
    ) -> Int {
        switch direction {
        case .forward:
            return 0
        case .backward:
            return max(contributor.items.count - 1, 0)
        case .none:
            return min(itemIndex, max(contributor.items.count - 1, 0))
        }
    }
}

struct DragCompletion {
    let direction: ContributorTransitionDirection
    let targetIndex: Int
}

enum ContributorTransitionDirection {
    case none
    case forward
    case backward

    var transition: AnyTransition {
        switch self {
        case .none:
            return .identity
        case .forward:
            return .asymmetric(
                insertion: .modifier(
                    active: StoryPerspectiveModifier(angle: -28, offset: 220, opacity: 0),
                    identity: .identity
                ),
                removal: .modifier(
                    active: StoryPerspectiveModifier(angle: 28, offset: -220, opacity: 0),
                    identity: .identity
                )
            )
        case .backward:
            return .asymmetric(
                insertion: .modifier(
                    active: StoryPerspectiveModifier(angle: 28, offset: -220, opacity: 0),
                    identity: .identity
                ),
                removal: .modifier(
                    active: StoryPerspectiveModifier(angle: -28, offset: 220, opacity: 0),
                    identity: .identity
                )
            )
        }
    }
}

struct StoryPerspectiveModifier: ViewModifier {
    let angle: Double
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.85)
            .offset(x: offset)
            .opacity(opacity)
    }

    static var identity: StoryPerspectiveModifier {
        StoryPerspectiveModifier(angle: 0, offset: 0, opacity: 1)
    }
}

struct POIStoryAvatarView: View {
    let contributor: ExperienceDetailView.POIStoryContributor

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Theme.neonPrimary,
                            Theme.neonAccent,
                            Theme.neonWarning,
                            Theme.neonPrimary
                        ]),
                        center: .center
                    ),
                    lineWidth: 3
                )
                .shadow(color: Theme.neonPrimary.opacity(0.5), radius: 10, y: 4)

            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            avatarContent
                .frame(width: 64, height: 64)
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let url = contributor.user?.avatarURL {
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

    private var placeholder: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
    }

    private var initials: String {
        guard let handle = contributor.user?.handle else { return "?" }
        return String(handle.prefix(2)).uppercased()
    }
}

struct AvatarSquare: View {
    let user: User?
    var size: CGFloat = 44
    var endorsement: RatedPOI.Endorsement? = nil
    var highlight: HighlightStyle = .none

    enum HighlightStyle {
        case none
        case recent(accent: Color)
        case past(accent: Color)
    }

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(baseStrokeOpacity), lineWidth: 1)
            }
            .overlay { highlightOverlay }
            .overlay(alignment: .bottomTrailing) {
                endorsementBadge
            }
    }

    private var baseStrokeOpacity: Double {
        switch highlight {
        case .none:
            return 0.3
        default:
            return 0.2
        }
    }

    @ViewBuilder
    private var highlightOverlay: some View {
        switch highlight {
        case .none:
            EmptyView()
        case let .recent(accent):
            let colors: [Color] = [
                Color.blue,
                Color.cyan,
                accent,
                Color.indigo,
                Color.blue
            ]
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: colors),
                        center: .center
                    ),
                    lineWidth: 3.5
                )
                .padding(-4.5)
                .shadow(color: Color.cyan.opacity(0.45), radius: 7, y: 3)
        case let .past(accent):
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 2.4)
                .padding(-4)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.65), accent.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                        .padding(-5.4)
                }
        }
    }

    private var avatarContent: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        avatarPlaceholder
                    default:
                        ProgressView()
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
    }

    @ViewBuilder
    private var endorsementBadge: some View {
        if let endorsement {
            EndorsementBadgeIcon(endorsement: endorsement, size: 20)
                .offset(x: endorsementOffset.x, y: endorsementOffset.y)
        }
    }

    private var endorsementOffset: CGPoint {
        guard let endorsement else {
            return CGPoint(x: 5, y: 5)
        }
        if endorsement == .hype {
            let delta = size * 0.12
            return CGPoint(x: 5 + delta, y: 5 + delta)
        }
        return CGPoint(x: 5, y: 5)
    }

    private var avatarPlaceholder: some View {
        Text(initials)
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
    }

    private var initials: String {
        guard let handle = user?.handle else { return "??" }
        return String(handle.prefix(2)).uppercased()
    }
}

struct CommentThreadList: View {
    let entries: [FriendEngagement]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 14) {
                ForEach(entries) { entry in
                    CommentThreadRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, ExperienceSheetLayout.engagementHorizontalInset)
    }
}

struct CommentThreadRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarSquare(user: entry.user)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestamp = entry.timestamp?.formatted(.relative(presentation: .named)) {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.95))

                if entry.replies.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.replies) { reply in
                            CommentReplyRow(entry: reply)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct CommentReplyRow: View {
    let entry: FriendEngagement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarSquare(user: entry.user, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.user?.handle ?? "Friend")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let timestamp = entry.timestamp?.formatted(.relative(presentation: .named)) {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}
}

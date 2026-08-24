import SwiftUI

struct RealStoriesRow: View {
    static let layoutHeight: CGFloat = 108

    enum DisplayMode {
        case people
        case content
    }

    struct POISharer: Identifiable {
        let id: UUID
        let user: User?
        let timestamp: Date
        let hasStory: Bool
        let readKeys: [String]
    }

    struct POIStoryGroup: Identifiable {
        let ratedPOI: RatedPOI
        let sharers: [POISharer]
        let latestTimestamp: Date

        var id: UUID { ratedPOI.id }
        var poiName: String { ratedPOI.poi.name }
        var category: POICategory { ratedPOI.poi.category }
        var primarySharers: [POISharer] { sharers }

        var unreadCandidateKeys: [String] {
            sharers
                .filter { $0.hasStory && StoryReadKeys.isFresh($0.timestamp) }
                .flatMap(\.readKeys)
        }
    }

    struct StoryItem: Identifiable {
        enum Source {
            case real(RealPost)
            case poi(POIStoryGroup)
            case journey(JourneyPost)
        }

        let source: Source
        let timestamp: Date

        var id: UUID {
            switch source {
            case let .real(real):
                return real.id
            case let .poi(group):
                return group.id
            case let .journey(journey):
                return journey.id
            }
        }

        init(real: RealPost) {
            source = .real(real)
            timestamp = real.createdAt
        }

        init(poiGroup: POIStoryGroup) {
            source = .poi(poiGroup)
            timestamp = poiGroup.latestTimestamp
        }

        init(journey: JourneyPost) {
            source = .journey(journey)
            timestamp = journey.createdAt
        }
    }

    let items: [StoryItem]
    let selectedId: UUID?
    let onSelectReal: (RealPost) -> Void
    let onSelectPOIGroup: (POIStoryGroup) -> Void
    let onSelectJourney: (JourneyPost) -> Void
    let userProvider: (UUID) -> User?
    let alignTrigger: Int
    let displayMode: DisplayMode
    let isUnseen: (StoryItem) -> Bool

    init(
        items: [StoryItem],
        selectedId: UUID?,
        onSelectReal: @escaping (RealPost) -> Void,
        onSelectPOIGroup: @escaping (POIStoryGroup) -> Void,
        onSelectJourney: @escaping (JourneyPost) -> Void,
        userProvider: @escaping (UUID) -> User?,
        alignTrigger: Int,
        displayMode: DisplayMode = .people,
        isUnseen: @escaping (StoryItem) -> Bool = { _ in false }
    ) {
        self.items = items
        self.selectedId = selectedId
        self.onSelectReal = onSelectReal
        self.onSelectPOIGroup = onSelectPOIGroup
        self.onSelectJourney = onSelectJourney
        self.userProvider = userProvider
        self.alignTrigger = alignTrigger
        self.displayMode = displayMode
        self.isUnseen = isUnseen
    }

    private let spacing: CGFloat = 16

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(items) { item in
                        storyButton(for: item, isSelected: selectedId == item.id)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChangeCompat(of: alignTrigger) { _ in
                centerOnSelected(using: proxy, animated: true)
            }
        }
        .frame(height: Self.layoutHeight)
    }

    @ViewBuilder
    private func storyButton(for item: StoryItem, isSelected: Bool) -> some View {
        let itemIsUnseen = isUnseen(item)
        switch item.source {
        case let .real(real):
            realButton(for: real, isSelected: isSelected, isUnseen: itemIsUnseen)
        case let .poi(group):
            poiButton(for: group, isSelected: isSelected, isUnseen: itemIsUnseen)
        case let .journey(journey):
            journeyButton(for: journey, isSelected: isSelected, isUnseen: itemIsUnseen)
        }
    }

    private func realButton(for real: RealPost, isSelected: Bool, isUnseen: Bool) -> some View {
        let user = userProvider(real.userId)
        return Button {
            onSelectReal(real)
        } label: {
            VStack(spacing: 6) {
                realBadge(for: real, user: user, isSelected: isSelected, isUnseen: isUnseen)
                .opacity(isSelected ? 1 : 0.82)
                Text(realLabel(for: real, user: user))
                    .font(.caption2.weight(.thin))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
            .frame(width: 72)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func poiButton(for group: POIStoryGroup, isSelected: Bool, isUnseen: Bool) -> some View {
        Button {
            onSelectPOIGroup(group)
        } label: {
            VStack(spacing: 6) {
                poiBadge(for: group, isSelected: isSelected, isUnseen: isUnseen)
                .opacity(isSelected ? 1 : 0.82)
                Text(group.poiName)
                    .font(.caption2.weight(.thin))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
            .frame(width: 72)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func journeyButton(for journey: JourneyPost, isSelected: Bool, isUnseen: Bool) -> some View {
        let user = userProvider(journey.userId)
        return Button {
            onSelectJourney(journey)
        } label: {
            VStack(spacing: 6) {
                journeyBadge(for: journey, user: user, isSelected: isSelected, isUnseen: isUnseen)
                .opacity(isSelected ? 1 : 0.82)
                Text(journeyLabel(for: journey, user: user))
                    .font(.caption2.weight(.thin))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
            .frame(width: 72)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func realBadge(for real: RealPost, user: User?, isSelected: Bool, isUnseen: Bool) -> some View {
        RealStoryBadge(
            real: real,
            user: user,
            displayMode: displayMode,
            isSelected: isSelected,
            isUnseen: isUnseen
        )
    }

    @ViewBuilder
    private func poiBadge(for group: POIStoryGroup, isSelected: Bool, isUnseen: Bool) -> some View {
        POIStoryGroupBadge(
            group: group,
            displayMode: displayMode,
            isSelected: isSelected,
            isUnseen: isUnseen
        )
    }

    @ViewBuilder
    private func journeyBadge(for journey: JourneyPost, user: User?, isSelected: Bool, isUnseen: Bool) -> some View {
        JourneyStoryBadge(
            journey: journey,
            user: user,
            displayMode: displayMode,
            isSelected: isSelected,
            isUnseen: isUnseen
        )
    }

    private func realLabel(for real: RealPost, user: User?) -> String {
        switch displayMode {
        case .people:
            return user?.handle ?? "you"
        case .content:
            let text = real.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? (text ?? "Reel") : "Reel"
        }
    }

    private func journeyLabel(for journey: JourneyPost, user: User?) -> String {
        switch displayMode {
        case .people:
            return user?.handle ?? "you"
        case .content:
            let text = journey.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Journey" : text
        }
    }

    private func centerOnSelected(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = selectedId else { return }
        let anchor = anchorPoint(for: id)
        let action = {
            proxy.scrollTo(id, anchor: anchor)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                action()
            }
        } else {
            action()
        }
    }

    private func anchorPoint(for id: UUID) -> UnitPoint {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return .center
        }
        if index == 0 {
            return .leading
        } else if index == items.count - 1 {
            return .trailing
        }
        return .center
    }
}

private struct RealStoryBadge: View {
    let real: RealPost?
    let user: User?
    let displayMode: RealStoriesRow.DisplayMode
    let isSelected: Bool
    let isUnseen: Bool
    private let contentDiameter: CGFloat = 60
    private let ringDiameter: CGFloat = 68

    var body: some View {
        ZStack {
            outerRing

            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: contentDiameter, height: contentDiameter)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }

            content
        }
        .frame(width: 70, height: 70)
    }

    private var outerRing: some View {
        StoryStatusCircleRing(
            diameter: ringDiameter,
            isUnseen: isUnseen,
            unreadLineWidth: 2.6,
            seenLineWidth: 1.5,
            unreadShadowRadius: 7
        )
    }

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .people:
            avatar
        case .content:
            realPreview
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = user?.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    initialsAvatar
                        .overlay {
                            ProgressView()
                                .controlSize(.mini)
                        }
                default:
                    initialsAvatar
                }
            }
            .frame(width: contentDiameter, height: contentDiameter)
            .clipShape(Circle())
        } else {
            initialsAvatar
        }
    }

    private var realPreview: some View {
        Group {
            if let real, let url = previewURL(for: real) {
                remoteImage(url: url)
            } else if let real, let emoji = firstEmoji(in: real.attachments) {
                fallback(symbol: emoji, color: Theme.neonPrimary)
            } else {
                avatar
            }
        }
        .frame(width: contentDiameter, height: contentDiameter)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func remoteImage(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                avatar
                    .overlay {
                        ProgressView()
                            .controlSize(.mini)
                    }
            default:
                avatar
            }
        }
    }

    private var initialsAvatar: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.black)
            .frame(width: contentDiameter, height: contentDiameter)
            .background(Color.white.opacity(0.72), in: Circle())
    }

    private func fallback(systemImage: String, color: Color) -> some View {
        ZStack {
            color.opacity(0.16)
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private func fallback(symbol: String, color: Color) -> some View {
        ZStack {
            color.opacity(0.16)
            Text(symbol)
                .font(.title2)
        }
    }

    private func previewURL(for real: RealPost) -> URL? {
        for attachment in real.attachments {
            switch attachment.kind {
            case let .photo(url):
                return url
            case let .video(_, poster):
                if let poster { return poster }
            case .emoji:
                continue
            }
        }
        return nil
    }

    private func firstEmoji(in attachments: [RealPost.Attachment]) -> String? {
        attachments.compactMap { attachment in
            if case let .emoji(emoji) = attachment.kind {
                return emoji
            }
            return nil
        }.first
    }

    private var initials: String {
        guard let handle = user?.handle else { return "ME" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct JourneyStoryBadge: View {
    let journey: JourneyPost?
    let user: User?
    let displayMode: RealStoriesRow.DisplayMode
    let isSelected: Bool
    let isUnseen: Bool
    private let contentDiameter: CGFloat = 60
    private let ringDiameter: CGFloat = 68

    var body: some View {
        ZStack {
            outerRing

            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: contentDiameter, height: contentDiameter)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            content
        }
        .frame(width: 70, height: 70)
        .overlay(alignment: .bottom) {
            if let label = bottomLabel {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.75), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.6)
                    }
            }
        }
    }

    private var outerRing: some View {
        StoryStatusCircleRing(
            diameter: ringDiameter,
            isUnseen: isUnseen,
            unreadLineWidth: 2.6,
            seenLineWidth: 1.5,
            unreadShadowRadius: 6
        )
    }

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .people:
            avatar
        case .content:
            journeyMark
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = user?.avatarURL {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ProgressView()
            }
            .frame(width: contentDiameter, height: contentDiameter)
            .clipShape(Circle())
        } else {
            Text(initials)
                .font(.headline.bold())
                .foregroundStyle(.black)
        }
    }

    private var journeyMark: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.neonAccent.opacity(0.95),
                    Theme.neonPrimary.opacity(0.65),
                    Color.black.opacity(0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "map.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

            Text(journey?.displayLabel.prefix(1).uppercased() ?? "J")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.85))
                .offset(x: 14, y: 14)
        }
        .frame(width: contentDiameter, height: contentDiameter)
        .clipShape(Circle())
    }

    private var bottomLabel: String? {
        switch displayMode {
        case .people:
            return "journey"
        case .content:
            return nil
        }
    }

    private var initials: String {
        guard let handle = user?.handle else { return "JR" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct POIStoryGroupBadge: View {
    let group: RealStoriesRow.POIStoryGroup
    let displayMode: RealStoriesRow.DisplayMode
    let isSelected: Bool
    let isUnseen: Bool

    var body: some View {
        ZStack {
            switch displayMode {
            case .people:
                peopleCluster
            case .content:
                poiMark
            }
        }
        .frame(width: 72, height: 72)
    }

    private var peopleCluster: some View {
        let displayedSharers = Array(group.primarySharers.prefix(4))
        return ZStack {
            ZStack {
                StoryStatusDiamondRing(
                    size: 62,
                    isUnseen: isUnseen,
                    cornerRadius: 8,
                    unreadLineWidth: 2.3,
                    seenLineWidth: 1.1,
                    unreadShadowRadius: 5
                )

                RoundedDiamond(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: group.category.markerGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(
                        color: isUnseen
                            ? Theme.unreadRingColor.opacity(0.18)
                            : (group.category.markerGradientColors.last?.opacity(0.3) ?? .black.opacity(0.3)),
                        radius: isUnseen ? 6 : 5
                    )

                RoundedDiamond(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
                    .frame(width: 52, height: 52)

                Image(systemName: group.category.symbolName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(y: 2)
            }
            .offset(y: 8)

            ForEach(Array(displayedSharers.enumerated()), id: \.element.id) { index, sharer in
                AvatarThumbnail(user: sharer.user)
                    .frame(width: avatarSize(for: displayedSharers.count), height: avatarSize(for: displayedSharers.count))
                    .offset(clusterOffset(for: index, total: displayedSharers.count))
            }

            if group.sharers.count > displayedSharers.count {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Text("+\(group.sharers.count - displayedSharers.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }
                    .offset(x: 22, y: -8)
            }
        }
    }

    private var poiMark: some View {
        ZStack {
            StoryStatusDiamondRing(
                size: 66,
                isUnseen: isUnseen,
                cornerRadius: 9,
                unreadLineWidth: 2.4,
                seenLineWidth: 1.2,
                unreadShadowRadius: 5
            )

            RoundedDiamond(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: group.category.markerGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .shadow(color: group.category.markerGradientColors.last?.opacity(0.28) ?? .black.opacity(0.28), radius: 4, y: 3)

            RoundedDiamond(cornerRadius: 8)
                .stroke(Color.white.opacity(0.32), lineWidth: 1)
                .frame(width: 56, height: 56)

            Image(systemName: group.category.symbolName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }

    private var poiRingColor: Color {
        if isUnseen {
            return Theme.unreadRingColor.opacity(0.9)
        }
        return Color.white.opacity(0.55)
    }

    private var poiRingWidth: CGFloat {
        return isUnseen ? 2.4 : 1
    }

    private var poiShadowColor: Color {
        if isUnseen {
            return Theme.unreadRingColor.opacity(0.35)
        }
        return group.category.markerGradientColors.last?.opacity(0.2) ?? .black.opacity(0.2)
    }

    private func avatarSize(for count: Int) -> CGFloat {
        switch count {
        case 0...1: return 32
        case 2: return 28
        default: return 26
        }
    }

    private func clusterOffset(for index: Int, total: Int) -> CGSize {
        let radius: CGFloat = 22
        let angleMap: [[CGFloat]] = [
            [],
            [55],
            [40, -10],
            [50, 10, -30],
            [60, 20, -10, -40]
        ]
        let angles = angleMap[min(total, angleMap.count - 1)]
        let angle = angles[index]
        let rad = angle * .pi / 180
        let x = cos(rad) * radius
        let y = -sin(rad) * radius
        return CGSize(width: x, height: y)
    }
}

private struct AvatarThumbnail: View {
    let user: User?

    var body: some View {
        Group {
            if let url = user?.avatarURL {
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
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.65), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.caption2.bold())
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
    }

    private var initials: String {
        guard let handle = user?.handle else { return "PO" }
        return String(handle.prefix(2)).uppercased()
    }
}

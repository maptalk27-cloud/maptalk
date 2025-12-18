import SwiftUI

struct RealStoriesRow: View {
    struct POISharer: Identifiable {
        let id: UUID
        let user: User?
        let timestamp: Date
    }

    struct POIStoryGroup: Identifiable {
        let ratedPOI: RatedPOI
        let sharers: [POISharer]
        let latestTimestamp: Date

        var id: UUID { ratedPOI.id }
        var poiName: String { ratedPOI.poi.name }
        var category: POICategory { ratedPOI.poi.category }
        var primarySharers: [POISharer] { sharers }
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

    init(
        items: [StoryItem],
        selectedId: UUID?,
        onSelectReal: @escaping (RealPost) -> Void,
        onSelectPOIGroup: @escaping (POIStoryGroup) -> Void,
        onSelectJourney: @escaping (JourneyPost) -> Void,
        userProvider: @escaping (UUID) -> User?,
        alignTrigger: Int
    ) {
        self.items = items
        self.selectedId = selectedId
        self.onSelectReal = onSelectReal
        self.onSelectPOIGroup = onSelectPOIGroup
        self.onSelectJourney = onSelectJourney
        self.userProvider = userProvider
        self.alignTrigger = alignTrigger
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
            }
            .onChangeCompat(of: alignTrigger) { _ in
                centerOnSelected(using: proxy, animated: true)
            }
        }
        .frame(height: 108)
    }

    @ViewBuilder
    private func storyButton(for item: StoryItem, isSelected: Bool) -> some View {
        switch item.source {
        case let .real(real):
            realButton(for: real, isSelected: isSelected)
        case let .poi(group):
            poiButton(for: group, isSelected: isSelected)
        case let .journey(journey):
            journeyButton(for: journey, isSelected: isSelected)
        }
    }

    private func realButton(for real: RealPost, isSelected: Bool) -> some View {
        let user = userProvider(real.userId)
        return Button {
            onSelectReal(real)
        } label: {
            VStack(spacing: 6) {
                RealStoryBadge(
                    user: user,
                    isSelected: isSelected
                )
                .opacity(isSelected ? 1 : 0.82)
                Text(user?.handle ?? "you")
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

    private func poiButton(for group: POIStoryGroup, isSelected: Bool) -> some View {
        Button {
            onSelectPOIGroup(group)
        } label: {
            VStack(spacing: 6) {
                POIStoryGroupBadge(group: group, isSelected: isSelected)
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

    private func journeyButton(for journey: JourneyPost, isSelected: Bool) -> some View {
        let user = userProvider(journey.userId)
        return Button {
            onSelectJourney(journey)
        } label: {
            VStack(spacing: 6) {
                JourneyStoryBadge(
                    user: user,
                    isSelected: isSelected
                )
                .opacity(isSelected ? 1 : 0.82)
                Text(user?.handle ?? "you")
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
    let user: User?
    let isSelected: Bool

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
                .frame(width: 66, height: 66)
                .shadow(color: Theme.neonPrimary.opacity(0.6), radius: 12)

            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: 62, height: 62)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }

            if let url = user?.avatarURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.headline.bold())
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 70, height: 70)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Theme.neonPrimary)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var initials: String {
        guard let handle = user?.handle else { return "ME" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct JourneyStoryBadge: View {
    let user: User?
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: 62, height: 62)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            if let url = user?.avatarURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.headline.bold())
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 70, height: 70)
        .overlay(alignment: .bottom) {
            Text("journey")
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
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Theme.neonPrimary)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 6, y: 6)
            }
        }
    }

    private var initials: String {
        guard let handle = user?.handle else { return "JR" }
        return String(handle.prefix(2)).uppercased()
    }
}

private struct POIStoryGroupBadge: View {
    let group: RealStoriesRow.POIStoryGroup
    let isSelected: Bool

    var body: some View {
        let displayedSharers = Array(group.primarySharers.prefix(4))
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: group.category.markerGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(45))
                .shadow(color: group.category.markerGradientColors.last?.opacity(0.35) ?? .black.opacity(0.35), radius: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        .rotationEffect(.degrees(45))
                }
                .offset(y: 8)
                .overlay {
                    Image(systemName: group.category.symbolName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(y: 6)
                }

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
                .frame(width: 72, height: 72)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Theme.neonPrimary)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 6, y: 6)
            }
        }
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

import SwiftUI

struct JourneyCard: View {
    enum Style {
        case standard
        case collapsed
    }

    let journey: JourneyPost
    let user: User?
    let style: Style
    let userProvider: (UUID) -> User?
    let onAvatarStackTap: (() -> Void)?

    init(
        journey: JourneyPost,
        user: User?,
        style: Style,
        userProvider: @escaping (UUID) -> User?,
        onAvatarStackTap: (() -> Void)? = nil
    ) {
        self.journey = journey
        self.user = user
        self.style = style
        self.userProvider = userProvider
        self.onAvatarStackTap = onAvatarStackTap
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            avatarView
                .alignmentGuide(.top) { $0[.top] }
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 12) {
                userNameRow
                contentText
                avatarStack
                footerRow
            }
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
    }

    private var horizontalPadding: CGFloat {
        style == .collapsed ? 16 : 24
    }

    private var verticalPadding: CGFloat {
        style == .collapsed ? 12 : 22
    }

    private var headerTopPadding: CGFloat { 40 }

    private var avatarSize: CGFloat {
        style == .collapsed ? 34 : 40
    }

    private var stackAvatarSize: CGFloat { 34 }

    private var userNameRow: some View {
        HStack(spacing: 8) {
            Text(displayName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text(journey.displayLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatarView: some View {
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
        user?.handle ?? "Unknown user"
    }

    private var displayInitials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "??" }
        return String(trimmed.prefix(2)).uppercased()
    }

    private var contentText: some View {
        Text(journey.content.isEmpty ? "Journey update" : journey.content)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(style == .collapsed ? 2 : 3)
    }

    private var avatarStack: some View {
        JourneyAvatarStack(
            journey: journey,
            userProvider: userProvider,
            avatarSize: stackAvatarSize,
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
        .onTapGesture {
            onAvatarStackTap?()
        }
    }

    private var footerRow: some View {
        HStack(spacing: 12) {
            Text(journey.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                metricsPill(
                    symbol: "heart.fill",
                    text: ExperienceDetailView.formatCount(journey.likes.count)
                )
                metricsPill(
                    symbol: "bubble.right.fill",
                    text: ExperienceDetailView.formatCount(journey.comments.count)
                )
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
}

private struct JourneyAvatarStack: View {
    let journey: JourneyPost
    let userProvider: (UUID) -> User?
    let avatarSize: CGFloat
    let maxRows: Int?

    init(
        journey: JourneyPost,
        userProvider: @escaping (UUID) -> User?,
        avatarSize: CGFloat,
        maxRows: Int? = nil
    ) {
        self.journey = journey
        self.userProvider = userProvider
        self.avatarSize = avatarSize
        self.maxRows = maxRows
    }

    var body: some View {
        let events = sortedEvents
        if events.isEmpty {
            Text("No stops yet")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        } else {
            let rows = chunked(events, size: 13)
            let visibleRows = maxRows.map { Array(rows.prefix($0)) } ?? rows
            let visibleCount = visibleRows.reduce(0) { $0 + $1.count }
            let remainingCount = max(events.count - visibleCount, 0)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleRows.indices, id: \.self) { index in
                    let row = visibleRows[index]
                    HStack(spacing: -10) {
                        ForEach(row) { event in
                            avatar(for: event)
                        }
                        if remainingCount > 0 && index == visibleRows.count - 1 {
                            Text("+\(remainingCount)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var sortedEvents: [JourneyStackEvent] {
        let reelEvents = journey.reels.map { reel in
            JourneyStackEvent(
                id: reel.id,
                date: reel.createdAt,
                kind: .reel(reel, userProvider(reel.userId))
            )
        }
        let poiEvents = journey.pois.map { poi in
            JourneyStackEvent(
                id: poi.id,
                date: poi.checkIns.map(\.createdAt).max() ?? journey.createdAt,
                kind: .poi(poi)
            )
        }
        return (reelEvents + poiEvents).sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.date > rhs.date
        }
    }

    @ViewBuilder
    private func avatar(for event: JourneyStackEvent) -> some View {
        switch event.kind {
        case let .reel(real, user):
            RealMapThumbnail(real: real, user: user, size: avatarSize)
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
                .frame(width: avatarSize * 0.88, height: avatarSize * 0.97)
        }
    }
}

private enum JourneyStackKind {
    case reel(RealPost, User?)
    case poi(RatedPOI)
}

private struct JourneyStackEvent: Identifiable {
    let id: UUID
    let date: Date
    let kind: JourneyStackKind

    var priority: Int {
        switch kind {
        case .reel:
            return 1
        case .poi:
            return 0
        }
    }
}

private func chunked<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [items] }
    var result: [[T]] = []
    var index = 0
    while index < items.count {
        let end = min(index + size, items.count)
        result.append(Array(items[index..<end]))
        index += size
    }
    return result
}

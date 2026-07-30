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
    let onUserTap: ((User) -> Void)?
    let onAvatarStackTap: (() -> Void)?

    init(
        journey: JourneyPost,
        user: User?,
        style: Style,
        userProvider: @escaping (UUID) -> User?,
        onUserTap: ((User) -> Void)? = nil,
        onAvatarStackTap: (() -> Void)? = nil
    ) {
        self.journey = journey
        self.user = user
        self.style = style
        self.userProvider = userProvider
        self.onUserTap = onUserTap
        self.onAvatarStackTap = onAvatarStackTap
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            profileButton {
                avatarView
            }
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
            profileButton {
                Text(displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
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

    @ViewBuilder
    private func profileButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let user, let onUserTap {
            Button {
                onUserTap(user)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
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

struct JourneyAvatarStack: View {
    let journey: JourneyPost
    let userProvider: (UUID) -> User?
    let reels: [RealPost]?
    let pois: [RatedPOI]?
    let avatarSize: CGFloat
    let maxRows: Int?
    let maxVisibleCount: Int?
    let onReelTap: ((RealPost) -> Void)?
    let onPOITap: ((RatedPOI) -> Void)?

    init(
        journey: JourneyPost,
        userProvider: @escaping (UUID) -> User?,
        reels: [RealPost]? = nil,
        pois: [RatedPOI]? = nil,
        avatarSize: CGFloat,
        maxRows: Int? = nil,
        maxVisibleCount: Int? = nil,
        onReelTap: ((RealPost) -> Void)? = nil,
        onPOITap: ((RatedPOI) -> Void)? = nil
    ) {
        self.journey = journey
        self.userProvider = userProvider
        self.reels = reels
        self.pois = pois
        self.avatarSize = avatarSize
        self.maxRows = maxRows
        self.maxVisibleCount = maxVisibleCount
        self.onReelTap = onReelTap
        self.onPOITap = onPOITap
    }

    var body: some View {
        let events = sortedEvents
        if events.isEmpty {
            Text("No stops yet")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        } else if let maxVisibleCount {
            let visibleEvents = Array(events.prefix(maxVisibleCount))
            let remainingCount = max(events.count - visibleEvents.count, 0)

            HStack(spacing: -10) {
                ForEach(visibleEvents) { event in
                    avatar(for: event)
                }
                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.leading, 10)
                }
            }
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
        let reelEvents = (reels ?? journey.reels).map { reel in
            JourneyStackEvent(
                id: reel.id,
                date: reel.createdAt,
                kind: .reel(reel, userProvider(reel.userId))
            )
        }
        let poiEvents = (pois ?? journey.pois).map { poi in
            JourneyStackEvent(
                id: poi.id,
                date: poi.checkIns.map(\.createdAt).max() ?? journey.createdAt,
                kind: .poi(poi)
            )
        }
        return (reelEvents + poiEvents).sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.date > rhs.date
        }
    }

    @ViewBuilder
    private func avatar(for event: JourneyStackEvent) -> some View {
        switch event.kind {
        case let .reel(reel, user):
            let displayUser = user ?? userProvider(reel.userId)
            tapTarget(action: onReelTap.map { handler in { handler(reel) } }) {
                RealMapThumbnail(
                    real: reel,
                    user: displayUser,
                    size: avatarSize,
                    fitsStatusInsideFrame: true
                )
            }
        case let .poi(rated):
            tapTarget(action: onPOITap.map { handler in { handler(rated) } }) {
                POIMapThumbnail(category: rated.poi.category, size: avatarSize)
            }
        }
    }

    @ViewBuilder
    private func tapTarget<Content: View>(
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let action {
            Button(action: action) {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

/// The compact media stack attached to a Reel when it belongs to a Journey.
/// It intentionally contains only the Journey's memories, never a public Journey post card.
struct JourneyAttachmentCapsule: View {
    let journey: JourneyPost
    let userProvider: (UUID) -> User?
    let reels: [RealPost]?
    let pois: [RatedPOI]?
    let isCompact: Bool
    let isCollapsed: Bool
    let maxVisibleCount: Int?
    let onTap: (() -> Void)?
    let onReelTap: ((RealPost) -> Void)?
    let onPOITap: ((RatedPOI) -> Void)?

    init(
        journey: JourneyPost,
        userProvider: @escaping (UUID) -> User?,
        reels: [RealPost]? = nil,
        pois: [RatedPOI]? = nil,
        isCompact: Bool = false,
        isCollapsed: Bool,
        maxVisibleCount: Int? = nil,
        onTap: (() -> Void)? = nil,
        onReelTap: ((RealPost) -> Void)? = nil,
        onPOITap: ((RatedPOI) -> Void)? = nil
    ) {
        self.journey = journey
        self.userProvider = userProvider
        self.reels = reels
        self.pois = pois
        self.isCompact = isCompact
        self.isCollapsed = isCollapsed
        self.maxVisibleCount = maxVisibleCount
        self.onTap = onTap
        self.onReelTap = onReelTap
        self.onPOITap = onPOITap
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityLabel("Journey memories")
    }

    private var content: some View {
        JourneyAvatarStack(
            journey: journey,
            userProvider: userProvider,
            reels: reels,
            pois: pois,
            avatarSize: avatarSize,
            maxRows: effectiveMaxVisibleCount == nil ? maxRows : nil,
            maxVisibleCount: effectiveMaxVisibleCount,
            onReelTap: onReelTap,
            onPOITap: onPOITap
        )
        .padding(.vertical, verticalPadding)
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: maxCapsuleWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .padding(.leading, -backgroundBleed)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .padding(.leading, -backgroundBleed)
        }
        .contentShape(Rectangle())
    }

    private var avatarSize: CGFloat { isCompact ? 26 : 34 }
    private var verticalPadding: CGFloat { isCompact ? 6 : 10 }
    private var horizontalPadding: CGFloat { isCompact ? 6 : 8 }
    private var leadingPadding: CGFloat { isCompact ? 0 : horizontalPadding }
    private var trailingPadding: CGFloat { horizontalPadding }
    private var maxRows: Int? { isCompact ? 1 : (isCollapsed ? 2 : nil) }
    private var backgroundBleed: CGFloat { isCompact ? 8 : 0 }
    private var maxCapsuleWidth: CGFloat? { isCompact ? nil : 280 }

    private var effectiveMaxVisibleCount: Int? {
        if let maxVisibleCount { return maxVisibleCount }
        guard let maxCapsuleWidth else { return nil }

        let eventCount = (reels ?? journey.reels).count + (pois ?? journey.pois).count
        let overlapSpacing: CGFloat = 10
        let availableWidth = max(maxCapsuleWidth - leadingPadding - trailingPadding, avatarSize)
        let step = max(avatarSize - overlapSpacing, 1)
        let baseOffset = overlapSpacing
        let maxWithoutPlus = max(1, Int((availableWidth - baseOffset) / step))

        if eventCount > maxWithoutPlus {
            let plusWidth = max(avatarSize * 0.8, 18)
            let maxWithPlus = max(1, Int((availableWidth - baseOffset - plusWidth) / step))
            return maxWithPlus
        }
        return maxWithoutPlus
    }
}

private struct JourneyStackEvent: Identifiable {
    enum Kind {
        case reel(RealPost, User?)
        case poi(RatedPOI)
    }

    enum Priority: Int {
        case reel = 0
        case poi = 1
    }

    let id: UUID
    let date: Date
    let kind: Kind

    var priority: Priority {
        switch kind {
        case .reel:
            return .reel
        case .poi:
            return .poi
        }
    }
}

private func chunked<T>(_ array: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [] }
    var result: [[T]] = []
    var current: [T] = []
    current.reserveCapacity(size)
    for element in array {
        current.append(element)
        if current.count == size {
            result.append(current)
            current = []
        }
    }
    if current.isEmpty == false {
        result.append(current)
    }
    return result
}

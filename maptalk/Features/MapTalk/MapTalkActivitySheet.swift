import SwiftUI

struct MapTalkActivityEvent: Identifiable {
    enum Kind: Equatable {
        case like
        case comment

    }

    struct Target {
        enum Destination {
            case reel(UUID)
            case place(UUID)
            case bubble(UUID)
        }

        enum Thumbnail {
            case image(URL)
            case emoji(String)
            case symbol(String)
        }

        let title: String
        let kindLabel: String
        let thumbnail: Thumbnail
        let destination: Destination
    }

    let id: String
    let actor: User
    let kind: Kind
    let action: String
    let detail: String?
    let timestamp: Date?
    let target: Target
    var commentID: UUID? = nil
}

enum MapTalkActivityFeed {
    static func events(
        reals: [RealPost],
        ratedPOIs: [RatedPOI],
        bubbles: [JourneyPost],
        currentUserID: UUID,
        userProvider: (UUID) -> User?
    ) -> [MapTalkActivityEvent] {
        let ownedReels = reals.filter { $0.userId == currentUserID }

        let reelComments = ownedReels.flatMap { reel in
            reel.comments.compactMap { comment -> MapTalkActivityEvent? in
                guard comment.userId != currentUserID,
                      let actor = userProvider(comment.userId) else {
                    return nil
                }
                return MapTalkActivityEvent(
                    id: "reel-comment-\(comment.id.uuidString)",
                    actor: actor,
                    kind: .comment,
                    action: "Comment on Reel",
                    detail: comment.text,
                    timestamp: comment.createdAt,
                    target: target(for: reel),
                    commentID: comment.id
                )
            }
        }

        let referencedBubbleIDs = Set(ownedReels.compactMap(\.capsuleId))
        let ownedBubbles = uniqueBubbles(bubbles).filter { bubble in
            bubble.userId == currentUserID && referencedBubbleIDs.contains(bubble.id)
        }
        let bubbleComments = ownedBubbles.flatMap { bubble in
            bubble.comments.compactMap { comment -> MapTalkActivityEvent? in
                guard comment.userId != currentUserID,
                      let actor = userProvider(comment.userId) else {
                    return nil
                }
                return MapTalkActivityEvent(
                    id: "bubble-comment-\(comment.id.uuidString)",
                    actor: actor,
                    kind: .comment,
                    action: "Comment on Bubble",
                    detail: comment.text,
                    timestamp: comment.createdAt,
                    target: target(for: bubble),
                    commentID: comment.id
                )
            }
        }

        let placeComments = ratedPOIs
            .filter { rated in
                rated.checkIns.contains { $0.userId == currentUserID }
            }
            .flatMap { rated in
                rated.comments.compactMap { comment -> MapTalkActivityEvent? in
                    guard comment.userId != currentUserID,
                          let actor = userProvider(comment.userId) else {
                        return nil
                    }
                    return MapTalkActivityEvent(
                        id: "place-comment-\(comment.id.uuidString)",
                        actor: actor,
                        kind: .comment,
                        action: "Comment at Place",
                        detail: detail(for: comment.content),
                        timestamp: comment.createdAt,
                        target: target(for: rated),
                        commentID: comment.id
                    )
                }
            }

        let comments = newest(reelComments + bubbleComments + placeComments)
        let likes = individualLikeEvents(
            for: ownedReels,
            bubbles: ownedBubbles,
            currentUserID: currentUserID,
            userProvider: userProvider
        )

        // Keep one mixed stream, with one row per person's interaction.
        // Likes do not have timestamps yet, so retain the existing mixed
        // ordering without fabricating dates or dropping older rows.
        var events: [MapTalkActivityEvent] = []
        for index in 0..<max(likes.count, comments.count) {
            if likes.indices.contains(index) {
                events.append(likes[index])
            }
            if comments.indices.contains(index) {
                events.append(comments[index])
            }
        }
        return events
    }

    private static func newest(_ events: [MapTalkActivityEvent]) -> [MapTalkActivityEvent] {
        events.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }

    private static func uniqueBubbles(_ bubbles: [JourneyPost]) -> [JourneyPost] {
        var seen = Set<UUID>()
        return bubbles.filter { seen.insert($0.id).inserted }
    }

    private static func individualLikeEvents(
        for reals: [RealPost],
        bubbles: [JourneyPost],
        currentUserID: UUID,
        userProvider: (UUID) -> User?
    ) -> [MapTalkActivityEvent] {
        let reelEvents = reals
            .sorted(by: { $0.createdAt > $1.createdAt })
            .flatMap { reel -> [MapTalkActivityEvent] in
                var seen = Set<UUID>()
                return reel.likes.compactMap { userID in
                    guard userID != currentUserID,
                          seen.insert(userID).inserted,
                          let actor = userProvider(userID) else {
                        return nil
                    }

                    return MapTalkActivityEvent(
                        id: "reel-like-\(reel.id.uuidString)-\(userID.uuidString)",
                        actor: actor,
                        kind: .like,
                        action: "Liked your Reel",
                        detail: nil,
                        // Likes currently store the person, but not the time.
                        timestamp: nil,
                        target: target(for: reel)
                    )
                }
            }

        let bubbleEvents = bubbles
            .sorted(by: { $0.createdAt > $1.createdAt })
            .flatMap { bubble -> [MapTalkActivityEvent] in
                var seen = Set<UUID>()
                return bubble.likes.compactMap { userID in
                    guard userID != currentUserID,
                          seen.insert(userID).inserted,
                          let actor = userProvider(userID) else {
                        return nil
                    }

                    return MapTalkActivityEvent(
                        id: "bubble-like-\(bubble.id.uuidString)-\(userID.uuidString)",
                        actor: actor,
                        kind: .like,
                        action: "Liked your Bubble",
                        detail: nil,
                        timestamp: nil,
                        target: target(for: bubble)
                    )
                }
            }
        return reelEvents + bubbleEvents
    }

    private static func detail(for content: RatedPOI.Comment.Content) -> String {
        switch content {
        case let .text(text):
            return text
        case .photo:
            return "Shared a photo"
        case .video:
            return "Shared a video"
        }
    }

    private static func target(for reel: RealPost) -> MapTalkActivityEvent.Target {
        .init(
            title: reel.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Reel",
            kindLabel: "Reel",
            thumbnail: thumbnail(for: reel),
            destination: .reel(reel.id)
        )
    }

    private static func target(for bubble: JourneyPost) -> MapTalkActivityEvent.Target {
        let thumbnail = bubble.reels.lazy.map { self.thumbnail(for: $0) }.first
            ?? bubble.pois.lazy.map { self.thumbnail(for: $0) }.first
            ?? .symbol("square.stack.3d.up.fill")
        return .init(
            title: bubble.title,
            kindLabel: "Bubble",
            thumbnail: thumbnail,
            destination: .bubble(bubble.id)
        )
    }

    private static func target(for place: RatedPOI) -> MapTalkActivityEvent.Target {
        .init(
            title: place.poi.name,
            kindLabel: "Place",
            thumbnail: thumbnail(for: place),
            destination: .place(place.id)
        )
    }

    private static func thumbnail(for reel: RealPost) -> MapTalkActivityEvent.Target.Thumbnail {
        for attachment in reel.attachments {
            switch attachment.kind {
            case let .photo(url):
                return .image(url)
            case let .video(_, poster):
                if let poster { return .image(poster) }
            case let .emoji(emoji):
                return .emoji(emoji)
            }
        }
        return .symbol("play.rectangle.fill")
    }

    private static func thumbnail(for place: RatedPOI) -> MapTalkActivityEvent.Target.Thumbnail {
        let media = place.media.first ?? place.checkIns.lazy.compactMap(\.media.first).first
        guard let media else { return .symbol(place.poi.category.symbolName) }
        switch media.kind {
        case let .photo(url):
            return .image(url)
        case let .video(_, poster):
            return poster.map(MapTalkActivityEvent.Target.Thumbnail.image)
                ?? .symbol("play.rectangle.fill")
        }
    }
}

struct MapTalkActivityView: View {
    let events: [MapTalkActivityEvent]
    let onVisible: () -> Void
    let onSelect: (MapTalkActivityEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var visibleEventID: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            VStack(spacing: 0) {
                                Button {
                                    onSelect(event)
                                } label: {
                                    MapTalkActivityRow(event: event)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("maptalk.activity.row.\(event.id)")

                                if event.id != events.last?.id {
                                    Divider()
                                        .padding(.leading, 80)
                                }
                            }
                            .id(event.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $visibleEventID, anchor: .top)
                .accessibilityIdentifier("maptalk.activity.list")
            }
        }
        .background(Color(.systemBackground))
        .onAppear(perform: onVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.activity.view")
    }

    private var header: some View {
        ZStack {
            Text("Activity")
                .font(.system(size: 20, weight: .semibold))

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("maptalk.activity.close")

                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 31, weight: .light))
            Text("No activity yet")
                .font(.headline)
            Text("Likes and comments on your map posts will show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct MapTalkActivityRow: View {
    let event: MapTalkActivityEvent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MapTalkActivityAvatar(user: event.actor, size: 42)

            if event.kind == .like {
                HStack(spacing: 6) {
                    Text(event.actor.handle)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Image(systemName: "heart.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .accessibilityHidden(true)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.actor.handle)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                       detail.isEmpty == false {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let timeText {
                        Text(timeText)
                            .font(.caption)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }

            Spacer(minLength: 0)

            MapTalkActivityTargetThumbnail(target: event.target)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, event.kind == .like ? 14 : 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var timeText: String? {
        event.timestamp?.formatted(.relative(presentation: .named))
    }

    private var accessibilityText: String {
        let time = timeText.map { ", \($0)" } ?? ""
        return "\(event.actor.handle), \(event.action), \(event.target.title)\(time)"
    }
}

private struct MapTalkActivityTargetThumbnail: View {
    let target: MapTalkActivityEvent.Target

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)

            switch target.thumbnail {
            case let .image(url):
                MapImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        fallbackSymbol
                    }
                }
            case let .emoji(emoji):
                Text(emoji)
                    .font(.system(size: 24))
            case .symbol:
                fallbackSymbol
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: some View {
        let symbol: String
        if case let .symbol(name) = target.thumbnail {
            symbol = name
        } else {
            symbol = "photo"
        }
        return Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct MapTalkActivityAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        Group {
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        Text(String(user.handle.prefix(2)).uppercased())
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

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
    let actorSuffix: String?
    let kind: Kind
    let action: String
    let detail: String?
    let timestamp: Date?
    let target: Target
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
                    actorSuffix: nil,
                    kind: .comment,
                    action: "Comment on Reel",
                    detail: comment.text,
                    timestamp: comment.createdAt,
                    target: target(for: reel)
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
                    actorSuffix: nil,
                    kind: .comment,
                    action: "Comment on Bubble",
                    detail: comment.text,
                    timestamp: comment.createdAt,
                    target: target(for: bubble)
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
                        actorSuffix: nil,
                        kind: .comment,
                        action: "Comment at Place",
                        detail: detail(for: comment.content),
                        timestamp: comment.createdAt,
                        target: target(for: rated)
                    )
                }
            }

        let comments = newest(reelComments + bubbleComments + placeComments)
        let likes = groupedLikeEvents(
            for: ownedReels,
            bubbles: ownedBubbles,
            currentUserID: currentUserID,
            userProvider: userProvider
        )

        // One activity stream, with likes grouped by post and comments kept
        // individual. The row treatment carries the distinction; the person
        // should not have to classify the interaction before reading it.
        var selected: [MapTalkActivityEvent] = []
        for index in 0..<3 {
            if likes.indices.contains(index) {
                selected.append(likes[index])
            }
            if comments.indices.contains(index) {
                selected.append(comments[index])
            }
        }

        if selected.count < 6 {
            let selectedIDs = Set(selected.map(\.id))
            let remaining = (likes + comments).filter { selectedIDs.contains($0.id) == false }
            selected.append(contentsOf: remaining.prefix(6 - selected.count))
        }

        return Array(selected.prefix(6))
    }

    private static func newest(_ events: [MapTalkActivityEvent]) -> [MapTalkActivityEvent] {
        events.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }

    private static func uniqueBubbles(_ bubbles: [JourneyPost]) -> [JourneyPost] {
        var seen = Set<UUID>()
        return bubbles.filter { seen.insert($0.id).inserted }
    }

    private static func groupedLikeEvents(
        for reals: [RealPost],
        bubbles: [JourneyPost],
        currentUserID: UUID,
        userProvider: (UUID) -> User?
    ) -> [MapTalkActivityEvent] {
        let reelEvents = reals
            .sorted(by: { $0.createdAt > $1.createdAt })
            .compactMap { reel -> MapTalkActivityEvent? in
            let people = reel.likes.filter { $0 != currentUserID }
            guard let firstID = people.first,
                  let actor = userProvider(firstID) else {
                return nil
            }

            let others = people.count - 1
            return MapTalkActivityEvent(
                id: "reel-likes-\(reel.id.uuidString)-\(people.count)",
                actor: actor,
                actorSuffix: others == 0
                    ? nil
                    : "and \(others) other\(others == 1 ? "" : "s")",
                kind: .like,
                action: "Liked your Reel",
                detail: nil,
                // RealPost currently stores who liked, but not when. Avoid
                // inventing a precise time until the backend provides one.
                timestamp: nil,
                target: target(for: reel)
            )
        }

        let bubbleEvents = bubbles
            .sorted(by: { $0.createdAt > $1.createdAt })
            .compactMap { bubble -> MapTalkActivityEvent? in
                let people = bubble.likes.filter { $0 != currentUserID }
                guard let firstID = people.first,
                      let actor = userProvider(firstID) else {
                    return nil
                }

                let others = people.count - 1
                return MapTalkActivityEvent(
                    id: "bubble-likes-\(bubble.id.uuidString)-\(people.count)",
                    actor: actor,
                    actorSuffix: others == 0
                        ? nil
                        : "and \(others) other\(others == 1 ? "" : "s")",
                    kind: .like,
                    action: "Liked your Bubble",
                    detail: nil,
                    timestamp: nil,
                    target: target(for: bubble)
                )
            }

        // Two Reels plus one Bubble make the social model legible without
        // turning the first version into a filterable inbox.
        var result = Array(reelEvents.prefix(2))
        if let bubble = bubbleEvents.first {
            result.append(bubble)
        }
        let selectedIDs = Set(result.map(\.id))
        result.append(contentsOf: (reelEvents + bubbleEvents).filter {
            selectedIDs.contains($0.id) == false
        })
        return result
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
    let onSelect: (MapTalkActivityEvent.Target.Destination) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            Button {
                                onSelect(event.target.destination)
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
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear(perform: onVisible)
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
                    Text(headlineText)
                        .font(.subheadline)
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

    private var headlineText: AttributedString {
        var text = AttributedString(event.actor.handle)
        text.font = .subheadline.bold()

        if let actorSuffix = event.actorSuffix {
            var suffix = AttributedString(" \(actorSuffix)")
            suffix.foregroundColor = .secondary
            text += suffix
        }

        return text
    }

    private var timeText: String? {
        event.timestamp?.formatted(.relative(presentation: .named))
    }

    private var accessibilityText: String {
        let actor = [event.actor.handle, event.actorSuffix].compactMap { $0 }.joined(separator: " ")
        let time = timeText.map { ", \($0)" } ?? ""
        return "\(actor), \(event.action), \(event.target.title)\(time)"
    }
}

private struct MapTalkActivityTargetThumbnail: View {
    let target: MapTalkActivityEvent.Target

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)

            switch target.thumbnail {
            case let .image(url):
                AsyncImage(url: url) { phase in
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

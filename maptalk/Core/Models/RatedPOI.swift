import Foundation

enum VisitTag: String, CaseIterable, Codable, Hashable {
    case dine
    case social
    case date
    case unwind
    case premium
    case explore
    case entertainment
    case express
    case study
    case detour

    var displayName: String {
        switch self {
        case .dine:
            return "Dining"
        case .social:
            return "Social"
        case .date:
            return "Date Night"
        case .unwind:
            return "Unwind"
        case .premium:
            return "Premium"
        case .explore:
            return "Explore"
        case .entertainment:
            return "Entertainment"
        case .express:
            return "Express"
        case .study:
            return "Study"
        case .detour:
            return "Detour"
        }
    }

    var emoji: String {
        switch self {
        case .dine:
            return "🍽️"
        case .social:
            return "🗣️"
        case .date:
            return "💞"
        case .unwind:
            return "🌿"
        case .premium:
            return "💎"
        case .explore:
            return "🧭"
        case .entertainment:
            return "🎉"
        case .express:
            return "🎨"
        case .study:
            return "📚"
        case .detour:
            return "🚶"
        }
    }
}

struct RatedPOI: Identifiable, Hashable {
    enum Endorsement: String, Codable, Hashable {
        case hype
        case solid
        case meh
        case questionable
    }

    struct Media: Identifiable, Hashable {
        enum Kind: Hashable {
            case photo(URL)
            case video(url: URL, poster: URL?)
        }

        let id: UUID
        var kind: Kind

        init(id: UUID = UUID(), kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    struct CheckIn: Identifiable, Hashable {
        let id: UUID
        let userId: UUID
        var createdAt: Date
        var endorsement: Endorsement?
        var media: [Media]
        var tag: VisitTag?
        var publishedAt: Date?
        var activityDate: Date { publishedAt ?? createdAt }

        init(
            id: UUID = UUID(),
            userId: UUID,
            createdAt: Date = .init(),
            endorsement: Endorsement? = nil,
            media: [Media] = [],
            tag: VisitTag? = nil,
            publishedAt: Date? = nil
        ) {
            self.id = id
            self.userId = userId
            self.createdAt = createdAt
            self.endorsement = endorsement
            self.media = media
            self.tag = tag
            self.publishedAt = publishedAt
        }
    }

    struct Comment: Identifiable, Hashable {
        enum Content: Hashable {
            case text(String)
            case photo(URL)
            case video(url: URL, poster: URL?)
        }

        let id: UUID
        let userId: UUID
        var content: Content
        var createdAt: Date

        init(id: UUID = UUID(), userId: UUID, content: Content, createdAt: Date = .init()) {
            self.id = id
            self.userId = userId
            self.content = content
            self.createdAt = createdAt
        }
    }

    struct TagStat: Identifiable, Hashable {
        let tag: VisitTag
        var count: Int

        var id: VisitTag { tag }
    }

    struct EndorsementSummary: Hashable {
        var hype: Int
        var solid: Int
        var meh: Int
        var questionable: Int
    }

    let poi: POI
    var highlight: String?
    var secondary: String?
    var media: [Media]
    var checkIns: [CheckIn]
    var comments: [Comment]
    var endorsements: EndorsementSummary
    var tags: [TagStat]
    var isFavoritedByCurrentUser: Bool
    var favoritesCount: Int

    var id: UUID { poi.id }
}

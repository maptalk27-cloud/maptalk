import CryptoKit
import Foundation

/// A Bubble browses the memories saved in its snapshot, not the place's live
/// public history. Each saved visit's media is its own story page.
@MainActor
struct HomeBubblePage: Identifiable {
    let id: UUID
    let memberID: UUID
    let mode: ExperienceDetailView.Mode
    let poiSelection: ExperienceDetailView.POIStorySelection?

    var media: RatedPOI.Media? { poiSelection?.media }

    var readKey: String? {
        switch mode {
        case let .real(real, _):
            return StoryReadKeys.real(real)
        case let .poi(place):
            guard let selection = poiSelection, let media = selection.media else { return nil }
            return StoryReadKeys.poiStoryPage(
                poiId: place.id,
                checkInId: selection.checkIn.id,
                mediaId: media.id,
                timestamp: selection.checkIn.activityDate
            )
        case .journey:
            return nil
        }
    }

    static func pages(in scope: MapJourneyScope) -> [Self] {
        scope.sequenceItems.flatMap { item -> [Self] in
            switch item.mode {
            case let .real(real, _):
                return [Self(id: real.id, memberID: item.id, mode: item.mode, poiSelection: nil)]

            case let .poi(place):
                let visits = place.checkIns.enumerated().sorted { lhs, rhs in
                    if lhs.element.activityDate != rhs.element.activityDate {
                        return lhs.element.activityDate > rhs.element.activityDate
                    }
                    if lhs.element.id != rhs.element.id {
                        return lhs.element.id.uuidString < rhs.element.id.uuidString
                    }
                    return lhs.offset < rhs.offset
                }
                var seenSlices = Set<String>()
                var pages: [Self] = []
                for entry in visits {
                    let visit = entry.element
                    // A location-only visit remains its own page; it must not
                    // borrow a photo from a different visit or place gallery.
                    let savedMedia: [RatedPOI.Media?] = visit.media.isEmpty
                        ? [nil]
                        : visit.media.map { Optional($0) }
                    for media in savedMedia {
                        let identity = "\(place.id.uuidString)/\(visit.id.uuidString)/\(media?.id.uuidString ?? "location")"
                        guard seenSlices.insert(identity).inserted else { continue }
                        pages.append(Self(
                            id: pageID(identity),
                            memberID: item.id,
                            mode: item.mode,
                            poiSelection: .init(checkIn: visit, media: media)
                        ))
                    }
                }

                if pages.isEmpty {
                    return [Self(
                        id: pageID("\(place.id.uuidString)/location"),
                        memberID: item.id,
                        mode: item.mode,
                        poiSelection: nil
                    )]
                }
                return pages

            case .journey:
                return []
            }
        }
    }

    private static func pageID(_ identity: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("maptalk.home-bubble.page/\(identity)".utf8)).prefix(16))
        // RFC 9562 custom, name-derived UUID (version 8), with an explicit
        // Bubble namespace so a reused media ID cannot collide across visits.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

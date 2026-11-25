import CryptoKit
import Foundation
import SwiftUI

private struct PersonalPOIHistoryChronologicalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var personalPOIHistoryChronological: Bool {
        get { self[PersonalPOIHistoryChronologicalKey.self] }
        set { self[PersonalPOIHistoryChronologicalKey.self] = newValue }
    }
}

/// A personal place keeps its existing outer map identity. These are only its
/// permitted owner's visit/media slots; neither freshness nor other people add
/// pages. Metadata can reserve a slot before the image/video bytes are ready.
@MainActor
enum PersonalPOISliceSequence {
    struct Cursor: Hashable {
        let visitID: UUID
        let mediaID: UUID?
    }

    struct Slice: Identifiable {
        let id: Cursor
        let checkIn: RatedPOI.CheckIn
        let media: RatedPOI.Media?

        var selection: ExperienceDetailView.POIStorySelection {
            .init(checkIn: checkIn, media: media)
        }
    }

    struct Page: Identifiable {
        let id: UUID
        let originID: UUID
        let mode: ExperienceDetailView.Mode
        let cursor: Cursor?

        var item: ExperienceDetailView.SequencePager.Item { .init(id: id, mode: mode) }
    }

    struct PageProgress: Equatable {
        let count: Int
        let index: Int
    }

    private struct DayGroup: Equatable {
        let placeID: UUID
        let userID: UUID
        let day: String
    }

    /// Progress describes only the adjacent run. A later return to the same
    /// place/day after another place or a Post must not pull those pages here.
    static func dayRunProgress(in pages: [Page], selectedPageID: UUID) -> PageProgress? {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }),
              let group = dayGroup(for: pages[index]) else { return nil }
        var lower = index
        var upper = index
        while lower > 0, dayGroup(for: pages[lower - 1]) == group { lower -= 1 }
        while upper + 1 < pages.count, dayGroup(for: pages[upper + 1]) == group { upper += 1 }
        return PageProgress(count: upper - lower + 1, index: index - lower)
    }

    private static func dayGroup(for page: Page) -> DayGroup? {
        guard case let .poi(place) = page.mode, let cursor = page.cursor,
              let visit = place.checkIns.first(where: { $0.id == cursor.visitID }) else { return nil }
        return DayGroup(placeID: place.id, userID: visit.userId,
            day: POIVisitDay.key(for: visit, coordinate: place.poi.coordinate))
    }

    static func slices(in place: RatedPOI, ownerID: UUID,
                       metadataMediaIDs: [UUID: [UUID]] = [:]) -> [Slice] {
        let visits = place.checkIns.filter { $0.userId == ownerID }.sorted {
            if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
            return $0.id.uuidString > $1.id.uuidString
        }
        var seenVisits = Set<UUID>()
        return visits.filter { seenVisits.insert($0.id).inserted }.flatMap { visit in
            var seenMedia = Set<UUID>()
            let mediaIDs = ((metadataMediaIDs[visit.id] ?? []) + visit.media.map(\.id))
                .filter { seenMedia.insert($0).inserted }
            if mediaIDs.isEmpty {
                return [Slice(id: .init(visitID: visit.id, mediaID: nil), checkIn: visit, media: nil)]
            }
            return mediaIDs.map { mediaID in
                Slice(id: .init(visitID: visit.id, mediaID: mediaID), checkIn: visit,
                      media: visit.media.first { $0.id == mediaID })
            }
        }
    }

    static func index(in slices: [Slice], retaining cursor: Cursor?) -> Int? {
        guard !slices.isEmpty else { return nil }
        if let cursor {
            if let exact = slices.firstIndex(where: { $0.id == cursor }) { return exact }
            // A not-yet-known visit may acquire its descriptors after opening.
            // Stay at that visit instead of jumping to a newer neighbor.
            if let sameVisit = slices.firstIndex(where: { $0.id.visitID == cursor.visitID }) { return sameVisit }
        }
        return 0
    }

    /// Normally expand each POI where its original parent item already occurs.
    /// MyMap may opt into visit chronology without altering parent identities.
    /// The one native pager continues across a place boundary as an ordinary
    /// adjacent page; no nested scroller or extra swipe threshold is involved.
    static func pages(in items: [ExperienceDetailView.SequencePager.Item], ownerID: UUID,
                      metadataMediaIDs: [UUID: [UUID]] = [:], overviewID: UUID? = nil,
                      chronologicalPOIHistory: Bool = false) -> [Page] {
        let expanded = items.flatMap { item -> [Page] in
            if case let .poi(place) = item.mode, place.id != overviewID {
                let placeSlices = slices(in: place, ownerID: ownerID, metadataMediaIDs: metadataMediaIDs)
                if !placeSlices.isEmpty {
                    return placeSlices.map { slice in
                        Page(id: pageID(originID: item.id, cursor: slice.id), originID: item.id,
                             mode: item.mode, cursor: slice.id)
                    }
                }
            }
            return [Page(id: item.id, originID: item.id, mode: item.mode, cursor: nil)]
        }
        return chronologicalPOIHistory ? chronologicallyMerged(expanded) : expanded
    }

    private struct Run {
        var pages: [Page]
        var date: Date
        let originalOrder: Int
    }

    private static func chronologicallyMerged(_ pages: [Page]) -> [Page] {
        var visits: [Run] = []
        var unchanged: [Run] = []
        var previousWasUnchanged = false
        for (order, page) in pages.enumerated() {
            if let cursor = page.cursor, case let .poi(place) = page.mode,
               let visit = place.checkIns.first(where: { $0.id == cursor.visitID }) {
                if let last = visits.last, last.pages.last?.originID == page.originID,
                   last.pages.last?.cursor?.visitID == cursor.visitID {
                    visits[visits.count - 1].pages.append(page)
                } else {
                    visits.append(.init(pages: [page], date: visit.activityDate, originalOrder: order))
                }
                previousWasUnchanged = false
            } else {
                let date: Date
                switch page.mode {
                case let .real(post, _): date = post.activityDate
                case let .poi(place): date = place.checkIns.map(\.activityDate).max() ?? .distantPast
                case let .journey(journey): date = journey.createdAt
                }
                if previousWasUnchanged, let previous = unchanged.last?.pages.last,
                   samePostGroup(previous, page) {
                    unchanged[unchanged.count - 1].pages.append(page)
                    unchanged[unchanged.count - 1].date = max(unchanged[unchanged.count - 1].date, date)
                } else {
                    unchanged.append(.init(pages: [page], date: date, originalOrder: order))
                }
                previousWasUnchanged = true
            }
        }
        visits.sort {
            $0.date == $1.date ? $0.originalOrder < $1.originalOrder : $0.date > $1.date
        }
        // Posts remain in their original relative order and their existing
        // consecutive place groups remain indivisible; only POI visits move.
        var result: [Page] = []
        var visitIndex = 0
        for block in unchanged {
            while visitIndex < visits.count,
                  visits[visitIndex].date > block.date
                    || (visits[visitIndex].date == block.date
                        && visits[visitIndex].originalOrder < block.originalOrder) {
                result += visits[visitIndex].pages
                visitIndex += 1
            }
            result += block.pages
        }
        for run in visits.dropFirst(visitIndex) { result += run.pages }
        return result
    }

    private static func samePostGroup(_ first: Page, _ second: Page) -> Bool {
        guard case let .real(lhs, _) = first.mode, case let .real(rhs, _) = second.mode,
              lhs.userId == rhs.userId, let key = PostPlaceGrouping.placeKey(for: lhs) else { return false }
        return key == PostPlaceGrouping.placeKey(for: rhs)
    }

    static func selectedPageID(in pages: [Page], originID: UUID, cursor: Cursor?) -> UUID? {
        let matching = pages.filter { $0.originID == originID }
        if let cursor {
            if let exact = matching.first(where: { $0.cursor == cursor }) { return exact.id }
            if let visit = matching.first(where: { $0.cursor?.visitID == cursor.visitID }) { return visit.id }
        }
        return matching.first?.id ?? pages.first?.id
    }

    static func select(_ page: Page, currentOriginID: UUID,
                       updateCursor: (UUID, Cursor) -> Void, selectOrigin: (UUID) -> Void) {
        if let cursor = page.cursor, case let .poi(place) = page.mode { updateCursor(place.id, cursor) }
        if currentOriginID != page.originID { selectOrigin(page.originID) }
    }

    private static func pageID(originID: UUID, cursor: Cursor) -> UUID {
        let key = "personal-poi:\(originID):\(cursor.visitID):\(cursor.mediaID?.uuidString ?? "location")"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

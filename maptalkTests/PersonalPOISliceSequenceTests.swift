import CoreLocation
import Foundation
import Testing
@testable import maptalk

@MainActor
struct PersonalPOISliceSequenceTests {
    private let owner = id(1)
    private let other = id(2)

    @Test
    func includesEveryOwnedVisitAndMediaWithoutFreshnessFiltering() {
        let first = photo(101)
        let second = video(102)
        let old = visit(201, owner: owner, date: 1, media: [first, second])
        let latest = visit(202, owner: owner, date: 100, media: [photo(103)])
        let stranger = visit(203, owner: other, date: 200, media: [photo(104)])
        let place = place([old, latest, stranger])

        let slices = PersonalPOISliceSequence.slices(in: place, ownerID: owner)
        #expect(slices.map(\.id.visitID) == [latest.id, old.id, old.id])
        #expect(slices.map(\.id.mediaID) == [id(103), first.id, second.id])
        #expect(slices[1].checkIn.createdAt == old.createdAt)
        #expect(slices[2].media == second)
        #expect(place.checkIns.count == 3)
    }

    @Test
    func locationOnlyVisitIsItsOwnSliceAndNeverBorrowsMedia() {
        let earlier = visit(201, owner: owner, date: 1, media: [photo(101)])
        let latest = visit(202, owner: owner, date: 2, media: [])
        let slices = PersonalPOISliceSequence.slices(in: place([earlier, latest]), ownerID: owner)
        #expect(slices.count == 2)
        #expect(slices[0].checkIn.id == latest.id)
        #expect(slices[0].id.mediaID == nil)
        #expect(slices[0].media == nil)
        #expect(slices[1].media?.id == id(101))
    }

    @Test
    func coldMetadataReservesEverySlotAndSurvivesPartialHydration() {
        let pending = visit(201, owner: owner, date: 2, media: [])
        let earlier = visit(202, owner: owner, date: 1, media: [photo(103)])
        let metadata = [pending.id: [id(101), id(102)]]
        let cold = PersonalPOISliceSequence.slices(in: place([pending, earlier]), ownerID: owner,
            metadataMediaIDs: metadata)
        #expect(cold.count == 3)
        #expect(cold[0].id.mediaID == id(101))
        #expect(cold[1].id.mediaID == id(102))
        #expect(cold[0].media == nil)
        #expect(cold[1].media == nil)

        var partiallyReady = pending
        partiallyReady.media = [video(102)]
        let ready = PersonalPOISliceSequence.slices(in: place([partiallyReady, earlier]), ownerID: owner,
            metadataMediaIDs: metadata)
        #expect(ready.map(\.id) == cold.map(\.id))
        #expect(ready[0].media == nil)
        #expect(ready[1].media?.id == id(102))
        #expect(PersonalPOISliceSequence.index(in: ready, retaining: cold[1].id) == 1)
    }

    @Test
    func unknownPlaceholderAdoptsSameVisitWhenMetadataArrives() {
        let newest = visit(201, owner: owner, date: 2, media: [photo(101)])
        let unknown = visit(202, owner: owner, date: 1, media: [])
        let oldCursor = PersonalPOISliceSequence.Cursor(visitID: unknown.id, mediaID: nil)
        let ready = PersonalPOISliceSequence.slices(in: place([newest, unknown]), ownerID: owner,
            metadataMediaIDs: [unknown.id: [id(102), id(103)]])
        #expect(PersonalPOISliceSequence.index(in: ready, retaining: oldCursor) == 1)
        #expect(ready[1].id.visitID == unknown.id)
    }

    @Test
    func duplicateInputsDoNotInflateProgressAndOtherScopeNeverAddsPages() {
        let ownVisit = visit(201, owner: owner, date: 1, media: [photo(101), photo(101)])
        let otherVisit = visit(202, owner: other, date: 2, media: [photo(102)])
        let slices = PersonalPOISliceSequence.slices(in: place([ownVisit, ownVisit, otherVisit]), ownerID: owner,
            metadataMediaIDs: [ownVisit.id: [id(101), id(101)], otherVisit.id: [id(102), id(103)], id(999): [id(104)]])
        #expect(slices.count == 1)
        #expect(slices[0].id.visitID == ownVisit.id)
        #expect(slices[0].id.mediaID == id(101))
        #expect(PersonalPOISliceSequence.slices(in: place([ownVisit]), ownerID: other).isEmpty)
    }

    @Test
    func deletionOrOwnerChangeRepairsCursorOnlyInsideRemainingScope() {
        let oldCursor = PersonalPOISliceSequence.Cursor(visitID: id(201), mediaID: id(101))
        let remaining = visit(202, owner: owner, date: 1, media: [photo(102)])
        let slices = PersonalPOISliceSequence.slices(in: place([remaining]), ownerID: owner)
        #expect(PersonalPOISliceSequence.index(in: slices, retaining: oldCursor) == 0)
        #expect(PersonalPOISliceSequence.index(in: [], retaining: oldCursor) == nil)
    }

    @Test
    func flatteningKeepsOriginalParentOrderAndPostIdentity() {
        let firstPlace = place([visit(201, owner: owner, date: 1, media: [photo(101), photo(102)])], identifier: 501)
        let secondPlace = place([visit(202, owner: owner, date: 200, media: [photo(103), photo(104)])])
        let firstPost = post(701)
        let secondPost = post(702)
        let items: [ExperienceDetailView.SequencePager.Item] = [
            .init(id: firstPlace.id, mode: .poi(firstPlace)),
            .init(id: firstPost.id, mode: .real(firstPost, nil)),
            .init(id: secondPlace.id, mode: .poi(secondPlace)),
            .init(id: secondPost.id, mode: .real(secondPost, nil))
        ]
        let pages = PersonalPOISliceSequence.pages(in: items, ownerID: owner)
        #expect(pages.map(\.originID) == [firstPlace.id, firstPlace.id, firstPost.id,
                                         secondPlace.id, secondPlace.id, secondPost.id])
        #expect(pages[2].id == firstPost.id)
        #expect(pages[5].id == secondPost.id)
        #expect(pages[2].cursor == nil)
        #expect(pages[5].cursor == nil)
        #expect(Set(pages.map(\.id)).count == pages.count)
    }

    @Test
    func adjacentPlaceSelectionWritesOriginalParentBindingOnceButSamePlaceDoesNot() {
        let first = place([visit(201, owner: owner, date: 2, media: [photo(101), photo(102)])])
        let second = place([visit(202, owner: owner, date: 1, media: [photo(103)])], identifier: 501)
        let pages = PersonalPOISliceSequence.pages(in: [
            .init(id: first.id, mode: .poi(first)), .init(id: second.id, mode: .poi(second))
        ], ownerID: owner)
        var parentSelection = first.id
        var parentWrites: [UUID] = []
        var cursors: [UUID: PersonalPOISliceSequence.Cursor] = [:]
        func select(_ page: PersonalPOISliceSequence.Page) {
            PersonalPOISliceSequence.select(page, currentOriginID: parentSelection,
                updateCursor: { cursors[$0] = $1 }, selectOrigin: {
                    parentSelection = $0
                    parentWrites.append($0)
                })
        }
        select(pages[1])
        #expect(parentWrites.isEmpty)
        #expect(cursors[first.id]?.mediaID == id(102))
        select(pages[2])
        #expect(parentWrites == [second.id])
        #expect(parentSelection == second.id)
        select(pages[2])
        #expect(parentWrites == [second.id])
        #expect(PersonalPOISliceSequence.selectedPageID(in: pages, originID: first.id,
            cursor: cursors[first.id]) == pages[1].id)
    }

    @Test
    func chronologicalPOIHistoryInterleavesRepeatPlacesWithoutSplittingMediaOrPostGroups() {
        let newest = visit(201, owner: owner, date: 300, media: [photo(101), photo(102)])
        let oldest = visit(202, owner: owner, date: 100, media: [photo(103)])
        let middle = visit(203, owner: owner, date: 200, media: [photo(104)])
        let first = place([newest, oldest])
        let second = place([middle], identifier: 501)
        var firstPost = post(701)
        firstPost.createdAt = Date(timeIntervalSinceReferenceDate: 250)
        firstPost.locationID = id(800)
        var groupedPost = post(702)
        groupedPost.createdAt = Date(timeIntervalSinceReferenceDate: 50)
        groupedPost.locationID = id(800)
        let items: [ExperienceDetailView.SequencePager.Item] = [
            .init(id: first.id, mode: .poi(first)),
            .init(id: firstPost.id, mode: .real(firstPost, nil)),
            .init(id: groupedPost.id, mode: .real(groupedPost, nil)),
            .init(id: second.id, mode: .poi(second))
        ]
        let original = PersonalPOISliceSequence.pages(in: items, ownerID: owner)
        let ordered = PersonalPOISliceSequence.pages(in: items, ownerID: owner,
            chronologicalPOIHistory: true)
        #expect(original.compactMap(\.cursor?.visitID) == [newest.id, newest.id, oldest.id, middle.id])
        #expect(ordered.compactMap(\.cursor?.visitID) == [newest.id, newest.id, middle.id, oldest.id])
        #expect(ordered.map(\.originID) == [first.id, first.id, firstPost.id, groupedPost.id, second.id, first.id])
        #expect(Set(ordered.map(\.id)) == Set(original.map(\.id)))
        #expect(ordered.suffix(2).map(\.originID) == [second.id, first.id])
    }

    @Test
    func dayProgressJoinsOnlyAdjacentSamePlaceVisitsWithoutMovingSeparatedHistory() throws {
        var newest = visit(201, owner: owner, date: 300, media: [photo(101), photo(102)])
        var adjacent = visit(202, owner: owner, date: 275, media: [photo(103)])
        var laterReturn = visit(203, owner: owner, date: 100, media: [photo(104)])
        newest.visitDay = "2026-11-24"
        adjacent.visitDay = "2026-11-24"
        laterReturn.visitDay = "2026-11-24"
        let middle = visit(204, owner: owner, date: 200, media: [photo(105)])
        let first = place([newest, adjacent, laterReturn])
        let second = place([middle], identifier: 501)
        let pages = PersonalPOISliceSequence.pages(in: [
            .init(id: first.id, mode: .poi(first)), .init(id: second.id, mode: .poi(second))
        ], ownerID: owner, chronologicalPOIHistory: true)
        #expect(pages.compactMap(\.cursor?.visitID) == [newest.id, newest.id, adjacent.id, middle.id, laterReturn.id])
        let firstRun = try #require(PersonalPOISliceSequence.dayRunProgress(in: pages, selectedPageID: pages[2].id))
        #expect(firstRun.count == 3)
        #expect(firstRun.index == 2)
        let returnRun = try #require(PersonalPOISliceSequence.dayRunProgress(in: pages, selectedPageID: pages[4].id))
        #expect(returnRun.count == 1)
        #expect(returnRun.index == 0)
    }

    @Test
    func dateFilteringRetainsMatchingOldVisitWithoutReintroducingNewestVisit() throws {
        let recent = visit(201, owner: owner, date: 300, media: [photo(101)])
        let old = visit(202, owner: owner, date: 100, media: [photo(102)])
        let poi = place([recent, old])
        let record = UserMapRecord(id: poi.id, timestamp: recent.activityDate, kind: .poi(poi))
        let filtered = try #require(record.filteringDates { $0 < Date(timeIntervalSinceReferenceDate: 200) })
        #expect(filtered.id == record.id)
        #expect(filtered.timestamp == old.activityDate)
        guard case let .poi(result) = filtered.kind else {
            Issue.record("The date filter changed the POI record kind")
            return
        }
        #expect(result.checkIns.map(\.id) == [old.id])
        #expect(result.media.map(\.id) == [id(102)])
        #expect(PersonalPOISliceSequence.slices(in: result, ownerID: owner).map(\.id.visitID) == [old.id])
        #expect(record.filteringDates { _ in false } == nil)
        #expect(poi.checkIns.count == 2)
    }

    private func visit(_ value: Int, owner: UUID, date: TimeInterval,
                       media: [RatedPOI.Media]) -> RatedPOI.CheckIn {
        .init(id: id(value), userId: owner, createdAt: Date(timeIntervalSinceReferenceDate: date),
              endorsement: .solid, media: media, comment: "Original visit")
    }

    private func place(_ visits: [RatedPOI.CheckIn], identifier: Int = 500) -> RatedPOI {
        .init(poi: .init(id: id(identifier), name: "Place", coordinate: .init(latitude: 47.6, longitude: -122.3),
                        category: .viewpoint), highlight: nil, secondary: nil,
              media: visits.flatMap(\.media), checkIns: visits, comments: [],
              endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
              isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private func post(_ value: Int) -> RealPost {
        .init(id: id(value), userId: owner, center: .init(latitude: 47.6, longitude: -122.3),
              radiusMeters: 100, message: "Original post", attachments: [], likes: [], comments: [],
              visibility: .publicAll, createdAt: .distantPast, expiresAt: .distantFuture)
    }

    private func photo(_ value: Int) -> RatedPOI.Media {
        .init(id: id(value), kind: .photo(URL(fileURLWithPath: "/tmp/personal-poi-\(value).jpg")))
    }

    private func video(_ value: Int) -> RatedPOI.Media {
        .init(id: id(value), kind: .video(url: URL(fileURLWithPath: "/tmp/personal-poi-\(value).mp4"), poster: nil))
    }
}

private func id(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

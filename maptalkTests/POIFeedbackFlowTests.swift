import Foundation
import Testing
@testable import maptalk

@MainActor
struct POIFeedbackFlowTests {
    @Test
    func quickSelectionOnlySendsBeforeEnteringComposer() {
        var draft = POIFeedbackDraft()
        let quickSubmit = draft.select(.solid)
        #expect(quickSubmit)
        draft.beginComposing()
        draft.comment = "A quiet afternoon"
        let typedSubmit = draft.select(.hype)
        #expect(!typedSubmit)
        draft.comment = ""
        let clearedSubmit = draft.select(.solid)
        #expect(!clearedSubmit)
        #expect(draft.isComposing)
    }

    @Test
    func customFeelingPreservesCommentAndNeverCountsAsRating() {
        var draft = POIFeedbackDraft()
        draft.comment = "Still thinking about this"
        draft.selectCustom(POICustomFeeling.choices[0])
        #expect(draft.endorsement == nil)
        #expect(draft.customEmoji == POICustomFeeling.choices[0])
        #expect(draft.isValid)
        let replacedSubmit = draft.select(.solid)
        #expect(!replacedSubmit)
        #expect(draft.customEmoji == nil)
        #expect(draft.comment == "Still thinking about this")
        draft.selectCustom(POICustomFeeling.choices[1])
        #expect(draft.endorsement == nil)
        draft.comment = ""
        #expect(draft.isValid)
        draft.comment = "invalid\0text"
        #expect(!draft.isValid)
    }

    @Test
    func optionalDraftStartsUnratedAndAcceptsEitherInput() {
        var draft = POIFeedbackDraft()
        #expect(draft.endorsement == nil)
        #expect(!draft.hasContent)
        #expect(!draft.isValid)
        draft.comment = "  \n "
        #expect(!draft.isValid)
        draft.toggle(.hype)
        #expect(draft.isValid)
        #expect(draft.endorsement == .hype)
        draft.toggle(.hype)
        #expect(draft.endorsement == nil)
        #expect(!draft.isValid)
        draft.comment = "  Quiet enough to read. \n"
        #expect(draft.isValid)
        #expect(draft.trimmedComment == "Quiet enough to read.")
        draft.toggle(.meh)
        draft.toggle(.solid)
        #expect(draft.endorsement == .solid)
        draft.comment = String(repeating: "a", count: 1_001)
        #expect(!draft.isValid)
    }

    @Test
    func privateVisitFeedbackNeverChangesAnotherPublicVisitAtThatPlace() throws {
        let ownerID = UUID()
        let archive = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        let earlier = RatedPOI.CheckIn(userId: ownerID, createdAt: .now.addingTimeInterval(-100),
                                      publishedAt: .now.addingTimeInterval(-100))
        let privateVisit = RatedPOI.CheckIn(userId: ownerID)
        var personal = PreviewData.sampleRatedPOIs[0]
        personal.checkIns = [privateVisit, earlier]
        personal.comments = []
        personal.refreshEndorsementSummary()
        var publicPlace = personal
        publicPlace.checkIns = [earlier]
        archive.savePOI(personal, publicVersion: publicPlace, audience: .livePublic)

        #expect(archive.updatePOIFeedback(checkInID: privateVisit.id, endorsement: .hype,
                                        comment: "  A peaceful morning  "))
        let saved = try #require(archive.privatePOIs.first?.checkIns.first)
        #expect(saved.id == privateVisit.id)
        #expect(saved.createdAt == privateVisit.createdAt)
        #expect(saved.publishedAt == privateVisit.publishedAt)
        #expect(saved.comment == "A peaceful morning")
        #expect(saved.endorsement == .hype)
        #expect(archive.privatePOIs.first?.checkIns.count == 2)
        #expect(archive.publicPOIOverlays.first?.checkIns.count == 1)
        #expect(archive.publicPOIOverlays.first?.checkIns.first?.comment == nil)
        #expect(archive.publicPOIOverlays.first?.endorsements.hype == 0)
        #expect(archive.privateBubbleCatalog.isEmpty)

        // Retrying feedback is an update of the same visit, not a new check-in.
        #expect(archive.updatePOIFeedback(checkInID: privateVisit.id, endorsement: .hype,
                                        comment: "A peaceful morning"))
        #expect(archive.privatePOIs.first?.checkIns.count == 2)
        #expect(archive.privatePOIs.first?.endorsements.hype == 1)
        #expect(!archive.updatePOIFeedback(checkInID: UUID(), endorsement: .solid, comment: ""))
    }

    @Test
    func publicFeedbackAppearsWithTheExistingVisitWithoutChangingItsTime() throws {
        let ownerID = UUID()
        let archive = MyMapArchiveStore(currentUserID: ownerID, startsEmpty: true)
        let visit = RatedPOI.CheckIn(userId: ownerID)
        var place = PreviewData.sampleRatedPOIs[0]
        place.checkIns = [visit]
        place.comments = []
        place.refreshEndorsementSummary()
        archive.savePOI(place, publicVersion: place, audience: .livePublic)
        #expect(archive.updatePOIFeedback(checkInID: visit.id, endorsement: nil, comment: "Try the window seat."))
        let updated = try #require(archive.publicPOIOverlays.first)
        #expect(updated.checkIns.first?.comment == "Try the window seat.")
        #expect(updated.checkIns.first?.createdAt == visit.createdAt)
        #expect(updated.endorsements.hype == 0)
        #expect(updated.endorsements.solid == 0)
        #expect(updated.endorsements.meh == 0)
        #expect(updated.endorsements.questionable == 0)
        let view = ExperienceDetailView(mode: .poi(updated))
        let entries = view.checkInEngagements(for: updated)
        #expect(entries.first?.message == "Try the window seat.")
        #expect(entries.first?.timestamp == visit.activityDate)
        let notes = view.poiCommentEngagements(for: updated)
        #expect(notes.count == 1)
        #expect(notes.first?.id == visit.id)
        #expect(notes.first?.message == "Try the window seat.")
        #expect(updated.comments.isEmpty, "Visit feedback must not create a separate public place comment.")
    }
}

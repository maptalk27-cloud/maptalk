import CoreGraphics
import Testing
@testable import maptalk

@MainActor
struct MapTalkPostEntryDragTests {
    private let canvas = CGSize(width: 390, height: 760)
    private let controls = CGRect(x: 316, y: 480, width: 54, height: 196)

    @Test
    func temporaryPOIClearanceRestoresDefaultAndDraggedPositions() {
        let placements: [CGPoint?] = [nil, CGPoint(x: 210, y: 650)]
        for remembered in placements {
            let before = resting(remembered)
            let lifted = resting(remembered, clearance: 340)
            let after = resting(remembered)
            #expect(lifted.x == before.x)
            #expect(lifted.y < before.y)
            #expect(after == before)
        }
    }

    @Test
    func draggingTheLiftedEntryStartsAtItsVisiblePointAndReplacesUserPlacement() throws {
        let remembered = CGPoint(x: 210, y: 650)
        let lifted = resting(remembered, clearance: 340)
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: lifted, translation: CGSize(width: 20, height: -30))
        #expect(drag.center == CGPoint(x: lifted.x + 20, y: lifted.y - 30))
        let committed = drag.finish()
        let newPlacement = try #require(committed)
        #expect(resting(newPlacement) == newPlacement)
        #expect(resting(newPlacement) != remembered)
    }

    @Test
    func postReturnUsesMapPlacementNotThePOIsTemporaryLift() {
        let remembered = CGPoint(x: 210, y: 650)
        let lifted = resting(remembered, clearance: 340)
        // POI→Post is an in-place content switch. Once the entry is hidden,
        // its source returns to baseline and stays there through native close.
        let postSource = resting(remembered)
        let returnTarget = resting(remembered)
        let afterClose = resting(remembered)
        #expect(postSource != lifted)
        #expect(postSource == remembered)
        #expect(returnTarget == postSource)
        #expect(afterClose == returnTarget)
    }

    @Test
    func dragKeepsItsInitialOriginWhenParentPlacementChanges() {
        var drag = MapTalkPostEntryDrag()
        #expect(!drag.isActive)
        #expect(drag.center == nil)

        drag.update(startingAt: CGPoint(x: 80, y: 600),
                    translation: CGSize(width: 10, height: -20))
        #expect(drag.isActive)
        #expect(drag.center == CGPoint(x: 90, y: 580))

        // A parent update during the same drag must not become a new origin.
        drag.update(startingAt: CGPoint(x: 200, y: 350),
                    translation: CGSize(width: 30, height: -45))
        #expect(drag.center == CGPoint(x: 110, y: 555))
    }

    @Test
    func cancelledDragKeepsTheLastTrackedPointInsteadOfReturningToOrigin() {
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: CGPoint(x: 80, y: 600),
                    translation: CGSize(width: 90, height: -140))
        let lastPoint = drag.center

        // GestureState reset can be the only completion when a drag cancels.
        #expect(drag.finish() == lastPoint)
        #expect(lastPoint == CGPoint(x: 170, y: 460))
        #expect(!drag.isActive)
        #expect(drag.center == nil)
    }

    @Test
    func normalCompletionUsesTheFinalTranslationSample() {
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: CGPoint(x: 80, y: 600),
                    translation: CGSize(width: 90, height: -140))

        #expect(drag.finish(finalTranslation: CGSize(width: 96, height: -148))
                == CGPoint(x: 176, y: 452))
        #expect(!drag.isActive)
        #expect(drag.center == nil)
    }

    @Test
    func completionIsIdempotentAndTheNextDragGetsAFreshOrigin() {
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: CGPoint(x: 80, y: 600),
                    translation: CGSize(width: 20, height: -30))
        #expect(drag.finish() == CGPoint(x: 100, y: 570))
        #expect(drag.finish() == nil)
        #expect(drag.finish(finalTranslation: CGSize(width: 999, height: 999)) == nil)

        drag.update(startingAt: CGPoint(x: 210, y: 420),
                    translation: CGSize(width: -10, height: 15))
        #expect(drag.center == CGPoint(x: 200, y: 435))
        #expect(drag.finish() == CGPoint(x: 200, y: 435))
    }

    @Test
    func draggingAcrossTheControlObstacleRemainsContinuous() throws {
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: CGPoint(x: 330, y: 480),
                    translation: CGSize(width: 0, height: 8))
        let first = duringDrag(try #require(drag.center))
        drag.update(startingAt: CGPoint(x: 330, y: 480),
                    translation: CGSize(width: 0, height: 10))
        let second = duringDrag(try #require(drag.center))

        // These points straddle the nearest-edge decision of the controls.
        // Tracking must not project each sample onto different obstacle edges.
        #expect(first == CGPoint(x: 330, y: 488))
        #expect(second == CGPoint(x: 330, y: 490))
        #expect(second.x == first.x)
        #expect(second.y - first.y == 2)
    }

    @Test
    func releasedPositionAvoidsButtonsWithoutMovingToAScreenCorner() throws {
        var drag = MapTalkPostEntryDrag()
        drag.update(startingAt: CGPoint(x: 330, y: 480),
                    translation: CGSize(width: 0, height: 8))
        let finalPoint = drag.finish(finalTranslation: CGSize(width: 0, height: 10))
        let release = try #require(finalPoint)
        let settled = MapTalkPostEntryGeometry.constrainedCenter(release,
            canvasSize: canvas, topInset: 150, bottomInset: 16, excludedFrame: controls)
        let size = MapTalkPostEntryGeometry.size
        let frame = CGRect(x: settled.x - size.width / 2,
                           y: settled.y - size.height / 2,
                           width: size.width, height: size.height)

        #expect(settled == CGPoint(x: 275.5, y: 490))
        #expect(settled.x > canvas.width / 2)
        #expect(!frame.intersects(controls.insetBy(dx: -12, dy: -12)))
        #expect(!drag.isActive)
    }

    private func duringDrag(_ point: CGPoint) -> CGPoint {
        MapTalkPostEntryGeometry.constrainedCenter(point,
            canvasSize: canvas, topInset: 150, bottomInset: 16)
    }

    private func resting(_ point: CGPoint?, clearance: CGFloat? = nil) -> CGPoint {
        MapTalkPostEntryGeometry.restingCenter(point, canvasSize: canvas,
            topInset: 150, idleBottomInset: 16, clearanceBottomInset: clearance)
    }
}

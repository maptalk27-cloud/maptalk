import XCTest

final class MapTalkActivityRevisitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommentsOpenTheOriginalLargeCardAndClosePreservesActivityPosition() throws {
        let app = XCUIApplication()
        app.launch()

        let activityButton = app.buttons["maptalk.activity"]
        XCTAssertTrue(activityButton.waitForExistence(timeout: 8))
        activityButton.tap()

        let activity = app.descendants(matching: .any)["maptalk.activity.view"].firstMatch
        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(list.waitForExistence(timeout: 5))

        // These fixtures already ship with PreviewData. The Bubble is attached
        // to Reel 9301, but its notification must open Bubble 3001 itself.
        let fixtures = [
            RevisitFixture(
                kind: "reel", postID: "00000000-0000-0000-0000-000000000101", commentSeed: 3103,
                title: "Drone light show countdown on Pier 62.",
                comment: "City soundtrack is unreal tonight."
            ),
            RevisitFixture(
                kind: "bubble", postID: "00000000-0000-0000-0000-000000003001", commentSeed: 3052,
                title: "Hawaii neon arc",
                comment: "Dropping pins for these stops."
            ),
            RevisitFixture(
                kind: "place", postID: "BBBBBBBB-1111-2222-3333-444444444444", commentSeed: 6101,
                title: "Kirkland Waterfront",
                comment: "Busker playing city pop tonight—super chill vibes"
            )
        ]

        for fixture in fixtures {
            let row = app.buttons[fixture.rowIdentifier]
            reveal(row, in: list)
            let originalRowY = row.frame.midY
            row.tap()

            let detail = app.descendants(matching: .any)[fixture.detailIdentifier].firstMatch
            let close = app.buttons["maptalk.activity.detail.close"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(detail.frame.height, app.frame.height * 0.72,
                                 "A notification must open the existing card at its large detent")

            let comment = detail.descendants(matching: .any)[fixture.commentIdentifier].firstMatch
            XCTAssertTrue(comment.waitForExistence(timeout: 5))
            waitUntilHittable(comment)
            XCTAssertTrue(detail.staticTexts[fixture.comment].exists)
            assertIsolatedCard(detail, close: close, activityRow: row, in: app)
            attachScreenshot(app, name: "\(fixture.title) — focused comment")

            // Horizontal drags within the card may interact with its own
            // content, but must never advance to another feed post.
            drag(detail, from: CGVector(dx: 0.8, dy: 0.6), to: CGVector(dx: 0.2, dy: 0.6))
            assertIsolatedCard(detail, close: close, activityRow: row, in: app)
            XCTAssertTrue(comment.isHittable, "A horizontal swipe must retain the selected post's comment")
            drag(detail, from: CGVector(dx: 0.2, dy: 0.6), to: CGVector(dx: 0.8, dy: 0.6))
            assertIsolatedCard(detail, close: close, activityRow: row, in: app)
            XCTAssertTrue(comment.isHittable, "A horizontal swipe must retain the selected post's comment")

            close.tap()
            XCTAssertTrue(activity.waitForExistence(timeout: 5))
            waitUntilHittable(row)
            XCTAssertEqual(
                row.frame.midY, originalRowY, accuracy: 4,
                "Closing the card must reveal the same Activity row at the same scroll position"
            )
            XCTAssertFalse(detail.exists)
            attachScreenshot(app, name: "\(fixture.title) — Close to Activity")
        }
    }

    @MainActor
    func testLikeOpensTheOriginalLargeCardAndNativePullDownReturnsToActivity() throws {
        let app = XCUIApplication()
        app.launch()

        let activityButton = app.buttons["maptalk.activity"]
        XCTAssertTrue(activityButton.waitForExistence(timeout: 8))
        activityButton.tap()

        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let like = app.buttons[
            "maptalk.activity.row.reel-like-00000000-0000-0000-0000-000000000101-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        ]
        reveal(like, in: list)
        let originalRowY = like.frame.midY
        like.tap()

        let detail = app.descendants(matching: .any)[
            "maptalk.activity.detail.reel.00000000-0000-0000-0000-000000000101"
        ].firstMatch
        let close = app.buttons["maptalk.activity.detail.close"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        assertIsolatedCard(detail, close: close, activityRow: like, in: app)

        let post = detail.staticTexts["Drone light show countdown on Pier 62."].firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        waitUntilHittable(post)
        XCTAssertFalse(detail.descendants(matching: .any)[
            "experience.comment.00000000-0000-0000-0000-000000003103"
        ].firstMatch.isHittable)
        attachScreenshot(app, name: "Reel like — original expanded post")

        dismissNativeSheet(detail, in: app)
        waitUntilHittable(like)
        XCTAssertFalse(detail.exists, "Pulling down must dismiss, not collapse the card into the main feed")
        XCTAssertEqual(like.frame.midY, originalRowY, accuracy: 4,
                       "Native dismissal must preserve the Activity list's scroll position")
        attachScreenshot(app, name: "Reel like — Native dismissal to Activity")
    }

    @MainActor
    func testAttachedCapsuleUsesItsOwnMemoriesAndReturnsToTheOriginalPost() throws {
        let app = XCUIApplication()
        app.launch()

        let activityButton = app.buttons["maptalk.activity"]
        XCTAssertTrue(activityButton.waitForExistence(timeout: 8))
        activityButton.tap()

        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let like = app.buttons[
            "maptalk.activity.row.reel-like-00000000-0000-0000-0000-000000009301-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        ]
        reveal(like, in: list, maxAttempts: 60)
        let originalRowY = like.frame.midY
        like.tap()

        let detail = app.descendants(matching: .any)[
            "maptalk.activity.detail.reel.00000000-0000-0000-0000-000000009301"
        ].firstMatch
        let close = app.buttons["maptalk.activity.detail.close"]
        let capsuleBack = app.buttons["maptalk.activity.capsule.back"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(capsuleBack.exists)

        let parentPost = detail.staticTexts["Waikiki boardwalk glow before the night surf."].firstMatch
        XCTAssertTrue(parentPost.waitForExistence(timeout: 5))
        let capsule = detail.buttons["Journey memories"].firstMatch
        reveal(capsule, in: detail)
        capsule.tap()

        XCTAssertTrue(capsuleBack.waitForExistence(timeout: 5))
        waitUntilHittable(capsuleBack)
        XCTAssertFalse(parentPost.exists,
                       "Opening an attached capsule must show its first memory, not the parent Reel again")
        assertIsolatedCard(detail, close: close, activityRow: like, in: app)
        attachScreenshot(app, name: "Attached capsule — its own memories")

        capsuleBack.tap()
        XCTAssertTrue(parentPost.waitForExistence(timeout: 5))
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        XCTAssertFalse(capsuleBack.exists,
                       "Returning from the capsule must restore the original notification post")
        assertIsolatedCard(detail, close: close, activityRow: like, in: app)
        attachScreenshot(app, name: "Attached capsule — Back to original Reel")

        close.tap()
        waitUntilHittable(like)
        XCTAssertFalse(detail.exists)
        XCTAssertEqual(like.frame.midY, originalRowY, accuracy: 4,
                       "After capsule navigation, closing must still preserve the Activity list position")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in list: XCUIElement, maxAttempts: Int = 18) {
        for _ in 0..<maxAttempts where !row.isHittable {
            // Traverse long feeds quickly until the lazy row is loaded, then
            // take smaller steps to avoid skipping a partially visible target.
            let rowExists = row.exists
            let rowIsAboveList = rowExists && row.frame.maxY <= list.frame.minY
            drag(
                list,
                from: CGVector(dx: 0.5, dy: rowExists ? (rowIsAboveList ? 0.4 : 0.75) : 0.85),
                to: CGVector(dx: 0.5, dy: rowExists ? (rowIsAboveList ? 0.75 : 0.4) : 0.2)
            )
        }
        XCTAssertTrue(row.isHittable, "Expected the seeded Activity comment row")
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement) {
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    @MainActor
    private func assertIsolatedCard(
        _ detail: XCUIElement,
        close: XCUIElement,
        activityRow: XCUIElement,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(detail.exists, "A gesture must not change the notification's target post")
        XCTAssertTrue(close.isHittable, "The original expanded card must remain presented")
        XCTAssertFalse(activityRow.isHittable, "The Activity list must not receive touches beneath the card")
        XCTAssertFalse(app.buttons["maptalk.activity.detail.back"].exists,
                       "Revisits must not add a second custom detail-page header")
    }

    @MainActor
    private func dismissNativeSheet(_ detail: XCUIElement, in app: XCUIApplication) {
        let grabber = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@", "Sheet Grabber", "Sheet Grabber")
        ).firstMatch
        let start = grabber.exists
            ? grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            : detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        start.press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
        )
    }

    @MainActor
    private func drag(_ element: XCUIElement, from start: CGVector, to end: CGVector) {
        element.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: element.coordinate(withNormalizedOffset: end)
        )
    }

    private struct RevisitFixture {
        let kind: String
        let postID: String
        let commentSeed: Int
        let title: String
        let comment: String

        var rowIdentifier: String {
            "maptalk.activity.row.\(kind)-comment-\(uuid(commentSeed))"
        }

        var detailIdentifier: String {
            "maptalk.activity.detail.\(kind).\(postID)"
        }

        var commentIdentifier: String {
            "experience.comment.\(uuid(commentSeed))"
        }

        private func uuid(_ seed: Int) -> String {
            String(format: "00000000-0000-0000-0000-%012d", seed)
        }
    }
}

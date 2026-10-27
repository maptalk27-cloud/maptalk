import XCTest

/// Exercise the content surface, not the grabber: a working grabber alone does
/// not prove that a downward drag from the middle hands off to the sheet.
final class ExperienceSheetGestureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVideoMiddlePullCollapsesMapCardAndHorizontalPagingStillWorks() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let myMap = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMap.waitForExistence(timeout: 8))
        myMap.tap()

        let record = app.buttons["mymap.list-record.00000000-0000-0000-0000-000000009118"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()

        let pager = app.collectionViews["mymap.compact-capsule"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        waitForDetent("Half screen", in: app)
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45)).tap()
        waitForDetent("Expanded", in: app)

        let video = app.descendants(matching: .any)[
            "experience.real.video.00000000-0000-0000-0000-000000009118"
        ].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        attachEvidence(app, name: "Video — expanded before middle pull")
        // Deliberately begin on the video, far from the sheet grabber.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.91))
        )
        waitForDetent("Half screen", in: app)
        XCTAssertTrue(pager.exists, "A map card should collapse before leaving the map")
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists,
                       "Dragging over video must not activate its tap-to-open action")
        attachEvidence(app, name: "Video — middle pull returned to compact")

        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45)).tap()
        waitForDetent("Expanded", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).press(
            forDuration: 0.05,
            thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        )
        waitFor(NSPredicate(format: "hittable == false"), on: video,
                message: "Horizontal paging must still move to the next memory")
        waitForDetent("Expanded", in: app)
        attachEvidence(app, name: "Horizontal paging remains expanded")
    }

    @MainActor
    func testPhotoMiddlePullCollapsesMapCard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let myMap = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMap.waitForExistence(timeout: 8))
        myMap.tap()
        let record = app.buttons["mymap.list-record.00000000-0000-0000-0000-000000009122"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        for _ in 0..<3 where !record.isHittable { app.swipeUp() }
        XCTAssertTrue(record.isHittable)
        record.tap()

        let pager = app.collectionViews["mymap.compact-capsule"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        waitForDetent("Half screen", in: app)
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.7)).tap()
        waitForDetent("Expanded", in: app)
        attachEvidence(app, name: "Photo — expanded map card")
        // Slow enough to settle at the map's intermediate compact stop.
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.91))
        )
        waitForDetent("Half screen", in: app)
        XCTAssertTrue(pager.exists)
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)
        attachEvidence(app, name: "Photo — middle pull returned to compact")
    }

    @MainActor
    func testPhotoMiddlePullReturnsToActivityWithoutCompactFeedCard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let list = openActivity(app)
        let like = app.buttons[
            "maptalk.activity.row.reel-like-00000000-0000-0000-0000-000000000101-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        ]
        reveal(like, in: list)
        let originalY = like.frame.midY
        like.tap()
        let detail = activityDetail(in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        attachEvidence(app, name: "Photo — Activity post at top")

        // Native interactive dismissal remains cancellable. A short, slow
        // pull should track the finger and return to the expanded position.
        let initialFrame = detail.frame
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48)).press(
            forDuration: 0.05,
            thenDragTo: detail.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.60)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(app.buttons["maptalk.activity.detail.close"].isHittable)
        XCTAssertEqual(detail.frame.minY, initialFrame.minY, accuracy: 4)
        attachEvidence(app, name: "Photo — short middle pull cancels safely")
        middlePull(detail, in: app)

        waitFor(NSPredicate(format: "exists == false"), on: detail,
                message: "A middle-content pull must dismiss to Activity, not just bounce")
        waitFor(NSPredicate(format: "hittable == true"), on: like,
                message: "The original notification must be reachable again")
        XCTAssertEqual(like.frame.midY, originalY, accuracy: 4)
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists,
                       "Activity must not leave a compact main-feed card behind")
        attachEvidence(app, name: "Photo — middle pull returned to Activity")
    }

    @MainActor
    func testScrolledCommentsMoveBeforeTheSheetDismisses() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let list = openActivity(app)
        let row = app.buttons["maptalk.activity.row.reel-comment-00000000-0000-0000-0000-000000003103"]
        reveal(row, in: list)
        row.tap()

        let detail = activityDetail(in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let comment = detail.descendants(matching: .any)[
            "experience.comment.00000000-0000-0000-0000-000000003103"
        ].firstMatch
        waitFor(NSPredicate(format: "hittable == true"), on: comment,
                message: "Opening the notification should focus its comment")
        let title = detail.staticTexts["Drone light show countdown on Pier 62."].firstMatch
        XCTAssertFalse(title.isHittable, "This fixture must actually be scrolled away from its top")
        let initialTitleY = title.frame.minY

        // A short reverse scroll while reading a long thread is not an exit.
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)).press(
            forDuration: 0.05,
            thenDragTo: detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.57))
        )
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(app.buttons["maptalk.activity.detail.close"].isHittable)
        XCTAssertGreaterThan(title.frame.minY, initialTitleY + 10,
                             "Content must scroll toward its top before the sheet takes over")
        attachEvidence(app, name: "Long comments — reverse scroll stays inside card")

        app.buttons["maptalk.activity.detail.close"].tap()
        waitFor(NSPredicate(format: "hittable == true"), on: row,
                message: "Closing the comment must still return to Activity")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func openActivity(_ app: XCUIApplication) -> XCUIElement {
        let activity = app.buttons["maptalk.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 8))
        activity.tap()
        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        return list
    }

    @MainActor
    private func activityDetail(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[
            "maptalk.activity.detail.reel.00000000-0000-0000-0000-000000000101"
        ].firstMatch
    }

    @MainActor
    private func middlePull(_ detail: XCUIElement, in app: XCUIApplication) {
        // From the middle there is less than half a sheet of travel left.
        // Use an actual release flick: the default 500 pt/s drag correctly
        // cancels natively here, even when the sheet follows the finger.
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.96)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in list: XCUIElement) {
        for _ in 0..<24 where !row.isHittable {
            let above = row.exists && row.frame.maxY <= list.frame.minY
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.3 : 0.78)).press(
                forDuration: 0.05,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.78 : 0.25))
            )
        }
        XCTAssertTrue(row.isHittable, "The existing demo notification must be reachable")
    }

    @MainActor
    private func waitForDetent(_ value: String, in app: XCUIApplication) {
        waitFor(NSPredicate(format: "exists == true AND value == %@", value),
                on: app.buttons["Sheet Grabber"], message: "Expected native sheet detent: \(value)")
    }

    @MainActor
    private func waitFor(_ predicate: NSPredicate, on element: XCUIElement, message: String) {
        let condition = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed, message)
    }

    @MainActor
    private func attachEvidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) — hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

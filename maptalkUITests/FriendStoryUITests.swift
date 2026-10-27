import XCTest

/// Uses the existing simulator and demo fixtures. No authentication, live
/// publishing, device installation or destructive fixture reset is required.
final class FriendStoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOneAuthorEntryOwnsBothPOIAndReelUpdates() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let authorID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        let author = revealAuthor(authorID, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "friend-story.author.\(authorID)").count, 1)
        author.tap()
        evidence(app, name: "Person story — initial compact card")
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        rewind(app)

        var sawPlace = false
        var sawReel = false
        for _ in 0..<90 {
            XCTAssertEqual(currentAuthor(app).value as? String, "aurora.wave")
            sawPlace = sawPlace || app.buttons["friend-story.open-place"].exists
            sawReel = sawReel || app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "experience.real.caption.")
            ).count > 0
            if sawPlace && sawReel { break }
            let next = app.buttons["friend-story.next-page"]
            if !next.isEnabled { break }
            changePage(using: next, app: app)
        }
        XCTAssertTrue(sawPlace, "Exact POI visits must participate in the author's story")
        XCTAssertTrue(sawReel, "The same author entry must retain the original Reel card")
        evidence(app, name: "One person — mixed original records")
        let caption = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "experience.real.caption.")
        ).firstMatch
        XCTAssertTrue(caption.isHittable)
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: caption.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        )
        waitForAuthorChange(from: "aurora.wave", app: app)
    }

    @MainActor
    func testPlaceReturnsToExactPageAndExpandedNavigationKeepsDetent() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        rewind(app)
        // Choose an interior POI slice so both media-edge directions are real
        // navigation rather than relying only on the header arrow controls.
        for _ in 0..<90 {
            let previous = app.buttons["friend-story.previous-page"]
            let next = app.buttons["friend-story.next-page"]
            if app.buttons["friend-story.open-place"].exists && previous.isEnabled && next.isEnabled { break }
            XCTAssertTrue(next.isEnabled, "The demo author must have an interior POI update")
            changePage(using: next, app: app)
        }
        let pageID = currentPage(app).identifier
        let author = currentAuthor(app).value as? String

        let stage = app.descendants(matching: .any)["friend-story.poi-stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 3))
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        waitForPageChange(from: pageID, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        changePage(using: app.buttons["friend-story.next-page"], app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        waitForPageChange(from: pageID, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        changePage(using: app.buttons["friend-story.previous-page"], app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForDetent("Expanded", app: app)
        app.buttons["friend-story.open-place"].tap()
        let back = app.buttons["maptalk.friend-story.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)

        let next = app.buttons["friend-story.next-page"]
        XCTAssertTrue(next.isEnabled, "The seeded author should have a subsequent update")
        changePage(using: next, app: app)
        waitForDetent("Expanded", app: app)
        XCTAssertNotEqual(currentPage(app).identifier, pageID)
        evidence(app, name: "Place returns exactly — next item stays expanded")
    }

    @MainActor
    func testMapDragDoesNotSwitchAuthorButHorizontalCardDragDoes() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        rewind(app)
        findPlacePage(app)
        let originalAuthor = currentAuthor(app).value as? String
        let originalPage = currentPage(app).identifier

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        )
        XCTAssertEqual(currentAuthor(app).value as? String, originalAuthor)
        XCTAssertEqual(currentPage(app).identifier, originalPage)

        let stage = app.descendants(matching: .any)["friend-story.poi-stage"].firstMatch
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.5))
        )
        waitForAuthorChange(from: originalAuthor ?? "", app: app)
        XCTAssertTrue(app.buttons["friend-story.close"].exists)
        evidence(app, name: "Map stays independent — swipe selects next person")
    }

    @MainActor
    func testDownwardPullCollapsesWithoutSwitchingPersonAndCloseExits() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        rewind(app)
        findPlacePage(app)
        let pageID = currentPage(app).identifier
        let stage = app.descendants(matching: .any)["friend-story.poi-stage"].firstMatch
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForDetent("Expanded", app: app)
        let author = currentAuthor(app).value as? String
        let expandedFrame = stage.frame
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.44)).press(
            forDuration: 0.05,
            thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.58)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Expanded", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        XCTAssertEqual(stage.frame.minY, expandedFrame.minY, accuracy: 4,
                       "A short diagonal pull should cancel natively, not switch person or move the card permanently")
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.45)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.88)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Half screen", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        app.buttons["friend-story.close"].tap()
        waitUntilAbsent(app.buttons["friend-story.close"])
        XCTAssertFalse(app.buttons["maptalk.friend-story.back"].exists)
        evidence(app, name: "Middle pull collapses — explicit close exits")
    }

    @MainActor
    func testNotificationsRemainIsolatedFromPersonStoryNavigation() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let activity = app.buttons["maptalk.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 8))
        activity.tap()
        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "maptalk.activity.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let close = app.buttons["maptalk.activity.detail.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["friend-story.next-page"].exists)
        XCTAssertFalse(app.buttons["friend-story.close"].exists)
        close.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["friend-story.close"].exists)
    }

    @MainActor
    func testOriginalReelPhotoAndBubbleReturnToExactStory() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(app.buttons["friend-story.close"].waitForExistence(timeout: 5))
        rewind(app)
        let reelID = "00000000-0000-0000-0000-000000009301"
        let expectedPage = "friend-story.page.reel:\(reelID)"
        for _ in 0..<90 {
            if currentPage(app).identifier == expectedPage { break }
            let next = app.buttons["friend-story.next-page"]
            XCTAssertTrue(next.isEnabled, "The existing demo author must retain the Waikiki Reel")
            changePage(using: next, app: app)
        }
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        let author = currentAuthor(app).value as? String
        let navigation = app.descendants(matching: .any)["friend-story.navigation"].firstMatch
        let avatar = app.descendants(matching: .any)["experience.real.avatar.\(reelID)"].firstMatch
        let likes = app.descendants(matching: .any)["experience.real.likes.\(reelID)"].firstMatch
        // The compact card's existing Open-details trait can expose its Text
        // descendants as buttons. Match the exact ID, not an inferred AX type.
        let timestamp = app.descendants(matching: .any)["experience.real.timestamp.\(reelID)"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        XCTAssertTrue(likes.waitForExistence(timeout: 5))
        XCTAssertTrue(timestamp.waitForExistence(timeout: 5))
        XCTAssertTrue(avatar.isHittable, "The original Reel avatar must remain visible in compact mode")
        XCTAssertGreaterThanOrEqual(avatar.frame.minY, navigation.frame.maxY - 1,
                                    "The story navigation must not clip the original card header")
        XCTAssertGreaterThanOrEqual(avatar.frame.height, 33,
                                    "The original 34 pt compact avatar must not be partially clipped")
        for footerItem in [likes, timestamp] {
            XCTAssertTrue(footerItem.isHittable, "The original timestamp and engagement footer must be visible before expanding")
            XCTAssertLessThanOrEqual(footerItem.frame.maxY, app.frame.maxY - 24,
                                     "The entire compact footer must fit above the bottom safe area")
        }
        evidence(app, name: "Original Reel — compact photo and Bubble")

        // Use the ordinary native grabber, not a test-only expansion hook.
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        )
        waitForDetent("Expanded", app: app)
        let caption = app.staticTexts["experience.real.caption.\(reelID)"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        let photo = app.buttons["experience.real.photo.\(reelID).00000000-0000-0000-0000-000000009302"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        let closePhoto = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(closePhoto.waitForExistence(timeout: 5), "Original Reel photos must still use the original media viewer")
        XCTAssertFalse(app.buttons["friend-story.next-page"].isHittable)
        evidence(app, name: "Original Reel — original photo viewer")
        closePhoto.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)

        let capsule = app.buttons["Journey memories"].firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if capsule.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.42))
            )
        }
        XCTAssertTrue(capsule.isHittable)
        capsule.tap()
        let back = app.buttons["maptalk.friend-story.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(caption.exists, "The Bubble must open its own memories, not the parent Reel")
        XCTAssertFalse(app.buttons["friend-story.next-page"].isHittable)
        evidence(app, name: "Person story — original attached Bubble")
        back.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)
        XCTAssertTrue(capsule.exists)
        evidence(app, name: "Photo and Bubble — exact original Reel restored")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func revealAuthor(_ id: String, app: XCUIApplication) -> XCUIElement {
        let rail = app.descendants(matching: .any)["maptalk.friend-story.rail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 8))
        let author = app.buttons["friend-story.author.\(id)"]
        for _ in 0..<24 {
            if author.isHittable { break }
            rail.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)).press(
                forDuration: 0.05,
                thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
            )
        }
        XCTAssertTrue(author.isHittable, "Expected an existing demo author in the person rail")
        return author
    }

    @MainActor
    private func currentAuthor(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["friend-story.open-author"].firstMatch
    }

    @MainActor
    private func currentPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend-story.page.")).firstMatch
    }

    @MainActor
    private func rewind(_ app: XCUIApplication) {
        let previous = app.buttons["friend-story.previous-page"]
        for _ in 0..<90 {
            if !previous.isEnabled { break }
            changePage(using: previous, app: app)
        }
        XCTAssertFalse(previous.isEnabled)
    }

    @MainActor
    private func findPlacePage(_ app: XCUIApplication) {
        let place = app.buttons["friend-story.open-place"]
        for _ in 0..<90 {
            if place.exists { break }
            let next = app.buttons["friend-story.next-page"]
            XCTAssertTrue(next.isEnabled, "The seeded author should have a POI slice")
            changePage(using: next, app: app)
        }
        XCTAssertTrue(place.waitForExistence(timeout: 3))
    }

    @MainActor
    private func changePage(using button: XCUIElement, app: XCUIApplication) {
        let page = currentPage(app)
        XCTAssertTrue(page.waitForExistence(timeout: 3), "The visible progress must expose the current update")
        let oldID = page.identifier
        XCTAssertTrue(button.isHittable, "Visible story navigation must be directly tappable")
        button.tap()
        waitForPageChange(from: oldID, app: app)
    }

    @MainActor
    private func waitForPageChange(from oldID: String, app: XCUIApplication) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "identifier != %@", oldID), object: currentPage(app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "A navigation tap must advance the update")
    }

    @MainActor
    private func waitForAuthorChange(from handle: String, app: XCUIApplication) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", handle), object: currentAuthor(app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    @MainActor
    private func waitForDetent(_ value: String, app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: grabber)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func waitUntilAbsent(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func evidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

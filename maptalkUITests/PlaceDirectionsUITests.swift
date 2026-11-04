import XCTest

/// Demo-only acceptance: no real account, publishing or physical device access.
final class PlaceDirectionsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPOIDirectionsCancelAndAppleMapsReturnPreserveStoryAndPaging() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let author = app.buttons["friend-story.author.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1"]
        XCTAssertTrue(author.waitForExistence(timeout: 8))
        author.tap()
        XCTAssertTrue(page(app).waitForExistence(timeout: 5))

        // Find an existing media visit through the real pager, not a test route.
        for _ in 0..<12 {
            if page(app).identifier.hasPrefix("friend-story.page.poi:"), poiMedia(app).exists { break }
            swipeNext(app)
        }
        XCTAssertTrue(page(app).identifier.hasPrefix("friend-story.page.poi:"))
        XCTAssertTrue(poiMedia(app).exists)
        let pageID = page(app).identifier
        let card = element("friend-story.card", app)
        let detent = card.value as? String

        let directions = app.buttons["place.directions"].firstMatch
        assertDirectionsTarget(directions, app: app)
        directions.tap()
        assertChooser(app)
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)
        evidence(app, "POI compact directions chooser")
        cancelChooser(app)
        XCTAssertTrue(directions.waitForExistence(timeout: 4))
        XCTAssertEqual(page(app).identifier, pageID)
        XCTAssertEqual(card.value as? String, detent)

        // The same media must still open once and return to the same story.
        poiMedia(app).coordinate(withNormalizedOffset: .init(dx: 0.55, dy: 0.48)).tap()
        let close = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(page(app).waitForExistence(timeout: 5))
        XCTAssertEqual(page(app).identifier, pageID)

        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.12)))
        waitUntil { card.value as? String == "Expanded" }
        assertDirectionsTarget(directions, app: app)
        evidence(app, "POI expanded directions stays inside original media")
        directions.tap()
        assertChooser(app)
        cancelChooser(app)
        XCTAssertEqual(page(app).identifier, pageID)
        XCTAssertEqual(card.value as? String, "Expanded")

        directions.tap()
        assertChooser(app)
        app.buttons["Apple Maps"].tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 10),
                      "Apple Maps must receive the real URL handoff")
        evidence(maps, "Apple Maps receives demo place destination")
        app.activate()
        XCTAssertTrue(page(app).waitForExistence(timeout: 5))
        XCTAssertEqual(page(app).identifier, pageID)
        XCTAssertEqual(card.value as? String, "Expanded")
        XCTAssertTrue(directions.isHittable)
        swipeNext(app)
        XCTAssertNotEqual(page(app).identifier, pageID,
                          "Returning from maps must not leave the pager locked")
        evidence(app, "POI story remains interactive after returning from Apple Maps")
    }

    @MainActor
    func testReelVideoDirectionsDoNotStealPreviewOrBubbleTaps() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let myMap = app.buttons["MyMap"]
        XCTAssertTrue(myMap.waitForExistence(timeout: 8))
        myMap.tap()
        if app.buttons["Show list"].exists { app.buttons["Show list"].tap() }
        let id = "00000000-0000-0000-0000-000000009118"
        let record = app.buttons["mymap.list-record.\(id)"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let pager = app.collectionViews["mymap.compact-capsule"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let directions = app.buttons["experience.real.directions.\(id)"].firstMatch
        assertDirectionsTarget(directions, app: app)
        directions.tap()
        assertChooser(app)
        cancelChooser(app)
        XCTAssertTrue(directions.isHittable)
        evidence(app, "Reel compact video directions")

        pager.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.45)).tap()
        let video = element("experience.real.video.\(id)", app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        assertDirectionsTarget(directions, app: app)
        directions.tap()
        assertChooser(app)
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)
        cancelChooser(app)
        evidence(app, "Reel full video directions and original Bubble")
        video.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.45)).tap()
        let close = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let bubble = app.buttons["Journey memories"].firstMatch
        XCTAssertTrue(bubble.isHittable, "Directions must not cover the original Bubble control")

        // This simulator has no Google Maps app: the official HTTPS URL must
        // still hand off to the browser, without requiring an SDK or login.
        directions.tap()
        assertChooser(app)
        app.buttons["Google Maps"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        evidence(safari, "Google Maps browser fallback receives demo destination")
        app.activate()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        XCTAssertTrue(directions.isHittable)
    }

    @MainActor private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func page(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "friend-story.page.")).firstMatch
    }

    @MainActor private func poiMedia(_ app: XCUIApplication) -> XCUIElement {
        let id = page(app).identifier.split(separator: ":").last.map(String.init) ?? ""
        return app.buttons.matching(NSPredicate(format: "identifier IN %@", [
            "friend-story.poi.media.\(id)", "experience.poi.featured-media.\(id)"
        ])).firstMatch
    }

    @MainActor private func swipeNext(_ app: XCUIApplication) {
        let old = page(app).identifier
        let card = element("friend-story.card", app)
        let media = poiMedia(app)
        let target = media.exists && media.isHittable ? media : card
        let visible = target.frame.intersection(card.frame).intersection(app.frame)
        let y = target == card ? CGFloat(0.15) : (visible.midY - target.frame.minY) / target.frame.height
        target.coordinate(withNormalizedOffset: .init(dx: 0.84, dy: y)).press(forDuration: 0.05,
            thenDragTo: target.coordinate(withNormalizedOffset: .init(dx: 0.16, dy: y)))
        waitUntil { self.page(app).identifier != old }
    }

    @MainActor private func assertDirectionsTarget(_ button: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        // A native compact sheet can uniformly scale the authored 44-point target.
        XCTAssertGreaterThanOrEqual(button.frame.width, 42)
        XCTAssertGreaterThanOrEqual(button.frame.height, 42)
        XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY)
    }

    @MainActor private func assertChooser(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Apple Maps"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Google Maps"].exists)
        evidence(app, "Native maps provider chooser")
    }

    @MainActor private func cancelChooser(_ app: XCUIApplication) {
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // iOS 26 may present this as an anchored popover, whose standard
            // cancellation is tapping outside rather than a Cancel row.
            app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.25)).tap()
        }
        waitUntil { !app.buttons["Apple Maps"].exists }
    }

    @MainActor private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed)
    }

    @MainActor private func evidence(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

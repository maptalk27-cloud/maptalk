import XCTest

final class PrivateHighlightsUITests: XCTestCase {
    private let afterDarkID = "00000000-0000-0000-0000-000000008101"
    private let portraitReelID = "00000000-0000-0000-0000-000000009118"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreationCancelKeepsDirectoryAndBlankNameUsesFallback() {
        let app = launchHighlights()
        let rows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mymap.collection-folder."
        ))
        let originalCount = rows.count

        app.buttons["mymap.collections-add"].tap()
        let naming = app.alerts["New highlight"]
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        naming.textFields["Highlight name"].tap()
        naming.textFields["Highlight name"].typeText("Cancelled highlight")
        naming.buttons["Cancel"].tap()
        assertGone(naming)
        XCTAssertEqual(rows.count, originalCount)
        XCTAssertFalse(app.buttons["Open Cancelled highlight"].exists)

        app.buttons["mymap.collections-add"].tap()
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        // A new attempt must not reuse the cancelled draft. Blank names are valid.
        let field = naming.textFields["Highlight name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
        naming.buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["Untitled Highlight"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No memories yet"].exists)
        returnToHighlights(app)
        XCTAssertEqual(rows.count, originalCount + 1)
        let created = rows.matching(NSPredicate(format: "label == %@", "Open Untitled Highlight")).firstMatch
        XCTAssertTrue(created.exists)
        XCTAssertEqual(created.value as? String, "0 memories, Only you")
    }

    @MainActor
    func testRenameRejectsWhitespaceAndRemovingMemberPreservesOriginal() {
        let app = launchHighlights()
        openAfterDark(app)

        app.buttons["Highlight options"].tap()
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename highlight"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        let field = rename.textFields["Highlight name"]
        replaceText(in: field, with: "   ")
        XCTAssertFalse(rename.buttons["Save"].isEnabled)
        replaceText(in: field, with: "  Lanai memories  ")
        XCTAssertTrue(rename.buttons["Save"].isEnabled)
        rename.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Lanai memories"].waitForExistence(timeout: 3))

        let member = app.buttons["mymap.collection-memory.\(portraitReelID)"]
        XCTAssertTrue(member.waitForExistence(timeout: 3))
        member.swipeLeft()
        let remove = app.buttons["Remove from highlight"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        assertGone(member)
        XCTAssertTrue(app.staticTexts["2 memories"].exists)

        returnToHighlights(app)
        let folder = app.buttons["mymap.collection-folder.\(afterDarkID)"]
        XCTAssertEqual(folder.label, "Open Lanai memories")
        XCTAssertEqual(folder.value as? String, "2 memories, Only you")
        app.buttons["Close"].tap()
        assertOriginalMemory(app, id: portraitReelID, search: "Kyoto")
    }

    @MainActor
    func testDeleteCancelPreservesHighlightAndConfirmedDeleteKeepsEveryOriginal() {
        let app = launchHighlights()
        attachScreenshot(app, name: "Private highlights — directory")
        openAfterDark(app)
        attachScreenshot(app, name: "Private highlights — detail")

        openDeleteConfirmation(app)
        attachScreenshot(app, name: "Private highlights — delete confirmation")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // iOS 26 may present an anchored popover with outside-tap dismissal.
            // System dismiss regions can extend beyond the screen; use the visible
            // sheet body outside the popover, without hitting an underlying action.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        }
        assertGone(app.buttons["Delete highlight"])
        XCTAssertTrue(app.navigationBars["After dark"].exists)
        XCTAssertTrue(app.buttons["mymap.collection-memory.\(portraitReelID)"].exists)
        returnToHighlights(app)
        XCTAssertTrue(app.buttons["mymap.collection-folder.\(afterDarkID)"].exists)

        openAfterDark(app)
        openDeleteConfirmation(app)
        app.buttons["Delete highlight"].tap()
        XCTAssertTrue(app.navigationBars["Highlights"].waitForExistence(timeout: 3))
        assertGone(app.buttons["mymap.collection-folder.\(afterDarkID)"])
        XCTAssertTrue(app.buttons["mymap.collection-folder.00000000-0000-0000-0000-000000008102"].exists)
        app.buttons["Close"].tap()

        assertOriginalMemory(app, id: portraitReelID, search: "Kyoto")
        assertOriginalMemory(app, id: "00000000-0000-0000-0000-000000009120", search: "Lagos")
        assertOriginalMemory(app, id: "00000000-0000-0000-0000-000000007006", search: "Charoen")
    }

    @MainActor
    private func launchHighlights() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let tab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let entry = app.buttons["mymap.collections-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "Highlights")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Highlights"].waitForExistence(timeout: 3))
        return app
    }

    @MainActor
    private func openAfterDark(_ app: XCUIApplication) {
        let row = app.buttons["mymap.collection-folder.\(afterDarkID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mymap.collection-list.\(afterDarkID)"]
            .waitForExistence(timeout: 3))
    }

    @MainActor
    private func returnToHighlights(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Highlights"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.navigationBars["Highlights"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func openDeleteConfirmation(_ app: XCUIApplication) {
        app.buttons["Highlight options"].tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.buttons["Delete highlight"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The original POIs and Reels will stay in MyMap."].exists)
    }

    @MainActor
    private func assertOriginalMemory(_ app: XCUIApplication, id: String, search: String) {
        let searchField = app.textFields["Search memories"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        replaceText(in: searchField, with: search)
        XCTAssertTrue(app.buttons["mymap.list-record.\(id)"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // These short names fit the field; tapping its trailing edge puts the caret at the end.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let value = field.value as? String ?? ""
        let count = value == field.placeholderValue ? 0 : value.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }

    @MainActor
    private func assertGone(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 3)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

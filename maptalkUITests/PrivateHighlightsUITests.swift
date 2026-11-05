import XCTest

final class PrivateHighlightsUITests: XCTestCase {
    private let afterDarkID = "00000000-0000-0000-0000-000000008101"
    private let portraitReelID = "00000000-0000-0000-0000-000000009118"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShelfCoverOpensExistingDetailAndAddingReturnsToSameHighlight() {
        let app = launchMyMap()
        let cover = app.buttons["mymap.highlight.\(afterDarkID)"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertEqual(cover.label, "Open After dark")
        XCTAssertEqual(cover.value as? String, "3 memories, Only you")
        attachScreenshot(app, name: "MyMap — private Highlights shelf")
        cover.tap()

        let detail = app.descendants(matching: .any)["mymap.collection-list.\(afterDarkID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["After dark"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.map-folder-scope.\(afterDarkID)"].exists)
        app.buttons["Add memories"].tap()

        XCTAssertTrue(app.navigationBars["Add to After dark"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["mymap.highlights-shelf"].exists)
        XCTAssertTrue(app.textFields["Search memories"].exists)
        XCTAssertTrue(app.buttons["Filter records"].exists)
        app.buttons["mymap.cancel-selection"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["After dark"].exists)

        app.buttons["Add memories"].tap()
        let nairobiID = "00000000-0000-0000-0000-000000009122"
        let memory = app.buttons["mymap.list-record.\(nairobiID)"]
        XCTAssertTrue(memory.waitForExistence(timeout: 3))
        memory.tap()
        app.buttons["mymap.add-selected-memories"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["mymap.collection-memory.\(nairobiID)"].exists)

        returnToHighlights(app)
        XCTAssertEqual(app.buttons["mymap.collection-folder.\(afterDarkID)"].value as? String,
                       "4 memories, Only you")
        app.buttons["Close"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 3))
        XCTAssertEqual(cover.value as? String, "4 memories, Only you")
    }

    @MainActor
    func testShelfCreationCanCancelAndSharesOneDirectory() {
        let app = launchMyMap()
        let covers = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mymap.highlight."
        ))
        let originalCount = covers.count
        let create = app.buttons["mymap.highlights-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()

        let naming = app.alerts["New highlight"]
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        naming.textFields["Highlight name"].tap()
        naming.textFields["Highlight name"].typeText("Cancelled shelf draft")
        naming.buttons["Cancel"].tap()
        assertGone(naming)
        XCTAssertEqual(covers.count, originalCount)
        XCTAssertFalse(app.buttons["Open Cancelled shelf draft"].exists)

        create.tap()
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        let field = naming.textFields["Highlight name"]
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
        field.tap()
        field.typeText("Lanai stays")
        naming.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Lanai stays"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No memories yet"].exists)
        returnToHighlights(app)

        let created = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "mymap.collection-folder.", "Open Lanai stays"
        ))
        XCTAssertEqual(created.count, 1, "The shelf and directory must reference one shared highlight")
        XCTAssertEqual(created.firstMatch.value as? String, "0 memories, Only you")
        app.buttons["Close"].tap()
        XCTAssertEqual(covers.count, originalCount + 1)
        let newCover = covers.matching(NSPredicate(format: "label == %@", "Open Lanai stays")).firstMatch
        XCTAssertTrue(newCover.exists)
        XCTAssertEqual(newCover.value as? String, "0 memories, Only you")
    }

    @MainActor
    func testEmptyShelfKeepsCreationAvailableAfterDeletingEveryHighlight() {
        let app = launchHighlights()
        for id in [afterDarkID, "00000000-0000-0000-0000-000000008102"] {
            let row = app.buttons["mymap.collection-folder.\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.swipeLeft()
            let delete = app.buttons["Delete highlight"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            delete.tap()
            assertGone(row)
        }
        XCTAssertTrue(app.staticTexts["No highlights yet"].waitForExistence(timeout: 3))
        app.buttons["Close"].tap()

        let create = app.buttons["mymap.highlights-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertTrue(create.isHittable)
        let covers = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mymap.highlight."
        ))
        XCTAssertEqual(covers.count, 0, "Deleted highlights must not leave stale covers on the shelf")
        XCTAssertTrue(app.buttons["mymap.list-record.\(portraitReelID)"].exists)
        attachScreenshot(app, name: "MyMap — empty Highlights shelf")

        create.tap()
        let naming = app.alerts["New highlight"]
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        naming.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Untitled Highlight"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No memories yet"].exists)
        XCTAssertTrue(app.buttons["Add memories"].exists)
        returnToHighlights(app)
        let rows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mymap.collection-folder."
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.firstMatch.label, "Open Untitled Highlight")
        XCTAssertEqual(rows.firstMatch.value as? String, "0 memories, Only you")
        app.buttons["Close"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers.firstMatch.label, "Open Untitled Highlight")
    }

    @MainActor
    func testShelfScrollsAwayAndStaysOutOfSearchFiltersAndSelection() {
        let app = launchMyMap()
        let cover = app.buttons["mymap.highlight.\(afterDarkID)"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertTrue(cover.isHittable)
        let search = app.textFields["Search memories"]

        // Scroll the memory list, not the horizontal shelf. Search remains fixed;
        // Highlights must leave the viewport with the records instead of overlaying them.
        app.swipeUp()
        app.swipeUp()
        let offscreen = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: cover)
        wait(for: [offscreen], timeout: 3)
        XCTAssertTrue(search.isHittable)
        for _ in 0..<4 where cover.isHittable == false {
            app.swipeDown()
        }
        XCTAssertTrue(cover.isHittable)

        replaceText(in: search, with: "Kyoto")
        assertGone(app.buttons["mymap.highlights-new"])
        XCTAssertFalse(cover.exists)
        XCTAssertTrue(app.buttons["mymap.list-record.\(portraitReelID)"].exists)
        replaceText(in: search, with: "")
        XCTAssertTrue(cover.waitForExistence(timeout: 3))
        search.typeText("\n")

        app.buttons["mymap.select-memories"].tap()
        XCTAssertTrue(app.navigationBars["Select memories"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mymap.highlights-new"].exists)
        XCTAssertFalse(cover.exists)
        app.buttons["mymap.cancel-selection"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 3))

        app.buttons["Filter records"].tap()
        let poi = app.buttons["POI"]
        XCTAssertTrue(poi.waitForExistence(timeout: 3))
        poi.tap()
        let apply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show ")).firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        apply.tap()
        assertGone(app.buttons["mymap.highlights-new"])
        XCTAssertFalse(cover.exists)
        let clear = app.buttons["Clear POI filter"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 3))
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
        let app = launchMyMap()
        let entry = app.buttons["mymap.collections-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "See all highlights")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Highlights"].waitForExistence(timeout: 3))
        return app
    }

    @MainActor
    private func launchMyMap() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let tab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.buttons["mymap.highlights-new"].waitForExistence(timeout: 5))
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

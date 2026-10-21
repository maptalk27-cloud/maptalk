import XCTest

/// Composer-only regressions. Demo mode never signs into, uploads to, or
/// publishes against the hosted backend. These tests do not need library
/// fixtures; they exercise presentation, cancellation and keyboard layout.
final class PublishComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlaceEntryKeepsCaptureAndLibraryExplicit() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)

        let capture = app.buttons["Take a photo or video"]
        let library = app.buttons["Choose from library"]
        let cancel = app.buttons["Cancel publishing"]
        waitUntilHittable(capture)
        XCTAssertTrue(library.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(app.buttons["Cancel"].exists,
                       "Opening Place must not immediately present the system library or camera")
        XCTAssertFalse(app.navigationBars["Photos"].exists)

        // A person can choose the destination without first dismissing an
        // unrelated camera or permission screen.
        openPlaceChoices(in: app)
        let back = app.buttons["Back to place"]
        waitUntilHittable(back)
        back.tap()
        waitUntilHittable(capture)
        XCTAssertTrue(library.isHittable)
        cancel.tap()
        waitUntilHittable(app.buttons["Add a place"])
    }

    @MainActor
    func testNewPlaceNameAndConfirmationStayAboveKeyboardAndBackKeepsDraft() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        openNewPlace(in: app)

        let name = app.textFields["maptalk.place.new-name"]
        waitUntilHittable(name)
        name.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "Run this keyboard regression with the Simulator software keyboard enabled")
        let draft = "Cafe by the lake - north entrance"
        name.typeText(draft)

        let usePlace = app.buttons["Use this place"]
        waitUntilHittable(usePlace)
        assertNameEditorVisible(name, confirmation: usePlace, keyboard: keyboard, in: app)
        XCTAssertEqual(name.value as? String, draft)
        attachScreenshot(app, name: "Custom place name remains visible above keyboard")

        app.buttons["Back to nearby places"].tap()
        waitUntilHittable(app.buttons["Back to place"])
        revealAndTapCreatePlace(in: app)
        waitUntilHittable(name)
        XCTAssertEqual(name.value as? String, draft,
                       "Going back to nearby places must not silently erase the unconfirmed name")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        assertNameEditorVisible(name, confirmation: usePlace, keyboard: keyboard, in: app)
        usePlace.tap()

        let landmark = app.buttons["maptalk.place.choose-landmark"]
        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, draft)
        waitUntilGone(app.staticTexts["New place"])
        waitUntilGone(keyboard)
        XCTAssertTrue(app.buttons["Take a photo or video"].isHittable)
    }

    @MainActor
    func testCancellingPlaceLibraryPreservesCustomPlaceAndDoesNotRequireMedia() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        openNewPlace(in: app)
        let name = app.textFields["maptalk.place.new-name"]
        waitUntilHittable(name)
        name.tap()
        name.typeText("Quiet garden corner")
        app.buttons["Use this place"].tap()

        let landmark = app.buttons["maptalk.place.choose-landmark"]
        waitUntilHittable(landmark)
        let library = app.buttons["Choose from library"]
        waitUntilHittable(library)
        library.tap()
        cancelSystemLibrary(in: app)

        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, "Quiet garden corner")
        XCTAssertTrue(app.buttons["Take a photo or video"].isHittable)
        XCTAssertTrue(library.isHittable)
        XCTAssertTrue(app.buttons["Add to MyMap"].isEnabled,
                      "A selected place can still be checked in without a photo or video")
        XCTAssertFalse(app.buttons["Retake"].exists,
                       "Cancelling the library must not leave a phantom imported attachment")
    }

    @MainActor
    func testReelOffersPhotosAndVideosAndLibraryCancelKeepsCaption() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let entry = app.buttons["Share a reel"]
        waitUntilHittable(entry)
        entry.tap()

        let caption = app.textViews["maptalk.reel.text"]
        waitUntilHittable(caption)
        caption.tap()
        let draft = "An evening walk worth keeping"
        caption.typeText(draft)

        // Assert the offered capability without depending on the user's
        // library contents or a particular Photos grid layout.
        let addMedia = app.buttons["maptalk.reel.add-media"]
        waitUntilHittable(addMedia)
        XCTAssertEqual(addMedia.label, "Add photos or videos")
        addMedia.tap()
        cancelSystemLibrary(in: app)

        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.value as? String, draft)
        XCTAssertTrue(addMedia.exists)
        XCTAssertTrue(app.buttons["Share"].isEnabled)
        let mediaItems = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "maptalk.reel.media-item.")
        )
        XCTAssertEqual(mediaItems.count, 0,
                       "Cancelling must not append a placeholder or leave an import pending")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        // Keep system picker labels deterministic without changing the
        // Simulator's language or any personal account configuration.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func openPlace(in app: XCUIApplication) {
        let entry = app.buttons["Add a place"]
        waitUntilHittable(entry)
        entry.tap()
        waitUntilHittable(app.buttons["Take a photo or video"])
    }

    @MainActor
    private func openPlaceChoices(in app: XCUIApplication) {
        let landmark = app.buttons["maptalk.place.choose-landmark"]
        waitUntilHittable(landmark)
        landmark.tap()
        XCTAssertTrue(app.staticTexts["Choose a place"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openNewPlace(in app: XCUIApplication) {
        openPlaceChoices(in: app)
        revealAndTapCreatePlace(in: app)
    }

    @MainActor
    private func revealAndTapCreatePlace(in app: XCUIApplication) {
        let create = app.buttons["maptalk.place.create-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        // Nearby results can vary with the existing simulated location. Only
        // scroll the visible picker and stop as soon as its final row is shown.
        for _ in 0..<5 where !create.isHittable {
            let visibleScroll = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable }
            guard let visibleScroll else { break }
            visibleScroll.swipeUp()
        }
        waitUntilHittable(create)
        create.tap()
        XCTAssertTrue(app.staticTexts["New place"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func cancelSystemLibrary(in app: XCUIApplication) {
        // PhotosPicker uses Cancel on some iOS versions and Close on others.
        // Both are distinct from our own "Cancel publishing" action.
        let controls = [app.buttons["Cancel"], app.buttons["Close"]]
        let available = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in controls.contains { $0.exists && $0.isHittable } },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 8), .completed,
                       "An explicitly opened system library should offer cancellation")
        guard let cancel = controls.first(where: { $0.exists && $0.isHittable }) else { return }
        cancel.tap()
        waitUntilGone(cancel)
    }

    @MainActor
    private func assertNameEditorVisible(
        _ name: XCUIElement,
        confirmation: XCUIElement,
        keyboard: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let header = app.staticTexts["New place"]
        XCTAssertTrue(name.isHittable, file: file, line: line)
        XCTAssertTrue(confirmation.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(name.frame.minY, header.frame.maxY,
                                    "Typing must not push the name behind the header", file: file, line: line)
        XCTAssertLessThanOrEqual(name.frame.maxY, keyboard.frame.minY,
                                 "The whole name field must remain above the keyboard", file: file, line: line)
        XCTAssertLessThanOrEqual(confirmation.frame.maxY, keyboard.frame.minY + 1,
                                 "Confirmation must remain visible without dismissing the keyboard",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(name.frame.minX, app.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(name.frame.maxX, app.frame.maxX, file: file, line: line)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected a visible, tappable control: \(element.identifier)")
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

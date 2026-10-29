import XCTest

/// Composer-only regressions. Demo mode never signs into, uploads to, or
/// publishes against the hosted backend. These tests do not need library
/// fixtures except for the explicitly named photo regressions; they exercise
/// presentation, cancellation and keyboard layout.
final class PublishComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlaceEntryKeepsCaptureAndLibraryExplicit() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)

        let capture = app.buttons["maptalk.place.add-media"]
        let library = app.buttons["Choose from library"]
        let cancel = app.buttons["Cancel publishing"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["maptalk.place.camera-photo"].exists)
        XCTAssertFalse(app.buttons["maptalk.place.camera-video"].exists,
                       "One shutter must offer tap-to-photo and hold-to-video without a mode switch")
        XCTAssertTrue(library.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(app.buttons["Cancel"].exists,
                       "Opening Place must not immediately present the system library or camera")
        XCTAssertFalse(app.navigationBars["Photos"].exists)

        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Embedded POI camera stays inside the publishing panel"
        preview.lifetime = .keepAlways
        add(preview)

        // A person can choose the destination without first dismissing an
        // unrelated camera or permission screen.
        openPlaceChoices(in: app)
        let back = app.buttons["Back to place"]
        waitUntilHittable(back)
        back.tap()
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        XCTAssertTrue(app.buttons["Choose from library"].isHittable)
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
        waitUntilGone(app.keyboards.firstMatch)
        let library = app.buttons["Choose from library"]
        waitUntilHittable(library)
        library.tap()
        cancelSystemLibrary(in: app)

        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, "Quiet garden corner")
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
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
    func testPlacePhotoTextCanBeEditedCancelledAndCleared() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        XCTAssertFalse(app.buttons["maptalk.place.photo-text"].exists)
        importFirstPhoto(in: app)
        let edit = app.buttons["maptalk.place.photo-text"]
        waitUntilHittable(edit)
        edit.tap()
        let input = app.textViews["maptalk.photo-text.input"]
        waitUntilHittable(input)
        input.tap()
        input.typeText("A quiet morning")
        let done = app.buttons["maptalk.photo-text.done"]
        waitUntilHittable(done)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY,
                          "Photo words must remain visible while typing")
        let canvas = app.descendants(matching: .any).matching(identifier: "maptalk.photo-text.canvas").firstMatch
        XCTAssertTrue(canvas.exists)
        XCTAssertLessThanOrEqual(canvas.frame.height, 327,
                                 "Inline editing must keep the composer's compact photo stage")
        attachScreenshot(app, name: "POI photo text editor above keyboard")
        done.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            edit.exists && edit.value as? String == "A quiet morning"
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        attachScreenshot(app, name: "Words rendered into POI photo preview")
        edit.tap()
        waitUntilHittable(input)
        XCTAssertEqual(input.value as? String, "A quiet morning")
        input.tap()
        input.typeText(" changed")
        app.buttons["maptalk.photo-text.cancel"].tap()
        waitUntilHittable(edit)
        XCTAssertEqual(edit.value as? String, "A quiet morning")
        edit.tap()
        app.buttons["maptalk.photo-text.clear"].tap()
        done.tap()
        waitUntilHittable(edit)
        XCTAssertEqual(edit.value as? String, "")
        app.buttons["maptalk.place.retake"].tap()
        XCTAssertFalse(edit.exists)
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        let cancelRetake = app.buttons["maptalk.place.cancel-retake"]
        waitUntilHittable(cancelRetake)
        cancelRetake.tap()
        waitUntilHittable(edit)
        XCTAssertEqual(edit.value as? String, "",
                       "Cancelling a retake must return the existing photo, not an empty composer")
    }

    @MainActor
    func testPlacePhotoRetakeLibraryCancelAndClosePreserveWordsUntilDiscard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        importFirstPhoto(in: app)
        let edit = app.buttons["maptalk.place.photo-text"]
        waitUntilHittable(edit)
        edit.tap()
        let input = app.textViews["maptalk.photo-text.input"]
        waitUntilHittable(input)
        input.tap()
        input.typeText("Keep this memory")
        app.buttons["maptalk.photo-text.done"].tap()
        waitForPhotoWords("Keep this memory", in: app)

        app.buttons["maptalk.place.retake"].tap()
        let cancelRetake = app.buttons["maptalk.place.cancel-retake"]
        waitUntilHittable(cancelRetake)
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        cancelRetake.tap()
        waitForPhotoWords("Keep this memory", in: app)
        attachScreenshot(app, name: "Cancelled retake restores the photo and its words")

        app.buttons["Choose from library"].tap()
        cancelSystemLibrary(in: app)
        waitForPhotoWords("Keep this memory", in: app)

        app.buttons["maptalk.publish.cancel"].tap()
        let keep = app.buttons["Keep editing"]
        waitUntilHittable(keep)
        XCTAssertTrue(app.buttons["Discard"].exists)
        keep.tap()
        waitForPhotoWords("Keep this memory", in: app)
        app.buttons["maptalk.publish.cancel"].tap()
        waitUntilHittable(app.buttons["Discard"])
        app.buttons["Discard"].tap()
        waitUntilHittable(app.buttons["Add a place"])
        openPlace(in: app)
        XCTAssertFalse(edit.exists)
        XCTAssertFalse(app.buttons["maptalk.place.retake"].exists)
    }

    @MainActor
    func testPlaceHotelAndAirportCategoriesAndManualDraftCloseProtection() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        openNewPlace(in: app)
        let name = app.textFields["maptalk.place.new-name"]
        waitUntilHittable(name)
        name.tap()
        name.typeText("A hotel worth remembering")

        let hotel = app.buttons["maptalk.place.new-category.hotel"]
        let airport = app.buttons["maptalk.place.new-category.airport"]
        revealCategory(hotel, in: app)
        hotel.tap()
        XCTAssertEqual(hotel.value as? String, "Selected")
        revealCategory(airport, in: app)
        airport.tap()
        XCTAssertEqual(airport.value as? String, "Selected")
        XCTAssertNotEqual(hotel.value as? String, "Selected")
        hotel.tap()
        attachScreenshot(app, name: "Hotel and airport use dedicated selectable place types")
        app.buttons["Use this place"].tap()
        let landmark = app.buttons["maptalk.place.choose-landmark"]
        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, "A hotel worth remembering")

        app.buttons["maptalk.publish.cancel"].tap()
        waitUntilHittable(app.buttons["Keep editing"])
        app.buttons["Keep editing"].tap()
        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, "A hotel worth remembering")
        openNewPlace(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        revealCategory(hotel, in: app)
        XCTAssertEqual(hotel.value as? String, "Selected",
                       "Keeping the draft must preserve both its name and its chosen type")
    }

    @MainActor
    func testPlaceAudienceChoicesAreVisibleAndSwitchWithoutOpeningAnotherMenu() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        let publicChoice = app.buttons["maptalk.place.audience.public"]
        let privateChoice = app.buttons["maptalk.place.audience.private"]
        waitUntilHittable(publicChoice)
        waitUntilHittable(privateChoice)
        XCTAssertEqual(privateChoice.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Add to MyMap"].exists)
        publicChoice.tap()
        XCTAssertEqual(publicChoice.value as? String, "Selected")
        XCTAssertNotEqual(privateChoice.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Post"].exists)
        XCTAssertTrue(privateChoice.isHittable,
                      "Both audience choices must remain visible after a selection")
        privateChoice.tap()
        XCTAssertEqual(privateChoice.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Add to MyMap"].exists)
        attachScreenshot(app, name: "POI audience is one directly tappable choice")
    }

    @MainActor
    func testReelCanAttachAClusterWithoutAddingAnotherPhotoOrCaption() throws {
        let app = launchDemo()
        defer { app.terminate() }
        waitUntilHittable(app.buttons["Share a reel"])
        app.buttons["Share a reel"].tap()
        let choose = app.buttons["maptalk.reel.choose-bubble"]
        waitUntilHittable(choose)
        XCTAssertFalse(app.buttons["maptalk.reel.publish"].isEnabled)
        choose.tap()
        let memory = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "maptalk.reel.bubble-memory."
        )).firstMatch
        waitUntilHittable(memory)
        memory.tap()
        app.buttons["Done"].tap()
        waitUntilHittable(choose)
        XCTAssertTrue(app.buttons["maptalk.reel.publish"].isEnabled,
                      "The selected cluster is content; another caption or photo is optional")
        XCTAssertTrue(app.descendants(matching: .any)["maptalk.reel.bubble-preview"].exists)
        attachScreenshot(app, name: "Existing Reel composer with attached cluster")

        choose.tap()
        app.buttons["Remove bubble selection"].tap()
        app.buttons["Back to reel"].tap()
        XCTAssertTrue(app.buttons["maptalk.reel.publish"].isEnabled,
                      "Cancelling the picker must preserve the previously selected cluster")
        choose.tap()
        app.buttons["Remove bubble selection"].tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["maptalk.reel.publish"].isEnabled)
    }

    @MainActor
    func testNearbyPlaceSearchStaysInPickerAndPreservesCaptureDraft() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        openPlaceChoices(in: app)
        let search = app.textFields["maptalk.place.search"]
        waitUntilHittable(search)
        search.tap()
        search.typeText("Airport")
        XCTAssertEqual(search.value as? String, "Airport")
        XCTAssertTrue(app.staticTexts["Choose a place"].exists)
        XCTAssertFalse(app.staticTexts["New place"].exists)
        XCTAssertFalse(app.navigationBars["Photos"].exists)
        attachScreenshot(app, name: "POI search stays in the existing place picker")
        let clear = app.buttons["Clear place search"]
        waitUntilHittable(clear)
        clear.tap()
        XCTAssertEqual(search.value as? String, "Search nearby places")
        app.buttons["Back to place"].tap()
        waitUntilHittable(app.buttons["maptalk.place.add-media"])
        waitUntilGone(app.keyboards.firstMatch)
        XCTAssertTrue(app.buttons["Choose from library"].isHittable)
        XCTAssertFalse(app.staticTexts["New place"].exists)
    }

    @MainActor
    func testCreatePlaceRemainsReachableWhileSearchingWithKeyboard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openPlace(in: app)
        openPlaceChoices(in: app)
        let search = app.textFields["maptalk.place.search"]
        waitUntilHittable(search)
        search.tap()
        search.typeText("A quiet place that is not listed")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let create = app.buttons["maptalk.place.create-new"]
        waitUntilHittable(create)
        XCTAssertLessThanOrEqual(create.frame.maxY, keyboard.frame.minY + 1,
                                 "Creating a missing place stays reachable above the keyboard without scrolling")
        attachScreenshot(app, name: "Place search keeps creation visible above keyboard")
        create.tap()
        let name = app.textFields["maptalk.place.new-name"]
        waitUntilHittable(name)
        name.tap()
        name.typeText("A quiet garden")
        let confirm = app.buttons["Use this place"]
        waitUntilHittable(confirm)
        confirm.tap()
        let landmark = app.buttons["maptalk.place.choose-landmark"]
        waitUntilHittable(landmark)
        XCTAssertEqual(landmark.value as? String, "A quiet garden")
        waitUntilGone(keyboard)
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
        waitUntilHittable(app.buttons["Choose from library"])
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        XCTAssertTrue(app.buttons["maptalk.place.flip-camera"].exists)
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
    private func importFirstPhoto(in app: XCUIApplication) {
        app.buttons["Choose from library"].tap()
        let photo = app.images.matching(NSPredicate(
            format: "label CONTAINS[c] 'Photo' AND NOT label CONTAINS[c] 'Video'"
        )).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The existing simulator needs a photo fixture")
        let frame = photo.frame
        XCTAssertTrue(app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        waitUntilHittable(app.buttons["maptalk.place.photo-text"], timeout: 20)
    }

    @MainActor
    private func waitForPhotoWords(_ words: String, in app: XCUIApplication) {
        let edit = app.buttons["maptalk.place.photo-text"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            edit.exists && edit.isHittable && edit.value as? String == words
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }

    @MainActor
    private func revealCategory(_ category: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !category.isHittable {
            guard let scroll = app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }) else { break }
            scroll.swipeUp()
        }
        waitUntilHittable(category)
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
        // The first cold PhotosPicker launch exposes its remote AX tree while
        // the visible sheet still says Loading. At that point its Cancel frame
        // is service-local (y=14), and asking isHittable can throw rather than
        // return false. Wait for a stable, screen-positioned navigation bar
        // before testing hittability. This still taps the real system control.
        let navigationBar = app.navigationBars["Photos"]
        let cancel = navigationBar.buttons.matching(
            NSPredicate(format: "label IN %@", ["Cancel", "Close"])
        ).firstMatch
        var lastNavigationFrame = CGRect.null
        var lastCancelFrame = CGRect.null
        let laidOut = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard navigationBar.exists, cancel.exists else { return false }
                let navigationFrame = navigationBar.frame
                let cancelFrame = cancel.frame
                // In this portrait iPhone sheet the real bar is below the
                // status area, not at the remote service's zero-based origin.
                guard cancelFrame.height > 0,
                      navigationFrame.minY >= cancelFrame.height,
                      navigationFrame.contains(cancelFrame) else { return false }
                defer {
                    lastNavigationFrame = navigationFrame
                    lastCancelFrame = cancelFrame
                }
                return navigationFrame == lastNavigationFrame && cancelFrame == lastCancelFrame
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [laidOut], timeout: 15), .completed,
                       "The system library must finish positioning its navigation controls")
        // Scope to navigation: the Photos privacy notice also has a Close
        // button, but dismissing that notice would not cancel the library.
        waitUntilHittable(cancel)
        cancel.tap()
        waitUntilGone(navigationBar)
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

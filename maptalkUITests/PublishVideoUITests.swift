import XCTest

/// Opt-in real PhotosPicker coverage. Seed a short MP4 and still photo into
/// the existing simulator with simctl addmedia; never access a physical phone.
final class PublishVideoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testReelMixedMediaCanPreviewVideoWithoutLosingDraftOrDragGesture() throws {
        let app = try launchDemo()
        defer { app.terminate() }
        let entry = app.buttons["Share a reel"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        app.buttons["maptalk.reel.add-media"].tap()
        try chooseVideo(in: app)
        let photo = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo' AND NOT label CONTAINS[c] 'Video'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        tapLibraryThumbnail(photo, in: app)
        let add = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Add' OR label BEGINSWITH 'Add ('")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let video = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == 'Video'", "maptalk.reel.media-item."
        )).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        let still = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == 'Photo'", "maptalk.reel.media-item."
        )).firstMatch
        XCTAssertTrue(still.exists)
        video.tap()
        let done = app.buttons["maptalk.reel.video-preview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        attach(app, "Reel video plays in preview")
        done.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        XCTAssertTrue(still.exists)

        // A hold/release must remain a drag gesture, not open video preview.
        video.press(forDuration: 0.5)
        XCTAssertFalse(done.exists)
        XCTAssertTrue(video.exists)
        XCTAssertTrue(app.buttons["Share"].isEnabled)
        attach(app, "Mixed Reel grid retained after video preview and hold")
    }

    @MainActor
    func testPlaceVideoLibraryImportShowsPlayablePreviewAndRetake() throws {
        let app = try launchDemo()
        defer { app.terminate() }
        let entry = app.buttons["Add a place"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        app.buttons["Choose from library"].tap()
        try chooseVideo(in: app)
        let retake = app.buttons["maptalk.place.retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists)
        XCTAssertTrue(app.buttons["maptalk.place.choose-landmark"].exists)
        XCTAssertTrue(app.buttons["Choose from library"].exists)
        attach(app, "POI imported video preview")

        retake.tap()
        let cancelRetake = app.buttons["maptalk.place.cancel-retake"]
        waitUntilHittable(cancelRetake)
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        cancelRetake.tap()
        waitUntilHittable(retake)
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists,
                      "A cancelled camera retake must restore the imported video")
        XCTAssertFalse(app.buttons["maptalk.place.photo-text"].exists,
                       "Returning from retake must not turn video into a still-photo draft")
        attach(app, "POI video restored after cancelling a retake")

        app.buttons["maptalk.publish.cancel"].tap()
        waitUntilHittable(app.buttons["Keep editing"])
        app.buttons["Keep editing"].tap()
        waitUntilHittable(retake)
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists,
                      "Keeping the post must preserve the playable video")
    }

    @MainActor
    func testPlaceLongVideoCanCancelClipThenPrepareSelectedMinute() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAPTALK_LONG_VIDEO_TESTS"] == "1",
                          "Requires the generated 65-second video to be the newest simulator library item")
        let app = try launchDemo()
        defer { app.terminate() }
        let entry = app.buttons["Add a place"]
        waitUntilHittable(entry)
        entry.tap()
        let library = app.buttons["Choose from library"]
        waitUntilHittable(library)
        library.tap()
        try chooseVideo(in: app)

        let editor = app.descendants(matching: .any).matching(identifier: "maptalk.place.clip-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30),
                      "Long videos must reach clip selection rather than disappearing or being rejected")
        let slider = app.sliders["maptalk.place.clip.start"]
        waitUntilHittable(slider)
        let cancel = app.buttons["maptalk.place.clip.cancel"]
        waitUntilHittable(cancel)
        attach(app, "Long POI video offers a one-minute clip before importing")
        cancel.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(library.isEnabled)
        attach(app, "Cancelled clip returns to camera controls")
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        XCTAssertFalse(app.buttons["maptalk.place.retake"].exists,
                       "Cancelling the clip must not silently attach the untrimmed video")

        let libraryFrame = library.frame
        // After the clip overlay closes, iOS 26 can report this visible button
        // as non-hittable. Exercise its actual touch target and require Photos
        // to reopen and a second import to finish, rather than trusting AX alone.
        XCTAssertGreaterThanOrEqual(libraryFrame.width, 44)
        XCTAssertTrue(app.frame.contains(CGPoint(x: libraryFrame.midX, y: libraryFrame.midY)))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: libraryFrame.midX, dy: libraryFrame.midY)).tap()
        try chooseVideo(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        waitUntilHittable(slider)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let use = app.buttons["maptalk.place.clip.use"]
        waitUntilHittable(use)
        use.tap()
        let retake = app.buttons["maptalk.place.retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 60),
                      "A selected minute must finish importing as ordinary POI media")
        waitUntilHittable(retake)
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["maptalk.place.import.issue"].exists)
        attach(app, "Selected minute is ready in the normal POI video preview")
    }

    @MainActor
    private func chooseVideo(in app: XCUIApplication) throws {
        let video = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Video'")).firstMatch
        if !video.waitForExistence(timeout: 3) { print(app.debugDescription) }
        XCTAssertTrue(video.waitForExistence(timeout: 10), "Seed a short video into this simulator's Photos library first")
        tapLibraryThumbnail(video, in: app)
    }

    @MainActor
    private func tapLibraryThumbnail(_ item: XCUIElement, in app: XCUIApplication) {
        // iOS 26 Photos runs out of process; its otherwise-visible grid images
        // can report an invalid accessibility hit point (-1, -1).
        let frame = item.frame
        XCTAssertTrue(app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertGreaterThan(frame.width, 80)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    @MainActor
    private func launchDemo() throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAPTALK_SEEDED_MEDIA_TESTS"] == "1",
                          "Requires generated photo/video fixtures in the existing simulator library")
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected a visible, tappable control: \(element.identifier)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

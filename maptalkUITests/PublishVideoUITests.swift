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
    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

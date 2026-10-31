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
        let landmark = app.buttons["maptalk.place.choose-landmark"]
        XCTAssertTrue(landmark.exists)
        XCTAssertTrue(app.buttons["Choose from library"].exists)
        let stage = app.descendants(matching: .any).matching(identifier: "maptalk.place.media-stage").firstMatch
        XCTAssertTrue(stage.exists)
        let previewFrame = stage.frame
        let playback = app.buttons["maptalk.place.video.playback"]
        let sound = app.buttons["maptalk.place.video.sound"]
        waitUntilHittable(playback)
        waitForPlayback("Paused", control: playback)
        playback.tap()
        waitForPlayback("Playing", control: playback)
        playback.tap()
        waitForPlayback("Paused", control: playback)
        waitUntilHittable(sound)
        playback.tap()
        waitForPlayback("Playing", control: playback)
        XCTAssertEqual(sound.label, "Mute video")
        sound.tap()
        XCTAssertEqual(sound.label, "Unmute video")
        sound.tap()
        XCTAssertEqual(sound.label, "Mute video")
        waitForFrame(stage, matching: previewFrame)
        XCTAssertTrue(retake.isHittable,
                      "Review controls must stay in the composer, not launch a full-screen video player")

        waitForPlayback("Playing", control: playback)
        landmark.tap()
        let back = app.buttons["Back to place"]
        waitUntilHittable(back)
        back.tap()
        waitUntilHittable(playback)
        waitForPlayback("Paused", control: playback)
        waitForFrame(stage, matching: previewFrame)
        XCTAssertTrue(app.buttons["maptalk.publish.cancel"].isHittable)
        XCTAssertTrue(landmark.isHittable)
        XCTAssertEqual(sound.label, "Mute video",
                       "Returning from place selection must preserve sound preference without resuming playback")
        attach(app, "POI imported video preview")

        retake.tap()
        let cancelRetake = app.buttons["maptalk.place.cancel-retake"]
        waitUntilHittable(cancelRetake)
        XCTAssertTrue(app.buttons["maptalk.place.add-media"].exists)
        cancelRetake.tap()
        waitUntilHittable(retake)
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists,
                      "A cancelled camera retake must restore the imported video")
        XCTAssertTrue(app.buttons["maptalk.place.photo-text"].exists)
        XCTAssertEqual(app.buttons["maptalk.place.photo-text"].label, "Add text to video",
                       "Returning from retake must preserve a video draft with its text tool")
        attach(app, "POI video restored after cancelling a retake")

        waitUntilHittable(playback)
        playback.tap()
        waitForPlayback("Playing", control: playback)
        app.buttons["maptalk.publish.cancel"].tap()
        waitUntilHittable(app.buttons["Keep editing"])
        waitForPlayback("Paused", control: playback)
        app.buttons["Keep editing"].tap()
        waitUntilHittable(retake)
        waitForPlayback("Paused", control: playback)
        XCTAssertTrue(app.descendants(matching: .any)["Video preview"].exists,
                      "Keeping the post must preserve the playable video")
    }

    @MainActor
    func testPlaceVideoWordsCanBeConfirmedCancelledRemovedAndReplaced() throws {
        let app = try launchDemo()
        defer { app.terminate() }
        waitUntilHittable(app.buttons["Add a place"])
        app.buttons["Add a place"].tap()
        app.buttons["Choose from library"].tap()
        try chooseVideo(in: app)
        let edit = app.buttons["maptalk.place.photo-text"]
        waitUntilHittable(edit, timeout: 30)
        XCTAssertEqual(edit.label, "Add text to video")
        selectCustomPlace("Video text check-in", in: app)

        edit.tap()
        let input = app.textViews["maptalk.photo-text.input"]
        let done = app.buttons["maptalk.photo-text.done"]
        waitUntilHittable(input)
        input.tap()
        let words = "Water and light"
        input.typeText(words)
        waitUntilHittable(done)
        XCTAssertEqual(app.buttons.matching(identifier: "maptalk.photo-text.done").count, 1)
        XCTAssertFalse(app.buttons["maptalk.photo-text.clear"].exists)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1)
        attach(app, "POI video uses the same inline words editor")
        done.tap()
        waitForVideoWords(words, in: app)

        let playback = app.buttons["maptalk.place.video.playback"]
        let sound = app.buttons["maptalk.place.video.sound"]
        playback.tap()
        waitForPlayback("Playing", control: playback)
        XCTAssertEqual(sound.label, "Mute video",
                       "The rendered video must retain its sound control")
        playback.tap()
        waitForPlayback("Paused", control: playback)
        XCTAssertTrue(app.buttons["maptalk.place.publish"].isEnabled,
                      "A ready video with words and a selected place must remain a publishable draft")
        attach(app, "Video with confirmed words remains playable and publishable")

        edit.tap()
        waitUntilHittable(input)
        XCTAssertEqual(input.value as? String, words)
        input.typeText(" changed")
        app.buttons["maptalk.photo-text.cancel"].tap()
        waitForVideoWords(words, in: app)
        app.buttons["maptalk.place.retake"].tap()
        let cancelRetake = app.buttons["maptalk.place.cancel-retake"]
        waitUntilHittable(cancelRetake)
        cancelRetake.tap()
        waitForVideoWords(words, in: app)

        edit.tap()
        waitUntilHittable(input)
        let savedWords = try XCTUnwrap(input.value as? String)
        XCTAssertEqual(savedWords, words)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: savedWords.count))
        XCTAssertEqual(input.value as? String, "")
        done.tap()
        waitForVideoWords("", in: app)
        playback.tap()
        waitForPlayback("Playing", control: playback)
        playback.tap()
        waitForPlayback("Paused", control: playback)
        XCTAssertEqual(sound.label, "Mute video")

        edit.tap()
        waitUntilHittable(input)
        input.typeText("Keep these words")
        done.tap()
        waitForVideoWords("Keep these words", in: app)
        app.buttons["Choose from library"].tap()
        let photo = app.images.matching(NSPredicate(
            format: "label CONTAINS[c] 'Photo' AND NOT label CONTAINS[c] 'Video'"
        )).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        tapLibraryThumbnail(photo, in: app)
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            edit.exists && edit.isHittable && edit.label == "Add text to photo"
                && edit.value as? String == "" && !playback.exists
        }, object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 30), .completed,
                       "Replacing the video must not carry its old words into another attachment")
        XCTAssertTrue(app.buttons["maptalk.place.publish"].isEnabled)
        attach(app, "Replacing a captioned POI video clears words only, not the place draft")
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
        let stage = app.descendants(matching: .any).matching(identifier: "maptalk.place.media-stage").firstMatch
        XCTAssertTrue(stage.exists)
        let captureFrame = stage.frame
        library.tap()
        try chooseVideo(in: app)

        let editor = app.descendants(matching: .any).matching(identifier: "maptalk.place.clip-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30),
                      "Long videos must reach clip selection rather than disappearing or being rejected")
        let clipStart = app.descendants(matching: .any).matching(identifier: "maptalk.place.clip.start").firstMatch
        let timeline = app.descendants(matching: .any).matching(identifier: "maptalk.place.clip.timeline").firstMatch
        waitUntilHittable(clipStart)
        XCTAssertTrue(timeline.exists)
        assertSameStageOrigin(stage, as: captureFrame)
        XCTAssertGreaterThanOrEqual(timeline.frame.height, 44,
                                     "The visual timeline must be comfortably draggable")
        let cancel = app.buttons["maptalk.place.clip.cancel"]
        waitUntilHittable(cancel)
        attach(app, "Long POI video offers a one-minute clip before importing")
        cancel.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(library.isEnabled)
        attach(app, "Cancelled clip returns to camera controls")
        XCTAssertFalse(editor.exists)
        waitForFrame(stage, matching: captureFrame)
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
        waitUntilHittable(clipStart)
        assertSameStageOrigin(stage, as: captureFrame)
        let originalStart = try XCTUnwrap(clipStart.value as? String,
                                          "The selected clip start must be exposed to accessibility")
        XCTAssertFalse(originalStart.isEmpty)
        let timelineFrame = timeline.frame
        XCTAssertGreaterThan(timelineFrame.width, 80)
        XCTAssertTrue(app.frame.contains(timelineFrame))
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: timelineFrame.midX, dy: timelineFrame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: timelineFrame.midX + 20,
                                 dy: timelineFrame.midY))
        start.press(forDuration: 0.1, thenDragTo: end)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard clipStart.exists, let value = clipStart.value as? String else { return false }
            return !value.isEmpty && value != originalStart
        }, object: clipStart)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "Dragging the visible frame strip must actually change the selected clip")
        attach(app, "Long POI video selects a later range using the visual timeline")
        let use = app.buttons["maptalk.place.clip.use"]
        waitUntilHittable(use)
        XCTAssertTrue(use.isEnabled, "The dragged selection must remain a valid clip")
        use.tap()
        let retake = app.buttons["maptalk.place.retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 60),
                      "A selected minute must finish importing as ordinary POI media")
        waitUntilHittable(retake)
        XCTAssertFalse(editor.exists)
        waitForFrame(stage, matching: captureFrame)
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
    private func selectCustomPlace(_ name: String, in app: XCUIApplication) {
        app.buttons["maptalk.place.choose-landmark"].tap()
        let create = app.buttons["maptalk.place.create-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        for _ in 0..<5 where !create.isHittable {
            app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable })?.swipeUp()
        }
        waitUntilHittable(create)
        create.tap()
        let field = app.textFields["maptalk.place.new-name"]
        waitUntilHittable(field)
        field.tap()
        field.typeText(name)
        app.buttons["Use this place"].tap()
        waitUntilHittable(app.buttons["maptalk.place.photo-text"])
        XCTAssertEqual(app.buttons["maptalk.place.choose-landmark"].value as? String, name)
    }

    @MainActor
    private func waitForVideoWords(_ words: String, in app: XCUIApplication) {
        let edit = app.buttons["maptalk.place.photo-text"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            edit.exists && edit.isHittable && edit.label == "Add text to video"
                && edit.value as? String == words
                && app.buttons["maptalk.place.video.playback"].exists
                && app.buttons["maptalk.place.publish"].isEnabled
        }, object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 90), .completed,
                       "Confirmed words must finish preparing as playable, publishable video")
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
    private func assertSameStageOrigin(_ stage: XCUIElement, as frame: CGRect) {
        XCTAssertTrue(stage.exists, "Clip tools must remain attached to the existing media canvas")
        XCTAssertEqual(stage.frame.minX, frame.minX, accuracy: 2)
        XCTAssertEqual(stage.frame.minY, frame.minY, accuracy: 2)
        XCTAssertEqual(stage.frame.width, frame.width, accuracy: 2)
        XCTAssertGreaterThan(stage.frame.height, 0)
    }

    @MainActor
    private func waitForPlayback(_ value: String, control: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.exists && control.value as? String == value
        }, object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected the embedded video preview to be \(value)")
    }

    @MainActor
    private func waitForFrame(_ element: XCUIElement, matching frame: CGRect) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists else { return false }
            let current = element.frame
            return abs(current.minX - frame.minX) <= 2
                && abs(current.minY - frame.minY) <= 2
                && abs(current.width - frame.width) <= 2
                && abs(current.height - frame.height) <= 2
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Leaving clip selection must restore the normal media frame")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

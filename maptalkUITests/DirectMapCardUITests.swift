import XCTest

/// The person rail is used only to locate existing demo pins. Every interaction
/// under test starts by tapping the actual main-map marker, not the story card.
/// No authentication, publishing, fixture reset or production test hooks.
final class DirectMapCardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompactReelPhotoOpensWithoutExpandingItsMapCard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openOwnStory(app)
        let reelID = "00000000-0000-0000-0000-000000009301"
        selectExistingPage("friend-story.page.reel:\(reelID)", preferredIndex: 13, app: app)
        waitForCamera(latitude: 21.2866, longitude: -157.8399, app: app)
        let marker = element("maptalk.marker.reel.\(reelID)", in: app)
        waitForHittable(marker, message: "The original Reel marker must be interactive")
        marker.tap()
        assertNoPersonRoute(app)
        waitForNativeDetent("Half screen", app: app)

        let photo = app.buttons["experience.real.photo.\(reelID).00000000-0000-0000-0000-000000009302"]
        waitForHittable(photo, message: "The compact photo must be directly interactive")
        let photoFrame = photo.frame
        evidence(app, name: "Compact Reel — before photo tap")
        photo.tap()
        let close = app.buttons["experience.media-lightbox.close"]
        waitForHittable(close, message: "A compact photo tap opens its viewer once")
        assertStaysVisible(close, seconds: 2, message: "The compact photo viewer must not dismiss and reopen")
        evidence(app, name: "Compact Reel — photo preview")
        close.tap()

        waitForNativeDetent("Half screen", app: app)
        waitForHittable(photo, message: "Closing the photo returns to the same compact card")
        XCTAssertEqual(photo.frame.minY, photoFrame.minY, accuracy: 4)
        XCTAssertEqual(photo.frame.height, photoFrame.height, accuracy: 4)
        assertStaysVisible(photo, seconds: 2, message: "Returning must not reopen or resize the card")
        assertNoPersonRoute(app)
        evidence(app, name: "Compact Reel — unchanged after closing preview")

        // A tap on the card's ordinary text still expands details, and dragging
        // the sheet remains the native alternative to that tap.
        let caption = element("experience.real.caption.\(reelID)", in: app)
        waitForHittable(caption, message: "The original caption must remain reachable")
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForNativeDetent("Expanded", app: app)
    }

    @MainActor
    func testDirectReelPinExitsPersonStoryAndPhotoReturnsToSameExpandedCard() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openOwnStory(app)
        let reelID = "00000000-0000-0000-0000-000000009301"
        selectExistingPage("friend-story.page.reel:\(reelID)", preferredIndex: 13, app: app)
        waitForCamera(latitude: 21.2866, longitude: -157.8399, app: app)

        let marker = element("maptalk.marker.reel.\(reelID)", in: app)
        waitForHittable(marker, message: "The actual Waikiki map pin must be tappable")
        XCTAssertEqual(marker.value as? String, "Avatar, selected")
        XCTAssertEqual(marker.label, "chengsi Reel", "The map marker must identify the Reel's author")
        marker.tap()
        assertNoPersonRoute(app)
        waitForNativeDetent("Half screen", app: app)
        evidence(app, name: "Direct map Reel — original compact card, no person route")

        expandNativeCard(app)
        let caption = app.staticTexts["experience.real.caption.\(reelID)"]
        let photo = app.buttons["experience.real.photo.\(reelID).00000000-0000-0000-0000-000000009302"]
        waitForHittable(photo, message: "The original expanded Reel photo must be interactive")
        XCTAssertEqual(caption.label, "Waikiki boardwalk glow before the night surf.")
        let captionY = caption.frame.minY
        assertNoPersonRoute(app)
        evidence(app, name: "Direct map Reel — original expanded card")

        photo.tap()
        let close = app.buttons["experience.media-lightbox.close"]
        waitForHittable(close, message: "One photo tap must open the original photo viewer")
        assertStaysVisible(close, seconds: 2,
                           message: "The photo viewer must not exit and reopen its parent automatically")
        assertNoPersonRoute(app)
        evidence(app, name: "Direct map Reel — photo viewer remains open")
        close.tap()

        waitForNativeDetent("Expanded", app: app)
        waitForHittable(photo, message: "Closing the photo must return to the same expanded Reel")
        XCTAssertFalse(close.exists)
        XCTAssertEqual(caption.label, "Waikiki boardwalk glow before the night surf.")
        XCTAssertEqual(caption.frame.minY, captionY, accuracy: 4,
                       "Returning from the viewer must not recreate or reposition the map card")
        XCTAssertEqual(app.staticTexts.matching(identifier: caption.identifier).count, 1)
        assertStaysVisible(photo, seconds: 2,
                           message: "The returned map card must stay mounted without a close/reopen cycle")
        assertNoPersonRoute(app)
        evidence(app, name: "Direct map Reel — same expanded card after photo close")
    }

    @MainActor
    func testDirectPOIPinRetainsHistoricalFootprintPlaybackAfterPersonStory() throws {
        let app = launchDemo()
        defer { app.terminate() }
        openOwnStory(app)
        // Existing visit 6006 has three own photos. The same shared place also
        // has four other visitors, including pulse006.wave's 32-hour-old photo.
        // This is deliberately not a fixture claiming expiry beyond 72 hours.
        let ownVisit = "friend-story.page.poi:00000000-0000-0000-0000-000000006006:"
        selectExistingPage(ownVisit, preferredIndex: 12, app: app, prefix: true)
        let selectedSlice = try XCTUnwrap(currentPage(app).identifier.split(separator: ":").last.map(String.init))
        waitForCamera(latitude: 45.638, longitude: -122.661, app: app)

        let marker = element("maptalk.marker.poi.BBBBBBBB-9999-AAAA-BBBB-CCCCCCCCCCCC", in: app)
        waitForHittable(marker, message: "The actual night-market category pin must be tappable")
        marker.tap()
        assertNoPersonRoute(app)
        waitForNativeDetent("Half screen", app: app)
        XCTAssertTrue(element("experience.poi.collapsed", in: app).exists)
        expandNativeCard(app)
        XCTAssertTrue(element("experience.poi.expanded", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Capitol Hill Night Market"].firstMatch.exists)

        let contributorIDs = [
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", // own three-photo visit
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE9", // shadow.collector
            "00000000-0000-0000-0000-000000008000", // pulse001.wave
            "00000000-0000-0000-0000-000000008005", // historical pulse006.wave
            "00000000-0000-0000-0000-000000008006", // location-only visitor
        ]
        let historical = app.buttons["experience.poi.footprint.\(contributorIDs[3])"]
        revealFootprint(historical, app: app)
        for id in contributorIDs {
            XCTAssertTrue(app.buttons["experience.poi.footprint.\(id)"].exists,
                          "Direct map POIs retain all contributors, not only the selected person's slice")
        }
        assertNoPersonRoute(app)
        evidence(app, name: "Direct map POI — original complete footprint grid")

        historical.tap()
        let close = app.buttons["experience.poi-story.close"]
        waitForHittable(close, message: "Historical footprint avatars must open the original POI viewer")
        XCTAssertTrue(app.staticTexts["pulse006.wave"].firstMatch.exists,
                      "The viewer must play the tapped historical contributor, not the previous own-story slice")
        let media = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "experience.poi-story.media."
        ))
        XCTAssertTrue(media.firstMatch.exists)
        XCTAssertNotEqual(media.firstMatch.identifier, "experience.poi-story.media.\(selectedSlice)",
                       "A direct place history viewer must not inherit the previously selected personal media")
        // The original viewer automatically advances after its photo duration.
        // Inspect and close it promptly instead of spending that duration on
        // unrelated absence waits (the person route was checked above/below).
        evidence(app, name: "Direct map POI — 32-hour historical footprint playback")
        close.tap()

        waitForNativeDetent("Expanded", app: app)
        waitForHittable(historical, message: "Closing place history returns to the same expanded footprint grid")
        XCTAssertFalse(close.exists)
        for id in contributorIDs {
            XCTAssertTrue(app.buttons["experience.poi.footprint.\(id)"].exists)
        }
        assertNoPersonRoute(app)
        evidence(app, name: "Direct map POI — original expanded card after historical playback")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func openOwnStory(_ app: XCUIApplication) {
        let rail = element("maptalk.friend-story.rail", in: app)
        XCTAssertTrue(rail.waitForExistence(timeout: 8))
        let author = app.buttons["friend-story.author.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1"]
        for _ in 0..<24 {
            if author.isHittable { break }
            rail.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)).press(
                forDuration: 0.05,
                thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
            )
        }
        XCTAssertTrue(author.isHittable)
        author.tap()
        XCTAssertTrue(element("friend-story.navigation", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["friend-story.open-author"].value as? String, "chengsi")
    }

    @MainActor
    private func selectExistingPage(_ identifier: String, preferredIndex: Int, app: XCUIApplication, prefix: Bool = false) {
        let matches: () -> Bool = {
            let value = self.currentPage(app).identifier
            return prefix ? value.hasPrefix(identifier) : value == identifier
        }
        let count = pagePosition(app).count
        if count == 19 { selectPage(preferredIndex, app: app) }
        if !matches() {
            // Seed order may change, but discovery is bounded by the actual
            // current author's existing count, never an unbounded swipe loop.
            for index in 0..<min(count, 90) {
                selectPage(index, app: app)
                if matches() { break }
            }
        }
        XCTAssertTrue(matches(), "Expected the existing demo page \(identifier)")
    }

    @MainActor
    private func selectPage(_ index: Int, app: XCUIApplication) {
        let position = pagePosition(app)
        XCTAssertTrue((0..<position.count).contains(index))
        guard index != position.index else { return }
        let page = currentPage(app)
        XCTAssertTrue(page.isHittable)
        page.coordinate(withNormalizedOffset: CGVector(
            dx: (CGFloat(index) + 0.5) / CGFloat(position.count), dy: 0.5
        )).tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Update \(index + 1) of \(position.count)"),
            object: page
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed)
    }

    @MainActor
    private func pagePosition(_ app: XCUIApplication) -> (index: Int, count: Int) {
        let page = currentPage(app)
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let words = page.label.split(separator: " ")
        guard words.count == 4, words[0] == "Update", words[2] == "of",
              let number = Int(words[1]), let count = Int(words[3]), count > 0, (1...count).contains(number) else {
            XCTFail("Expected 'Update N of M', got '\(page.label)'")
            return (0, 1)
        }
        return (number - 1, count)
    }

    @MainActor
    private func currentPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "friend-story.page."
        )).firstMatch
    }

    @MainActor
    private func assertNoPersonRoute(_ app: XCUIApplication) {
        for id in ["friend-story.navigation", "friend-story.card", "maptalk.friend-story.back"] {
            let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(id, in: app))
            XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed,
                           "Direct-map interaction must not remain inside person navigation: \(id)")
        }
        XCTAssertFalse(app.buttons["friend-story.open-author"].exists)
    }

    @MainActor
    private func expandNativeCard(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        waitForHittable(grabber, message: "The original map sheet must expose its native grabber")
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
        )
        waitForNativeDetent("Expanded", app: app)
    }

    @MainActor
    private func revealFootprint(_ footprint: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 {
            if footprint.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
            )
        }
        waitForHittable(footprint, message: "The historical footprint must be reachable inside the original place card")
    }

    @MainActor
    private func waitForNativeDetent(_ value: String, app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", value),
            object: app.buttons["Sheet Grabber"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, "Expected native detent: \(value)")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, message: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed, message)
    }

    @MainActor
    private func assertStaysVisible(_ element: XCUIElement, seconds: TimeInterval, message: String) {
        let vanished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: element)
        vanished.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [vanished], timeout: seconds), .completed, message)
    }

    @MainActor
    private func waitForCamera(latitude: Double, longitude: Double, app: XCUIApplication) {
        let canvas = element("maptalk.map-canvas", in: app)
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = canvas.value as? String else { return false }
            let components = value.split(separator: ",").compactMap { Double($0) }
            return components.count == 2 && abs(components[0] - latitude) <= 0.08
                && abs(components[1] - longitude) <= 0.08
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 8), .completed,
                       "Wait for the real camera flight before tapping the actual map marker")
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func evidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

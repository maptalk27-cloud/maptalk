import XCTest

final class MapLayerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLayerPreviewSelector() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let layers = app.buttons["maptalk.map-layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 10))
        select("Standard", app: app)
        layers.tap()
        let standard = app.buttons["maptalk.layer.standard"]
        let satellite = app.buttons["maptalk.layer.satellite"]
        XCTAssertTrue(standard.waitForExistence(timeout: 3))
        XCTAssertTrue(standard.isSelected)
        XCTAssertEqual(standard.frame.midY, satellite.frame.midY, accuracy: 2)
        evidence(app, "Two compact map-style previews")
        satellite.tap()
        waitUntil { layers.value as? String == "Satellite" && !satellite.exists }
        layers.tap()
        XCTAssertTrue(satellite.waitForExistence(timeout: 3))
        XCTAssertTrue(satellite.isSelected)
        evidence(app, "Selected satellite preview in dark appearance")
        standard.tap()
        waitUntil { layers.value as? String == "Standard" && !standard.exists }
    }

    @MainActor
    func testLayersPreservePannedMapAndStory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let layers = app.buttons["maptalk.map-layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(layers.frame.width, 44)
        select("Standard", app: app)
        let locate = app.buttons["maptalk.locate"]
        XCTAssertTrue(locate.isHittable)
        XCTAssertLessThanOrEqual(layers.frame.maxY, locate.frame.minY)
        XCTAssertEqual(layers.frame.midX, locate.frame.midX, accuracy: 2,
                       "Layers and Locate share one vertical utility control")
        let standardLocateFrame = locate.frame

        let map = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch
        waitUntil { !(map.value as? String ?? "").isEmpty }
        let initial = map.value as? String
        app.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.44)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.44)))
        waitUntil { map.value as? String != initial }
        let pannedCenter = map.value as? String

        select("Satellite", app: app)
        XCTAssertEqual(map.value as? String, pannedCenter, "Changing layers must not recenter the map")
        XCTAssertEqual(locate.frame, standardLocateFrame, "Appearance must not move the existing controls")
        evidence(app, "Satellite with labels and lightweight layer control")
        app.buttons["MyMap"].tap()
        evidence(app, "MyMap retains its original appearance with satellite selected")
        app.buttons["MapFlick"].tap()
        XCTAssertTrue(layers.waitForExistence(timeout: 5))
        XCTAssertEqual(layers.value as? String, "Satellite")
        select("Standard", app: app)
        XCTAssertEqual(map.value as? String, pannedCenter)
        evidence(app, "Standard map layer control")

        let author = app.buttons["friend-story.author.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1"]
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        author.tap()
        let page = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "friend-story.page.")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let pageID = page.identifier
        let card = app.descendants(matching: .any)["friend-story.card"].firstMatch
        let detent = card.value as? String
        select("Satellite", app: app)
        XCTAssertEqual(page.identifier, pageID)
        XCTAssertEqual(card.value as? String, detent)
        evidence(app, "Satellite preserves compact story and annotations")
        select("Standard", app: app)
        XCTAssertEqual(page.identifier, pageID)
        XCTAssertEqual(card.value as? String, detent)

        card.coordinate(withNormalizedOffset: .init(dx: 0.84, dy: 0.15)).press(forDuration: 0.05,
            thenDragTo: card.coordinate(withNormalizedOffset: .init(dx: 0.16, dy: 0.15)))
        waitUntil { page.identifier != pageID }
    }

    @MainActor private func select(_ title: String, app: XCUIApplication) {
        let layers = app.buttons["maptalk.map-layers"]
        XCTAssertTrue(layers.isHittable)
        layers.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        waitUntil { layers.value as? String == title && !option.exists }
    }

    @MainActor private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }

    @MainActor private func evidence(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

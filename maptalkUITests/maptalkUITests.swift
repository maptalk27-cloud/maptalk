//
//  maptalkUITests.swift
//  maptalkUITests
//
//  Created by chengsi yang on 10/22/25.
//

import XCTest

final class maptalkUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testMyMapPinStaysOnMapAndOpensCapsule() throws {
        let app = XCUIApplication()
        app.launch()

        let myMapTab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMapTab.waitForExistence(timeout: 5))
        myMapTab.tap()

        let showMap = app.buttons["Show map"]
        XCTAssertTrue(showMap.waitForExistence(timeout: 5))
        showMap.tap()

        let mapPin = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mymap.map-marker.")
        ).firstMatch
        XCTAssertTrue(mapPin.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Done"].exists, "Entering Map must not itself enter Journey edit mode")
        mapPin.tap()

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MyMap pin opens a capsule in place"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let capsule = app.descendants(matching: .any)["mymap.compact-capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search memories"].exists)
    }

    @MainActor
    func testMyMapLongPressAddsMemoryToJourney() throws {
        let app = XCUIApplication()
        app.launch()

        let myMapTab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMapTab.waitForExistence(timeout: 5))
        myMapTab.tap()

        let showMap = app.buttons["Show map"]
        XCTAssertTrue(showMap.waitForExistence(timeout: 5))
        showMap.tap()

        let source = app.buttons["mymap.map-marker.00000000-0000-0000-0000-000000009122"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.press(forDuration: 0.75)

        XCTAssertTrue(app.maps.firstMatch.exists)
        XCTAssertTrue(app.buttons["Done"].exists)

        XCTAssertTrue(app.descendants(matching: .any)["mymap.journey-dock"].exists)
        let folder = app.descendants(matching: .any)["Journey folder: After dark"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertEqual(folder.value as? String, "3 memories")

        let sourcePoint = source.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        let folderPoint = folder.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        sourcePoint.press(forDuration: 0.2, thenDragTo: folderPoint)

        XCTAssertFalse(app.textFields["mymap.journey-name"].exists)
        let folderUpdated = expectation(
            for: NSPredicate(format: "value == %@", "4 memories"),
            evaluatedWith: folder
        )
        wait(for: [folderUpdated], timeout: 3)
        XCTAssertTrue(app.buttons["Done"].exists, "Organize mode must stay available after a successful drop")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MyMap map drag appends to an existing Journey"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMyMapContinuousLongPressDragCreatesJourney() throws {
        let app = XCUIApplication()
        app.launch()

        let myMapTab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMapTab.waitForExistence(timeout: 5))
        myMapTab.tap()

        let showMap = app.buttons["Show map"]
        XCTAssertTrue(showMap.waitForExistence(timeout: 5))
        showMap.tap()

        let source = app.buttons["mymap.map-marker.00000000-0000-0000-0000-000000009122"]
        let destination = app.buttons["mymap.map-marker.00000000-0000-0000-0000-000000009120"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.waitForExistence(timeout: 5))

        // The first long press must flow directly into the drag. Requiring a
        // release and second grab is precisely the interaction we are avoiding.
        let sourcePoint = source.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        let destinationPoint = destination.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        sourcePoint.press(forDuration: 0.75, thenDragTo: destinationPoint)

        let nameField = app.textFields["mymap.journey-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Night rhythm")
        app.buttons["mymap.save-journey-name"].tap()

        let createdFolder = app.descendants(matching: .any)["Journey folder: Night rhythm"]
        XCTAssertTrue(createdFolder.waitForExistence(timeout: 3))
        XCTAssertEqual(createdFolder.value as? String, "2 memories")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

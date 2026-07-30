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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

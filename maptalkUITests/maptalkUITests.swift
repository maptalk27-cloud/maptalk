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
    private func openMyMapList(_ app: XCUIApplication) {
        let myMapTab = app.tabBars.buttons["MyMap"]
        XCTAssertTrue(myMapTab.waitForExistence(timeout: 5))
        myMapTab.tap()
    }

    @MainActor
    private func openMyMapRootMap(_ app: XCUIApplication) {
        openMyMapList(app)

        let showMap = app.buttons["Show map"]
        XCTAssertTrue(showMap.waitForExistence(timeout: 5))
        showMap.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["mymap.map-canvas"].waitForExistence(timeout: 5)
        )
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
        XCTAssertFalse(app.buttons["Done"].exists, "Entering Map must not itself enter collection edit mode")
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
    func testMyMapRootMapHasNoCollectionBrowseShelf() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapRootMap(app)

        // Collections are deliberately not part of browsing the root canvas.
        XCTAssertFalse(app.buttons["mymap.map-journey-handle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.map-journey-shelf"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    @MainActor
    func testMyMapCollectionsOpenAsListAndAddThroughMyMap() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapList(app)

        let collections = app.buttons["mymap.collections-entry"]
        XCTAssertTrue(collections.waitForExistence(timeout: 5))
        collections.tap()

        let collectionsSheet = app.descendants(matching: .any)["mymap.collections-screen"]
        XCTAssertTrue(collectionsSheet.waitForExistence(timeout: 5))

        let afterDark = app.buttons[
            "mymap.collection-folder.00000000-0000-0000-0000-000000008101"
        ]
        XCTAssertTrue(afterDark.waitForExistence(timeout: 3))
        afterDark.tap()

        let collectionList = app.descendants(matching: .any)[
            "mymap.collection-list.00000000-0000-0000-0000-000000008101"
        ]
        XCTAssertTrue(collectionList.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["After dark"].exists)
        XCTAssertFalse(app.descendants(matching: .any)[
            "mymap.map-folder-scope.00000000-0000-0000-0000-000000008101"
        ].exists)
        XCTAssertFalse(app.buttons["Done"].exists)

        let addMemories = app.buttons["Add memories"]
        XCTAssertTrue(addMemories.waitForExistence(timeout: 3))
        addMemories.tap()

        XCTAssertTrue(app.navigationBars["Add to After dark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search memories"].exists)
        XCTAssertTrue(app.buttons["Filter records"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(collectionList.waitForExistence(timeout: 5))
    }

    @MainActor
    func testMyMapCollectionsCreateNamedFolder() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapList(app)

        let collections = app.buttons["mymap.collections-entry"]
        XCTAssertTrue(collections.waitForExistence(timeout: 5))
        collections.tap()

        let collectionsSheet = app.descendants(matching: .any)["mymap.collections-screen"]
        XCTAssertTrue(collectionsSheet.waitForExistence(timeout: 5))

        app.buttons["mymap.collections-add"].tap()
        let newCollection = app.alerts["New collection"]
        XCTAssertTrue(newCollection.waitForExistence(timeout: 5))

        newCollection.buttons["Cancel"].tap()
        XCTAssertTrue(collectionsSheet.waitForExistence(timeout: 5))

        app.buttons["mymap.collections-add"].tap()
        XCTAssertTrue(newCollection.waitForExistence(timeout: 5))

        let nameField = newCollection.textFields["Collection name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Weekend plans")
        newCollection.buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["Weekend plans"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMyMapListLeadingSwipeOpensCollectionPicker() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapList(app)

        let record = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.swipeRight()

        let add = app.buttons["Add to collection"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()

        XCTAssertTrue(app.navigationBars["Add to collection"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 3))
    }

    @MainActor
    func testMyMapListRecordOpensAFocusedMapPreview() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapList(app)

        let record = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["mymap.map-canvas"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["mymap.compact-capsule"].waitForExistence(timeout: 5)
        )
        // A tapped list record is a local preview, not the root map browser.
        XCTAssertFalse(app.textFields["Search memories"].exists)
        XCTAssertFalse(app.buttons["Show list"].exists)

        let returnToList = app.buttons["Return to list"]
        XCTAssertTrue(returnToList.waitForExistence(timeout: 3))
        returnToList.tap()

        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search memories"].exists)
    }

    @MainActor
    func testMyMapListTrailingSwipeConfirmsBeforeRemovingMemory() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapList(app)

        let record = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.swipeLeft()

        let remove = app.buttons["Remove from MyMap"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()

        let confirmation = app.buttons["Remove"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()

        let rowIsGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: record
        )
        wait(for: [rowIsGone], timeout: 3)
    }

    @MainActor
    func testMyMapRootLongPressDoesNotEnterOrganizer() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapRootMap(app)

        let source = app.buttons["mymap.map-marker.00000000-0000-0000-0000-000000000112"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.press(forDuration: 0.75)

        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.map-journey-shelf"].exists)
    }

    @MainActor
    func testMyMapOverlappingMarkersCycleThroughTheirMemories() throws {
        let app = XCUIApplication()
        app.launch()

        openMyMapRootMap(app)

        let stack = app.buttons[
            "mymap.map-marker-stack.00000000-0000-0000-0000-000000000117:00000000-0000-0000-0000-000000007005"
        ]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))

        stack.tap()
        XCTAssertTrue(app.buttons["Thames Fog Ferry"].waitForExistence(timeout: 3))

        stack.tap()
        XCTAssertTrue(
            app.buttons["River Thames ferry deck turned tea bar. Fog lasers!"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

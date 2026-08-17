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
    func testChatsSearchAppearsOnlyAfterPullingDown() throws {
        let app = XCUIApplication()
        app.launch()

        let chatsTab = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 5))
        chatsTab.tap()

        let search = app.textFields["chats.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        XCTAssertFalse(search.isHittable, "Chat search should begin above the visible layout")

        app.swipeDown()
        let searchIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: search
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [searchIsHittable], timeout: 2),
            .completed,
            "Pulling the chat list down should reveal search"
        )
    }

    @MainActor
    func testMapTalkHasTwoFocusedPublishEntrypoints() throws {
        let app = XCUIApplication()
        app.launch()

        let addPlace = app.buttons["Add a place"]
        XCTAssertTrue(addPlace.waitForExistence(timeout: 5))
        XCTAssertTrue(addPlace.isEnabled)
        addPlace.tap()

        let composer = app.descendants(matching: .any)["maptalk.publish-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        // Simulator stays on the capture surface. The library is presented
        // only after the person explicitly taps its button.
        XCTAssertTrue(app.staticTexts["Place"].exists)
        XCTAssertFalse(app.navigationBars["Add a place"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["maptalk.place.add-media"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["maptalk.place.choose-landmark"].exists
                || app.textFields["maptalk.place.new-name"].exists
        )
        let placeAudience = app.buttons["maptalk.place.audience"]
        XCTAssertTrue(placeAudience.exists)
        XCTAssertTrue(app.buttons["Add to MyMap"].exists)
        placeAudience.tap()
        let publicAudience = app.buttons["Public"]
        XCTAssertTrue(publicAudience.waitForExistence(timeout: 2))
        publicAudience.tap()
        XCTAssertTrue(app.buttons["Post"].exists)

        let chooseLandmark = app.descendants(matching: .any)["maptalk.place.choose-landmark"]
        if chooseLandmark.exists {
            chooseLandmark.tap()
            XCTAssertTrue(app.staticTexts["Choose a place"].waitForExistence(timeout: 2))
            XCTAssertFalse(app.descendants(matching: .any)["maptalk.place.add-media"].exists)

            let pickerBack = app.buttons["Back to place"]
            XCTAssertTrue(pickerBack.waitForExistence(timeout: 2))
            pickerBack.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["maptalk.place.add-media"].waitForExistence(timeout: 2)
            )
        }
        app.buttons["maptalk.publish.cancel"].tap()

        let shareReel = app.buttons["Share a reel"]
        XCTAssertTrue(shareReel.waitForExistence(timeout: 3))
        XCTAssertTrue(shareReel.isEnabled)
        shareReel.tap()

        XCTAssertTrue(app.descendants(matching: .any)["maptalk.publish-composer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["New reel"].exists)
        XCTAssertFalse(app.navigationBars["Share a reel"].exists)
        XCTAssertTrue(app.buttons["maptalk.reel.add-media"].exists)
        XCTAssertTrue(app.textViews["maptalk.reel.text"].exists)
        let chooseBubble = app.descendants(matching: .any)["maptalk.reel.choose-bubble"]
        XCTAssertTrue(chooseBubble.exists)
        XCTAssertTrue(app.buttons["maptalk.reel.audience"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)

        chooseBubble.tap()
        XCTAssertTrue(app.staticTexts["Add bubble"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Memories"].exists)
        XCTAssertTrue(app.buttons["Folders"].exists)
        XCTAssertFalse(app.buttons["Timeline"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["maptalk.reel.bubble-date-section.Today"]
                .waitForExistence(timeout: 2)
        )

        let firstMemory = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "maptalk.reel.bubble-memory.")
        ).firstMatch
        XCTAssertTrue(firstMemory.waitForExistence(timeout: 2))
        firstMemory.tap()
        XCTAssertTrue(app.staticTexts["1 memory selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Remove bubble selection"].exists)
        app.buttons["Back to reel"].tap()

        XCTAssertTrue(chooseBubble.waitForExistence(timeout: 2))
        XCTAssertTrue(chooseBubble.label.contains("Add"), "Back must discard pending Bubble edits")

        chooseBubble.tap()
        XCTAssertTrue(firstMemory.waitForExistence(timeout: 2))
        firstMemory.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["maptalk.reel.bubble-preview"]
                .waitForExistence(timeout: 2),
            "A selected Bubble should preview its memories without replacing the composer"
        )
        XCTAssertTrue(chooseBubble.label.contains("1 memory"))
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

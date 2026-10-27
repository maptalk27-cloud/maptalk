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
        app.launchArguments = ["--mock-data"]
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testChatsSearchAppearsOnlyAfterPullingDown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
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
        app.launchArguments = ["--mock-data"]
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
    func testMapTalkHistoryLayerKeepsMapGesturesPrimary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()

        let map = app.descendants(matching: .any)["maptalk.map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 8))

        let compactMarkers = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "maptalk.friend-place.compact."
            )
        )
        let expandedMarkers = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "maptalk.friend-place.expanded."
            )
        )
        let compactMarker = compactMarkers.firstMatch
        XCTAssertTrue(compactMarker.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(
            expandedMarkers.count,
            8,
            "Only a small ranked set of friend places should expand into large controls"
        )
        XCTAssertEqual(compactMarker.frame.width, 16, accuracy: 1)
        XCTAssertEqual(compactMarker.frame.height, 16, accuracy: 1)

        let preview = app.descendants(matching: .any)["maptalk.friend-place-preview"]
        XCTAssertFalse(preview.exists)

        let compactCenter = compactMarker.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        compactCenter.withOffset(CGVector(dx: 10, dy: 0)).tap()
        XCTAssertFalse(
            preview.waitForExistence(timeout: 0.5),
            "Tapping just outside a compact circle must remain an ordinary map tap"
        )

        let draggedMarkerID = compactMarker.identifier
        let originalMarkerFrame = compactMarker.frame
        compactCenter.press(
            forDuration: 0.05,
            thenDragTo: compactCenter.withOffset(CGVector(dx: 52, dy: 32))
        )
        XCTAssertFalse(
            preview.waitForExistence(timeout: 0.5),
            "Dragging from a compact circle must not be interpreted as a tap"
        )
        let draggedMarker = app.buttons[draggedMarkerID]
        XCTAssertTrue(
            draggedMarker.exists == false
                || abs(draggedMarker.frame.midX - originalMarkerFrame.midX) > 2
                || abs(draggedMarker.frame.midY - originalMarkerFrame.midY) > 2,
            "The map must still pan when a drag begins on a compact friend button"
        )

        map.pinch(withScale: 1.35, velocity: 1.1)
        XCTAssertFalse(
            preview.waitForExistence(timeout: 0.5),
            "Pinching the map must not open friend history"
        )

        let refreshedCompactMarkers = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "maptalk.friend-place.compact."
            )
        )
        let refreshedExpandedMarkers = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "maptalk.friend-place.expanded."
            )
        )
        let refreshedCompactMarker = refreshedCompactMarkers.firstMatch
        XCTAssertTrue(refreshedCompactMarker.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            refreshedExpandedMarkers.count,
            8,
            "Zooming must preserve the large-control budget"
        )
        XCTAssertEqual(refreshedCompactMarker.frame.width, 16, accuracy: 1)
        XCTAssertEqual(refreshedCompactMarker.frame.height, 16, accuracy: 1)
        let controlFrames = [
            app.buttons["location.circle.fill"],
            app.buttons["maptalk.add-place"],
            app.buttons["maptalk.share-reel"]
        ].map(\.frame)
        for marker in refreshedCompactMarkers.allElementsBoundByIndex
            + refreshedExpandedMarkers.allElementsBoundByIndex {
            XCTAssertFalse(
                controlFrames.contains { $0.intersects(marker.frame) },
                "A visible place must not be hidden beneath a map control: \(marker.identifier)"
            )
        }
        refreshedCompactMarker.tap()
        XCTAssertTrue(
            preview.waitForExistence(timeout: 5),
            "A direct tap on a compact friend button must open its preview"
        )
    }

    @MainActor
    func testMyMapPinStaysOnMapAndOpensCapsule() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
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
        app.launchArguments = ["--mock-data"]
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
        app.launchArguments = ["--mock-data"]
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

        let addSelected = app.buttons["mymap.add-selected-memories"]
        XCTAssertTrue(addSelected.waitForExistence(timeout: 3))
        XCTAssertFalse(addSelected.isEnabled)

        let alreadyAdded = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertTrue(alreadyAdded.waitForExistence(timeout: 3))
        XCTAssertFalse(alreadyAdded.isEnabled)
        XCTAssertEqual(alreadyAdded.value as? String, "Already in collection")

        app.buttons["mymap.cancel-selection"].tap()
        XCTAssertTrue(collectionList.waitForExistence(timeout: 5))

        addMemories.tap()
        let newMemory = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009122"
        ]
        XCTAssertTrue(newMemory.waitForExistence(timeout: 3))
        newMemory.tap()
        XCTAssertEqual(addSelected.value as? String, "1 selected")
        addSelected.tap()
        XCTAssertTrue(collectionList.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 memories"].exists)
        XCTAssertTrue(app.buttons[
            "mymap.collection-memory.00000000-0000-0000-0000-000000009122"
        ].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.collection-picker"].exists)
    }

    @MainActor
    func testMyMapCollectionsCreateNamedFolder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
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
    func testMyMapListLeadingSwipeDoesNotOfferCollectionAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()

        openMyMapList(app)
        let select = app.buttons["mymap.select-memories"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))

        let record = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.swipeRight()

        XCTAssertFalse(app.buttons["Add to collection"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.collection-picker"].exists)
        XCTAssertTrue(select.exists)
        XCTAssertTrue(app.textFields["Search memories"].exists)
        XCTAssertFalse(app.buttons["Return to list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.compact-capsule"].exists)
    }

    @MainActor
    func testMyMapMultipleSelectionCanToggleAndCancelWithoutOpeningMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()
        openMyMapList(app)

        let select = app.buttons["mymap.select-memories"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        let collections = app.buttons["mymap.collections-entry"]
        XCTAssertTrue(collections.exists)
        let title = app.navigationBars["MyMap"].staticTexts["MyMap"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(select.frame.maxX, title.frame.minX)
        XCTAssertGreaterThan(collections.frame.minX, title.frame.maxX)
        select.tap()

        let addSelected = app.buttons["mymap.add-selected-memories"]
        XCTAssertTrue(addSelected.waitForExistence(timeout: 3))
        XCTAssertFalse(addSelected.isEnabled)
        XCTAssertEqual(addSelected.value as? String, "0 selected")
        XCTAssertFalse(app.buttons["Show map"].exists)

        let record = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        XCTAssertEqual(record.value as? String, "Not selected")
        record.tap()
        XCTAssertEqual(record.value as? String, "Selected")
        XCTAssertEqual(addSelected.value as? String, "1 selected")
        XCTAssertTrue(addSelected.isEnabled)
        XCTAssertTrue(app.navigationBars["Select memories"].exists)
        XCTAssertTrue(app.buttons["mymap.cancel-selection"].exists)
        XCTAssertFalse(app.buttons["Return to list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.compact-capsule"].exists)

        // Organizing taps and swipes must not become browsing or deletion.
        record.swipeLeft()
        XCTAssertFalse(app.buttons["Remove from MyMap"].exists)
        XCTAssertFalse(app.buttons["Delete from MyMap and feed"].exists)
        XCTAssertEqual(addSelected.value as? String, "1 selected")
        XCTAssertEqual(record.value as? String, "Selected")
        record.swipeRight()
        XCTAssertEqual(addSelected.value as? String, "1 selected")
        XCTAssertEqual(record.value as? String, "Selected")
        XCTAssertFalse(app.buttons["Return to list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.compact-capsule"].exists)
        record.tap()
        XCTAssertEqual(record.value as? String, "Not selected")
        XCTAssertFalse(addSelected.isEnabled)

        record.tap()
        app.buttons["mymap.cancel-selection"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Show map"].exists)
        XCTAssertFalse(addSelected.exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.collections-screen"].exists)

        let browsingScreenshot = XCTAttachment(screenshot: app.screenshot())
        browsingScreenshot.name = "MyMap list after cancelling selection"
        browsingScreenshot.lifetime = .keepAlways
        add(browsingScreenshot)

        select.tap()
        XCTAssertEqual(addSelected.value as? String, "0 selected")
        XCTAssertEqual(record.value as? String, "Not selected")
        app.buttons["mymap.cancel-selection"].tap()
    }

    @MainActor
    func testMyMapMultipleSelectionSurvivesSearchAndPickerCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()
        openMyMapList(app)
        app.buttons["mymap.select-memories"].tap()

        let kyoto = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009118"
        ]
        kyoto.tap()

        let search = app.textFields["Search memories"]
        search.tap()
        search.typeText("Nairobi")
        let nairobi = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009122"
        ]
        XCTAssertTrue(nairobi.waitForExistence(timeout: 3))
        nairobi.tap()

        let addSelected = app.buttons["mymap.add-selected-memories"]
        XCTAssertEqual(addSelected.value as? String, "2 selected")
        addSelected.tap()
        let picker = app.descendants(matching: .any)["mymap.collection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        app.navigationBars["Add to collection"].buttons["Cancel"].tap()

        XCTAssertTrue(addSelected.waitForExistence(timeout: 3))
        XCTAssertEqual(addSelected.value as? String, "2 selected")
        XCTAssertEqual(nairobi.value as? String, "Selected")
        XCTAssertEqual(search.value as? String, "Nairobi")

        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Nairobi".count))
        XCTAssertTrue(kyoto.waitForExistence(timeout: 3))
        XCTAssertEqual(kyoto.value as? String, "Selected")
        XCTAssertEqual(nairobi.value as? String, "Selected")
        XCTAssertTrue(app.navigationBars["Select memories"].exists)
        XCTAssertTrue(app.buttons["mymap.cancel-selection"].exists)
        XCTAssertFalse(app.buttons["Return to list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mymap.compact-capsule"].exists)
        app.buttons["mymap.cancel-selection"].tap()
    }

    @MainActor
    func testMyMapMultipleSelectionCreatesFolderWithOnlySelectedMemories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()
        openMyMapList(app)
        app.buttons["mymap.select-memories"].tap()

        let selectedIDs = [
            "00000000-0000-0000-0000-000000009118",
            "00000000-0000-0000-0000-000000009120"
        ]
        for id in selectedIDs {
            app.buttons["mymap.list-record.\(id)"].tap()
        }

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "MyMap list with two selected memories"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)

        app.buttons["mymap.add-selected-memories"].tap()

        let picker = app.descendants(matching: .any)["mymap.collection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let newFolder = app.buttons["mymap.picker-new-collection"]
        newFolder.tap()
        let naming = app.alerts["New collection"]
        XCTAssertTrue(naming.waitForExistence(timeout: 3))
        naming.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 3))

        newFolder.tap()
        let name = naming.textFields["Collection name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Selected weekend")
        naming.buttons["Create"].tap()

        XCTAssertTrue(app.buttons["mymap.select-memories"].waitForExistence(timeout: 5))
        XCTAssertFalse(picker.exists)
        XCTAssertFalse(app.buttons["mymap.add-selected-memories"].exists)
        app.buttons["mymap.collections-entry"].tap()
        let folder = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "mymap.collection-folder.", "Open Selected weekend"
        )).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        XCTAssertEqual(folder.value as? String, "2 memories")
        folder.tap()
        XCTAssertTrue(app.navigationBars["Selected weekend"].waitForExistence(timeout: 3))

        let memberRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mymap.collection-memory."
        ))
        XCTAssertEqual(memberRows.count, 2)
        for id in selectedIDs {
            XCTAssertTrue(app.buttons["mymap.collection-memory.\(id)"].exists)
        }
        XCTAssertFalse(app.buttons[
            "mymap.collection-memory.00000000-0000-0000-0000-000000009122"
        ].exists)
    }

    @MainActor
    func testMyMapMultipleSelectionAddsToExistingFolderWithoutDuplicates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
        app.launch()
        openMyMapList(app)
        app.buttons["mymap.select-memories"].tap()

        // Kyoto is already in After dark; Nairobi is not. Both can be selected
        // before a destination is chosen, but only Nairobi should be appended.
        app.buttons["mymap.list-record.00000000-0000-0000-0000-000000009118"].tap()
        app.buttons["mymap.add-selected-memories"].tap()
        let destination = app.buttons[
            "mymap.collection-destination.00000000-0000-0000-0000-000000008101"
        ]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertFalse(destination.isEnabled, "A destination containing all selected memories is a no-op")
        app.navigationBars["Add to collection"].buttons["Cancel"].tap()

        let newMemory = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009122"
        ]
        XCTAssertTrue(newMemory.waitForExistence(timeout: 3))
        newMemory.tap()
        app.buttons["mymap.add-selected-memories"].tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertTrue(destination.isEnabled)
        destination.tap()

        XCTAssertTrue(app.buttons["mymap.select-memories"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mymap.add-selected-memories"].exists)
        app.buttons["mymap.collections-entry"].tap()
        let folder = app.buttons[
            "mymap.collection-folder.00000000-0000-0000-0000-000000008101"
        ]
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        XCTAssertEqual(folder.value as? String, "4 memories")
        folder.tap()
        XCTAssertTrue(app.navigationBars["After dark"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["4 memories"].exists)
        XCTAssertEqual(app.buttons.matching(identifier:
            "mymap.collection-memory.00000000-0000-0000-0000-000000009118"
        ).count, 1)
        XCTAssertTrue(app.buttons[
            "mymap.collection-memory.00000000-0000-0000-0000-000000009122"
        ].exists)

        app.buttons["Add memories"].tap()
        let added = app.buttons[
            "mymap.list-record.00000000-0000-0000-0000-000000009122"
        ]
        XCTAssertTrue(added.waitForExistence(timeout: 3))
        XCTAssertFalse(added.isEnabled)
        XCTAssertEqual(added.value as? String, "Already in collection")
        app.buttons["mymap.cancel-selection"].tap()
        XCTAssertTrue(app.navigationBars["After dark"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testMyMapListRecordOpensAFocusedMapPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
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
    func testMyMapPortraitVideoCardKeepsSharedChromeAndExpandsFullWidth() throws {
        // This existing memory contains the bundled portrait MP4, three likes,
        // and an attached Journey. It exercises the actual shared card without
        // Photos access, a new fixture launch path, or a physical device.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        openMyMapList(app)
        let record = app.buttons["mymap.list-record.00000000-0000-0000-0000-000000009118"]
        guard record.waitForExistence(timeout: 5) else {
            XCTFail("The existing bundled portrait-video memory must be available")
            return
        }
        record.tap()

        // The parent's identifier can propagate to its background images.
        // Select the pager explicitly, then find shared chrome globally by ID;
        // compact content may be exposed as Buttons instead of StaticTexts.
        let pager = app.collectionViews["mymap.compact-capsule"].firstMatch
        guard pager.waitForExistence(timeout: 5) else {
            XCTFail("Selecting the memory must open its ordinary compact card")
            return
        }
        waitForVideoCardDetent(in: app, expanded: false)
        let compactFrame = pager.frame
        attachVideoCardEvidence(app, name: "Portrait video — compact shared card")

        assertPortraitVideoChrome(in: app, inside: compactFrame)

        // Use the open area of the card, avoiding the interactive author and
        // Journey capsule, so this is the same tap-to-expand used by people.
        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45)).tap()
        waitForVideoCardDetent(in: app, expanded: true)
        attachVideoCardEvidence(app, name: "Portrait video — expanded shared card")
        XCTAssertGreaterThan(pager.frame.height, compactFrame.height + 80)

        let video = app.descendants(matching: .any)[
            "experience.real.video.00000000-0000-0000-0000-000000009118"
        ].firstMatch
        guard video.waitForExistence(timeout: 5) else {
            XCTFail("The expanded card must expose its ordinary video playback target")
            return
        }
        XCTAssertEqual(video.frame.minX, app.frame.minX, accuracy: 1,
                       "Expanded video must reach the sheet's left edge")
        XCTAssertEqual(video.frame.maxX, app.frame.maxX, accuracy: 1,
                       "Expanded video must reach the sheet's right edge")
        XCTAssertEqual(video.label, "Play video")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45)).tap()

        let close = app.buttons["experience.media-lightbox.close"]
        guard close.waitForExistence(timeout: 5) else {
            XCTFail("Tapping video must open the existing lightbox with its Close control")
            return
        }
        attachVideoCardEvidence(app, name: "Portrait video — playback lightbox")
        close.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        waitForVideoCardDetent(in: app, expanded: true)
        attachVideoCardEvidence(app, name: "Portrait video — returned to expanded card")

        // Drag the native grabber toward the compact detent rather than
        // swiping the video, whose gestures belong to playback and paging.
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let collapseTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: collapseTarget)
        waitForVideoCardDetent(in: app, expanded: false)
        attachVideoCardEvidence(app, name: "Portrait video — collapsed after playback")
        XCTAssertLessThan(pager.frame.height, app.frame.height * 0.5)
        assertPortraitVideoChrome(in: app, inside: pager.frame)

        let journey = app.buttons["Journey memories"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 5))
        XCTAssertTrue(journey.isHittable, "The compact Journey capsule must remain interactive after playback")
        journey.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mymap.journey-header"].firstMatch
            .waitForExistence(timeout: 5))
        let map = app.descendants(matching: .any)["mymap.map-canvas"].firstMatch
        XCTAssertEqual(map.value as? String, "Journey: Kyoto lantern run",
                       "The existing Journey capsule must open its own memories")
        attachVideoCardEvidence(app, name: "Portrait video — Journey capsule remains interactive")
    }

    @MainActor
    private func assertPortraitVideoChrome(in app: XCUIApplication, inside frame: CGRect) {
        let postID = "00000000-0000-0000-0000-000000009118"
        for (suffix, label) in [("author", "chengsi"), ("avatar", "chengsi avatar"), ("likes", "3 likes")] {
            let element = app.descendants(matching: .any)["experience.real.\(suffix).\(postID)"].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "The compact card must retain \(suffix)")
            if element.exists {
                XCTAssertEqual(element.label, label)
                assertVideoCardElement(element, isInside: frame, name: suffix)
            }
        }
    }

    @MainActor
    private func waitForVideoCardDetent(in app: XCUIApplication, expanded: Bool) {
        let grabber = app.buttons["Sheet Grabber"]
        let expectedValue = expanded ? "Expanded" : "Half screen"
        let reachedDetent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", expectedValue), object: grabber
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reachedDetent], timeout: 5), .completed,
                       "The native sheet must settle at its \(expectedValue) detent")
    }

    @MainActor
    private func assertVideoCardElement(_ element: XCUIElement, isInside frame: CGRect, name: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(element.frame.isEmpty, "\(name) must have visible bounds", file: file, line: line)
        XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(element.frame),
                      "\(name) must remain within the visible card: \(element.frame) in \(frame)",
                      file: file, line: line)
    }

    @MainActor
    private func attachVideoCardEvidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) — accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    func testMyMapListTrailingSwipeConfirmsBeforeRemovingMemory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data"]
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
        app.launchArguments = ["--mock-data"]
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
        app.launchArguments = ["--mock-data"]
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
            let app = XCUIApplication()
            app.launchArguments = ["--mock-data"]
            app.launch()
        }
    }
}

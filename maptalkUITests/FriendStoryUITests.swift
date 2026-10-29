import XCTest

/// Uses the existing simulator and demo fixtures. No authentication, live
/// publishing, device installation or destructive fixture reset is required.
final class FriendStoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOneAuthorEntryOwnsBothPOIAndReelUpdates() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let authorID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        let author = revealAuthor(authorID, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "friend-story.author.\(authorID)").count, 1)
        author.tap()
        evidence(app, name: "Person story — initial compact card")
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        rewind(app)

        var sawPlace = false
        var sawReel = false
        var reelIndex: Int?
        for _ in 0..<90 {
            XCTAssertEqual(currentAuthor(app).value as? String, "aurora.wave")
            assertSharedHeader(app)
            if currentPage(app).identifier.hasPrefix("friend-story.page.poi:") {
                assertOriginalPOICard(app, expanded: false)
                sawPlace = true
            }
            if currentPage(app).identifier.hasPrefix("friend-story.page.reel:") {
                sawReel = true
                reelIndex = pagePosition(app).index
            }
            if sawPlace && sawReel { break }
            if !advancePage(app) { break }
        }
        XCTAssertTrue(sawPlace, "Exact POI visits must participate in the author's story")
        XCTAssertTrue(sawReel, "The same author entry must retain the original Reel card")
        selectPage(try XCTUnwrap(reelIndex), app: app)
        evidence(app, name: "One person — mixed original records")
        let reelPage = currentPage(app).identifier
        XCTAssertTrue(reelPage.hasPrefix("friend-story.page.reel:"))
        let reelID = try XCTUnwrap(UUID(uuidString: String(reelPage.dropFirst("friend-story.page.reel:".count))))
        // The Paris demo Reel deliberately has no caption. Its original
        // identity and media remain present; do not require invented text.
        assertOriginalReelIdentity(reelID.uuidString, app: app)
        XCTAssertTrue(app.descendants(matching: .any)["experience.real.author.\(reelID.uuidString)"].firstMatch.isHittable)
        let reelPosition = pagePosition(app)
        let adjacentIndex = reelPosition.index + 1 < reelPosition.count
            ? reelPosition.index + 1 : reelPosition.index - 1
        swipeCard(to: adjacentIndex, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, "aurora.wave",
                       "Swiping the original Reel card selects another update from the same person")
        swipeCard(to: reelPosition.index, app: app)
        XCTAssertEqual(currentPage(app).identifier, reelPage)
        selectPage(pagePosition(app).count - 1, app: app)
        dragCardForward(true, app: app)
        waitForAuthorChange(from: "aurora.wave", app: app)
        XCTAssertEqual(pagePosition(app).index, 0)
    }

    @MainActor
    func testPlaceReturnsToExactPageAndExpandedNavigationKeepsDetent() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        rewind(app)
        // The floating bar selects the story slice; the original POI card
        // retains its compact/expanded layout and original avatar interaction.
        for _ in 0..<90 {
            let position = pagePosition(app)
            if currentPage(app).identifier.hasPrefix("friend-story.page.poi:")
                && poiMediaID(from: currentPage(app).identifier) != nil
                && position.index > 0 && position.index + 1 < position.count { break }
            XCTAssertTrue(advancePage(app), "The demo author must have an interior POI media update")
        }
        let pageID = currentPage(app).identifier
        let mediaID = try XCTUnwrap(poiMediaID(from: pageID))
        let author = currentAuthor(app).value as? String
        let authorID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        let pageIndex = pagePosition(app).index
        assertSharedHeader(app)

        selectPage(pageIndex - 1, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        selectPage(pageIndex, app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        selectPage(pageIndex + 1, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        selectPage(pageIndex, app: app)

        assertOriginalPOICard(app, expanded: false)
        evidence(app, name: "Original POI — compact card with circular contributor avatars")
        let sharer = app.buttons["experience.poi.sharer.\(authorID)"]
        XCTAssertTrue(sharer.waitForExistence(timeout: 5))
        XCTAssertTrue(sharer.isHittable)
        sharer.tap()
        assertCurrentPOIMedia(mediaID, app: app)
        evidence(app, name: "Original POI circular avatar — exact current story slice")
        app.buttons["experience.poi-story.close"].tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Half screen", app: app)
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: false)

        let collapsed = app.descendants(matching: .any)["experience.poi.collapsed"].firstMatch
        collapsed.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.15)).tap()
        waitForDetent("Expanded", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID,
                       "The original compact POI card expands the current update instead of switching posts")
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertOriginalPOICard(app, expanded: true)
        assertSharedHeader(app)
        evidence(app, name: "Original POI — expanded place card with footprints")

        selectPage(pageIndex + 1, app: app)
        waitForDetent("Expanded", app: app)
        XCTAssertNotEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        swipeCard(to: pageIndex, app: app)
        waitForDetent("Expanded", app: app)
        assertOriginalPOICard(app, expanded: true)

        let footprint = app.buttons["experience.poi.footprint.\(authorID)"]
        XCTAssertTrue(footprint.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if footprint.isHittable { break }
            storyCard(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).press(
                forDuration: 0.05,
                thenDragTo: storyCard(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
            )
        }
        XCTAssertTrue(footprint.isHittable, "The original expanded footprint avatar remains interactive")
        footprint.tap()
        assertCurrentPOIMedia(mediaID, app: app)
        evidence(app, name: "Original POI footprint — exact current story slice")
        app.buttons["experience.poi-story.close"].tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: true)

        swipeCard(to: pageIndex + 1, app: app)
        waitForDetent("Expanded", app: app)
        XCTAssertNotEqual(currentPage(app).identifier, pageID)
        evidence(app, name: "Original POI returns exactly — next item stays expanded")
    }

    @MainActor
    func testMapDragStaysIndependentAndCardPagingStaysWithinAuthor() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        rewind(app)
        findPlacePage(app)
        let originalAuthor = currentAuthor(app).value as? String
        let originalPage = currentPage(app).identifier
        let originalIndex = pagePosition(app).index

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        )
        XCTAssertEqual(currentAuthor(app).value as? String, originalAuthor)
        XCTAssertEqual(currentPage(app).identifier, originalPage)

        assertOriginalPOICard(app, expanded: false)
        let stage = storyCard(app)
        let restingFrame = stage.frame
        let position = pagePosition(app)
        let adjacentIndex = position.index + 1 < position.count ? position.index + 1 : position.index - 1
        swipeCard(to: adjacentIndex, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, originalAuthor,
                       "An interior card drag selects another update within this person")
        XCTAssertNotEqual(currentPage(app).identifier, originalPage)
        waitForDetent("Half screen", app: app)
        swipeCard(to: originalIndex, app: app)
        XCTAssertEqual(currentPage(app).identifier, originalPage)
        XCTAssertEqual(stage.frame.minX, restingFrame.minX, accuracy: 2,
                       "The content card must not inherit the floating bar's navigation motion")

        let identityRow = authorNavigation(app)
        let identityRestingFrame = identityRow.frame
        identityRow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: identityRow.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0.15
        )
        XCTAssertEqual(currentAuthor(app).value as? String, originalAuthor,
                       "A short horizontal pull on the floating identity must cancel instead of changing people")
        XCTAssertEqual(currentPage(app).identifier, originalPage)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(identityRow.frame.minX - identityRestingFrame.minX) < 2
        }, object: identityRow)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed,
                       "The floating identity must settle back after a cancelled pull")
        XCTAssertEqual(stage.frame.minX, restingFrame.minX, accuracy: 2,
                       "Dragging the floating identity must leave the original card's layout unchanged")
        identityRow.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: identityRow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        )
        XCTAssertEqual(currentAuthor(app).value as? String, originalAuthor)
        XCTAssertEqual(currentPage(app).identifier, originalPage)
        XCTAssertTrue(storyNavigation(app).exists)
        evidence(app, name: "Map stays independent — only lower cards page through updates")
    }

    @MainActor
    func testDownwardPullCollapsesWithoutSwitchingPersonAndNativeDismissExits() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        rewind(app)
        findPlacePage(app)
        assertSharedHeader(app)
        let pageID = currentPage(app).identifier
        assertOriginalPOICard(app, expanded: false)
        let selectedPOIMarker = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "maptalk.marker.poi.", "Category, selected"
        )).firstMatch
        XCTAssertTrue(selectedPOIMarker.waitForExistence(timeout: 8),
                      "Selecting a POI keeps its original category marker instead of replacing it with the person's avatar")
        let collapsed = app.descendants(matching: .any)["experience.poi.collapsed"].firstMatch
        collapsed.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.15)).tap()
        waitForDetent("Expanded", app: app)
        assertOriginalPOICard(app, expanded: true)
        let stage = storyCard(app)
        let author = currentAuthor(app).value as? String
        let expandedFrame = stage.frame
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.44)).press(
            forDuration: 0.05,
            thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.58)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Expanded", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertSharedHeader(app)
        XCTAssertEqual(stage.frame.minY, expandedFrame.minY, accuracy: 4,
                       "A short diagonal pull should cancel natively, not switch person or move the card permanently")
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.45)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.88)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Half screen", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: false)
        XCTAssertFalse(app.buttons["friend-story.close"].exists,
                       "The floating identity has no separate exit button")
        evidence(app, name: "Middle pull collapses — original card and detached identity remain")

        // A second native downward pull dismisses the compact sheet and its
        // floating accessory together, without a separate exit button.
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        waitUntilAbsent(storyNavigation(app))
        waitUntilAbsent(currentPage(app))
        XCTAssertFalse(app.buttons["maptalk.friend-story.back"].exists)
        XCTAssertFalse(app.buttons["friend-story.open-author"].exists,
                       "Native dismissal must not leave an orphaned author accessory on the map")
        let rail = app.descendants(matching: .any)["maptalk.friend-story.rail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(rail.isHittable, "The ordinary people rail remains available after dismissing the story")
        evidence(app, name: "Native compact dismissal — no orphaned floating identity")

        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        waitForDetent("Half screen", app: app)
        assertSharedHeader(app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "friend-story.navigation").count, 1,
                       "Reopening creates exactly one floating accessory")
        XCTAssertFalse(app.buttons["friend-story.close"].exists)
        evidence(app, name: "Reopened after native dismissal — single detached identity")
    }

    @MainActor
    func testFloatingAuthorProfileReturnsToExactStory() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        assertSharedHeader(app)
        let pageID = currentPage(app).identifier
        let author = currentAuthor(app).value as? String

        app.buttons["friend-story.open-author"].tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        assertStoryHeaderHidden(app)
        evidence(app, name: "Floating identity — original profile without story accessory")
        back.tap()

        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Half screen", app: app)
        assertSharedHeader(app)
        evidence(app, name: "Profile returns — floating identity and exact story restored")
    }

    @MainActor
    func testPositionRemainsStaticAfterReturningFromProfileUntilManualSwipe() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        XCTAssertEqual(pagePosition(app).count, 19)
        rewind(app)

        // Use the real position selector and original author profile.
        let expectedPage = "friend-story.page.reel:00000000-0000-0000-0000-000000009301"
        currentPage(app).coordinate(withNormalizedOffset: CGVector(dx: 13.5 / 19.0, dy: 0.5)).tap()
        app.buttons["friend-story.open-author"].tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        assertStoryHeaderHidden(app)

        // Neither time in the child nor time back on the card navigates.
        let profileLeftUnexpectedly = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: back
        )
        profileLeftUnexpectedly.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [profileLeftUnexpectedly], timeout: 7), .completed)
        back.tap()
        XCTAssertTrue(currentPage(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentPage(app).value as? String, "chengsi",
                       "The position indicator has no elapsed-time percentage")
        let unexpectedAdvance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "identifier != %@", expectedPage), object: currentPage(app)
        )
        unexpectedAdvance.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedAdvance], timeout: 8), .completed,
                       "A compact photo stays selected beyond the old countdown")
        XCTAssertEqual(pagePosition(app).index, 13)
        swipeCard(to: 14, app: app)
        XCTAssertEqual(pagePosition(app).index, 14)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        evidence(app, name: "Static position after profile — only the manual card swipe changes posts")
    }

    @MainActor
    func testPersonBarDoesNotSwipeAndLowerCardsCrossPeopleWithMapFlight() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        // Exercise the original expanded layout as well as compact paging.
        expandStoryForReading(app)
        selectPage(17, app: app)
        let ownPage = currentPage(app).identifier
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")

        for useProgressStrip in [true, false] {
            let bar = useProgressStrip ? currentPage(app) : authorNavigation(app)
            let frame = bar.frame
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)).press(
                forDuration: 0.05,
                thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
            )
            XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
            XCTAssertEqual(currentPage(app).identifier, ownPage)
            XCTAssertEqual(bar.frame.minX, frame.minX, accuracy: 2)
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).press(
                forDuration: 0.05,
                thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5))
            )
            XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
            XCTAssertEqual(currentPage(app).identifier, ownPage)
            XCTAssertEqual(bar.frame.minX, frame.minX, accuracy: 2)
        }
        swipeCard(to: 18, app: app)
        let lastOwnPage = currentPage(app).identifier
        let nairobi = CameraCenter(latitude: -1.2921, longitude: 36.8219)
        waitForCamera(near: nairobi, app: app)
        dragCardForward(true, app: app)
        waitForAuthorChange(from: "chengsi", app: app)
        let nextAuthor = try XCTUnwrap(currentAuthor(app).value as? String)
        XCTAssertEqual(pagePosition(app).index, 0, "Crossing the last card shows the next person's FIRST post")
        waitForCameraDeparture(from: nairobi, app: app)
        waitForDetent("Expanded", app: app)
        evidence(app, name: "Last lower card swipes into next person's first card and flies")

        dragCardForward(false, app: app)
        waitForAuthorChange(from: nextAuthor, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        XCTAssertEqual(currentPage(app).identifier, lastOwnPage)
        XCTAssertEqual(pagePosition(app).index, 18, "Reversing returns to the previous person's LAST post")
        waitForCamera(near: nairobi, app: app)
        swipeCard(to: 17, app: app)
        XCTAssertEqual(currentPage(app).identifier, ownPage)
        evidence(app, name: "Reverse lower-card swipe returns to own last post without remounting the sheet")
    }

    @MainActor
    func testCompactLastCardSwipesIntoNextPersonWithoutExpanding() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        selectPage(pagePosition(app).count - 1, app: app)
        dragCardForward(true, app: app)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "chengsi"), object: currentAuthor(app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed,
                       "The compact card swipe changes person immediately")
        XCTAssertEqual(pagePosition(app).index, 0)
        waitForDetent("Half screen", app: app)
        evidence(app, name: "Compact last card crosses person boundary without expanding")
    }

    @MainActor
    func testLastUpdateStaysUntilManualSwipeThenChangesPersonAndFlies() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        let position = pagePosition(app)
        XCTAssertEqual(position.count, 19)
        selectPage(position.count - 1, app: app)
        XCTAssertEqual(currentPage(app).identifier,
                       "friend-story.page.reel:00000000-0000-0000-0000-000000009122",
                       "The last public own update is Nairobi; private videos stay out of this feed")
        let nairobi = CameraCenter(latitude: -1.2921, longitude: 36.8219)
        waitForCamera(near: nairobi, app: app)
        let lastPage = currentPage(app).identifier
        let unexpectedAdvance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "identifier != %@", lastPage), object: currentPage(app)
        )
        unexpectedAdvance.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedAdvance], timeout: 8), .completed,
                       "The last post must not advance to another person on a timer")
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        XCTAssertEqual(currentPage(app).value as? String, "chengsi")
        waitForCamera(near: nairobi, app: app)
        dragCardForward(true, app: app)
        waitForAuthorChange(from: "chengsi", app: app)
        XCTAssertEqual(pagePosition(app).index, 0)
        waitForCameraDeparture(from: nairobi, app: app)
        waitForDetent("Half screen", app: app)
        evidence(app, name: "Last update stays put — manual card swipe changes person and flies")
    }

    @MainActor
    func testExpandedPhotoPreviewAndCardPagingKeepTheirOriginalInteraction() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        expandStoryForReading(app)
        selectPage(13, app: app)
        let pageID = currentPage(app).identifier
        let photo = app.buttons["experience.real.photo.00000000-0000-0000-0000-000000009301.00000000-0000-0000-0000-000000009302"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let close = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let unexpectedDismissal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close
        )
        unexpectedDismissal.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedDismissal], timeout: 7), .completed)
        close.tap()
        waitForDetent("Expanded", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertTrue(photo.isHittable)
        swipeCard(to: 14, app: app)
        waitForCamera(near: .init(latitude: 46.065, longitude: -118.343), app: app)
        swipeCard(to: 13, app: app)
        waitForCamera(near: .init(latitude: 21.2866, longitude: -157.8399), app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        evidence(app, name: "Photo preview and lower-card paging remain unchanged")
    }

    @MainActor
    private func expandStoryForReading(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        )
        waitForDetent("Expanded", app: app)
    }

    @MainActor
    func testNotificationsRemainIsolatedFromPersonStoryNavigation() throws {
        let app = launchDemo()
        defer { app.terminate() }
        let activity = app.buttons["maptalk.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 8))
        activity.tap()
        let list = app.descendants(matching: .any)["maptalk.activity.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "maptalk.activity.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let close = app.buttons["maptalk.activity.detail.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(currentPage(app).exists)
        XCTAssertFalse(storyNavigation(app).exists)
        close.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(storyNavigation(app).exists)
    }

    @MainActor
    func testOriginalReelPhotoAndBubbleReturnToExactStory() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        rewind(app)
        let reelID = "00000000-0000-0000-0000-000000009301"
        let expectedPage = "friend-story.page.reel:\(reelID)"
        // The current demo fixture places Waikiki at update 14 of 19. Use the
        // real progress selector directly, retaining discovery if seeds change.
        if pagePosition(app).count == 19 {
            selectPage(13, app: app)
        }
        if currentPage(app).identifier != expectedPage {
            rewind(app)
            for _ in 0..<90 {
                if currentPage(app).identifier == expectedPage { break }
                XCTAssertTrue(advancePage(app), "The existing demo author must retain the Waikiki Reel")
            }
        }
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        let author = currentAuthor(app).value as? String
        XCTAssertEqual(author, "chengsi", "The regression must exercise the current user's own stories")
        let ownPageIndex = pagePosition(app).index
        XCTAssertGreaterThan(ownPageIndex, 0)
        XCTAssertLessThan(ownPageIndex + 1, pagePosition(app).count)
        let waikiki = CameraCenter(latitude: 21.2866, longitude: -157.8399)
        waitForCamera(near: waikiki, app: app)
        let selectedReelMarker = app.descendants(matching: .any)["maptalk.marker.reel.\(reelID)"].firstMatch
        XCTAssertTrue(selectedReelMarker.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedReelMarker.value as? String, "Avatar, selected",
                       "Public-map Reels retain their author's avatar, including the current user's own posts")
        swipeCard(to: ownPageIndex + 1, app: app)
        XCTAssertEqual(currentPage(app).identifier, "friend-story.page.reel:00000000-0000-0000-0000-000000009101",
                       "The adjacent published demo post is Walla Walla, far from the starting Hawaii post")
        XCTAssertEqual(currentAuthor(app).value as? String, author,
                       "The current user's own updates must participate in ordinary horizontal paging")
        waitForDetent("Half screen", app: app)
        waitForCamera(near: .init(latitude: 46.065, longitude: -118.343), app: app)
        swipeCard(to: ownPageIndex, app: app)
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        waitForDetent("Half screen", app: app)
        waitForCamera(near: waikiki, app: app)
        evidence(app, name: "Own stories — horizontal next and previous return to exact Reel")
        let likes = app.descendants(matching: .any)["experience.real.likes.\(reelID)"].firstMatch
        assertSharedHeader(app)
        assertOriginalReelIdentity(reelID, app: app)
        XCTAssertTrue(likes.waitForExistence(timeout: 5))
        XCTAssertTrue(likes.isHittable, "The original engagement footer must remain visible before expanding")
        XCTAssertLessThanOrEqual(likes.frame.maxY, app.frame.maxY - 24,
                                 "The entire compact footer must fit above the bottom safe area")
        let photo = app.buttons["experience.real.photo.\(reelID).00000000-0000-0000-0000-000000009302"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let avatar = app.descendants(matching: .any)["experience.real.avatar.\(reelID)"].firstMatch
        XCTAssertGreaterThanOrEqual(photo.frame.minX - avatar.frame.maxX, 6,
                                    "The original compact Reel keeps its media to the right of the avatar column")
        evidence(app, name: "Floating navigation — original compact Reel photo and Bubble")

        // A thumbnail opens its own preview; it must not also expand and
        // replace the compact card that owns that preview. Repeat to catch
        // stale presentation state on the second opening.
        let compactPhotoFrame = photo.frame
        for _ in 0..<2 {
            photo.tap()
            let close = app.buttons["experience.media-lightbox.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close
            )
            dismissed.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 2), .completed)
            assertStoryHeaderHidden(app)
            close.tap()
            waitForDetent("Half screen", app: app)
            XCTAssertTrue(photo.isHittable)
            XCTAssertEqual(photo.frame.minY, compactPhotoFrame.minY, accuracy: 4)
            XCTAssertEqual(currentPage(app).identifier, expectedPage)
            XCTAssertEqual(currentAuthor(app).value as? String, author)
            assertSharedHeader(app)
        }
        evidence(app, name: "Compact story Reel — photo returns without expanding or changing the page")

        // Use the ordinary native grabber, not a test-only expansion hook.
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        )
        waitForDetent("Expanded", app: app)
        swipeCard(to: ownPageIndex - 1, app: app)
        XCTAssertTrue(currentPage(app).identifier.hasPrefix("friend-story.page.poi:00000000-0000-0000-0000-000000006006:"),
                      "The previous demo slice belongs to the Vancouver night-market visit")
        waitForDetent("Expanded", app: app)
        waitForCamera(near: .init(latitude: 45.638, longitude: -122.661), app: app)
        swipeCard(to: ownPageIndex, app: app)
        waitForDetent("Expanded", app: app)
        waitForCamera(near: waikiki, app: app)
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertSharedHeader(app)
        assertOriginalReelIdentity(reelID, app: app)
        let caption = app.staticTexts["experience.real.caption.\(reelID)"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable)
        XCTAssertGreaterThanOrEqual(photo.frame.minX - avatar.frame.maxX, 6,
                                    "Expanded media retains the original Reel's avatar-column layout")

        XCTAssertTrue(avatar.isHittable, "The original Reel author avatar must remain interactive")
        avatar.tap()
        let closeProfile = app.buttons["Back"].firstMatch
        XCTAssertTrue(closeProfile.waitForExistence(timeout: 5))
        assertStoryHeaderHidden(app)
        evidence(app, name: "Original Reel avatar — original profile presentation")
        closeProfile.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)
        assertSharedHeader(app)
        assertOriginalReelIdentity(reelID, app: app)
        let photoRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: photo
        )
        let restored = XCTWaiter.wait(for: [photoRestored], timeout: 5)
        if restored != .completed {
            let details = XCTAttachment(string: """
                Photo: \(photo.identifier)
                Matches: \(app.buttons.matching(identifier: photo.identifier).count)
                Exists: \(photo.exists), enabled: \(photo.isEnabled), hittable: \(photo.isHittable)
                Frame: \(photo.frame)
                \(photo.debugDescription)
                \(app.debugDescription)
                """)
            details.name = "Photo not interactive after profile return — element and app hierarchy"
            details.lifetime = .keepAlways
            add(details)
        }
        XCTAssertEqual(restored, .completed,
                       "Returning from the original profile must restore the visible photo's hit testing")
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        let closePhoto = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(closePhoto.waitForExistence(timeout: 5), "Original Reel photos must still use the original media viewer")
        XCTAssertFalse(currentPage(app).isHittable)
        assertStoryHeaderHidden(app)
        evidence(app, name: "Original Reel — original photo viewer")
        closePhoto.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)
        assertSharedHeader(app)

        let capsule = app.buttons["Journey memories"].firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if capsule.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.42))
            )
        }
        XCTAssertTrue(capsule.isHittable)
        capsule.tap()
        let back = app.buttons["maptalk.friend-story.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(caption.exists, "The Bubble must open its own memories, not the parent Reel")
        XCTAssertFalse(currentPage(app).isHittable)
        assertStoryHeaderHidden(app)
        evidence(app, name: "Person story — original attached Bubble")
        back.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Expanded", app: app)
        assertSharedHeader(app)
        assertOriginalReelIdentity(reelID, app: app)
        XCTAssertTrue(capsule.exists)
        evidence(app, name: "Photo and Bubble — exact original Reel restored")

        // Only crossing the last original card changes people, with the same
        // live map movement as a normal lower-card page change.
        selectPage(pagePosition(app).count - 1, app: app)
        let nairobi = CameraCenter(latitude: -1.2921, longitude: 36.8219)
        waitForCamera(near: nairobi, app: app)
        dragCardForward(true, app: app)
        waitForAuthorChange(from: author ?? "", app: app)
        waitForCameraDeparture(from: nairobi, app: app)
        evidence(app, name: "Lower-card author boundary — actual map camera follows the next person")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func revealAuthor(_ id: String, app: XCUIApplication) -> XCUIElement {
        let rail = app.descendants(matching: .any)["maptalk.friend-story.rail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 8))
        let author = app.buttons["friend-story.author.\(id)"]
        for _ in 0..<24 {
            if author.isHittable { break }
            rail.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)).press(
                forDuration: 0.05,
                thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
            )
        }
        XCTAssertTrue(author.isHittable, "Expected an existing demo author in the person rail")
        return author
    }

    @MainActor
    private func currentAuthor(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["friend-story.open-author"]
    }

    @MainActor
    private func currentPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend-story.page.")).firstMatch
    }

    @MainActor
    private func storyNavigation(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["friend-story.navigation"].firstMatch
    }

    @MainActor
    private func authorNavigation(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["friend-story.author-navigation"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        return row
    }

    @MainActor
    private func rewind(_ app: XCUIApplication) {
        selectPage(0, app: app)
        XCTAssertEqual(pagePosition(app).index, 0)
    }

    @MainActor
    private func findPlacePage(_ app: XCUIApplication) {
        for _ in 0..<90 {
            if currentPage(app).identifier.hasPrefix("friend-story.page.poi:") { break }
            XCTAssertTrue(advancePage(app), "The seeded author should have a POI slice")
        }
        XCTAssertTrue(poiCard(app).waitForExistence(timeout: 3))
    }

    @MainActor
    private func poiCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["experience.poi.collapsed", "experience.poi.expanded"]
        )).firstMatch
    }

    private func poiMediaID(from pageID: String) -> String? {
        guard pageID.hasPrefix("friend-story.page.poi:"),
              let last = pageID.split(separator: ":").last,
              let mediaID = UUID(uuidString: String(last)) else { return nil }
        return mediaID.uuidString
    }

    @MainActor
    private func assertOriginalPOICard(_ app: XCUIApplication, expanded: Bool) {
        let mode = expanded ? "expanded" : "collapsed"
        let originalCard = app.descendants(matching: .any)["experience.poi.\(mode)"].firstMatch
        let exists = originalCard.waitForExistence(timeout: 3)
        if !exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Missing original POI \(mode) — accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(exists,
                      "Friend stories must use the original \(mode) POI card")
        XCTAssertFalse(app.descendants(matching: .any)["friend-story.poi-stage"].firstMatch.exists,
                       "The replacement media-stage design must not return")
        XCTAssertFalse(app.buttons["friend-story.open-place"].exists,
                       "The replacement bottom place bar must not return")
    }

    @MainActor
    private func assertCurrentPOIMedia(_ mediaID: String, app: XCUIApplication) {
        XCTAssertTrue(app.buttons["experience.poi-story.close"].waitForExistence(timeout: 5),
                      "POI avatars retain the original story viewer")
        XCTAssertTrue(app.descendants(matching: .any)["experience.poi-story.media.\(mediaID)"].firstMatch.waitForExistence(timeout: 5),
                      "The original viewer must open the exact media slice selected by the floating bar")
        assertStoryHeaderHidden(app)
    }

    @MainActor
    private func pagePosition(_ app: XCUIApplication) -> (index: Int, count: Int) {
        let page = currentPage(app)
        XCTAssertTrue(page.waitForExistence(timeout: 3), "The progress strip exposes the current update")
        let words = page.label.split(separator: " ")
        guard words.count == 4, words[0] == "Update", words[2] == "of",
              let number = Int(words[1]), let count = Int(words[3]),
              count > 0, (1...count).contains(number) else {
            XCTFail("Expected the progress label 'Update N of M', got '\(page.label)'")
            return (0, 1)
        }
        return (number - 1, count)
    }

    @MainActor
    private func advancePage(_ app: XCUIApplication) -> Bool {
        let position = pagePosition(app)
        guard position.index + 1 < position.count else { return false }
        selectPage(position.index + 1, app: app)
        return true
    }

    @MainActor
    private func swipeCard(to index: Int, app: XCUIApplication) {
        let position = pagePosition(app)
        guard (0..<position.count).contains(index), abs(index - position.index) == 1 else {
            XCTFail("A card swipe must target one adjacent update, got \(position.index) → \(index)")
            return
        }
        let oldID = currentPage(app).identifier
        let author = currentAuthor(app).value as? String
        dragCardForward(index > position.index, app: app)
        waitForPageChange(from: oldID, app: app)
        XCTAssertEqual(pagePosition(app).index, index, "A card swipe changes exactly one update")
        XCTAssertEqual(currentAuthor(app).value as? String, author,
                       "Interior pages stay within the selected person's stories")
    }

    @MainActor
    private func dragCardForward(_ next: Bool, app: XCUIApplication) {
        let card = storyCard(app)
        XCTAssertTrue(card.isHittable)
        // The original card's title/blank header area belongs to the outer
        // pager. Do not commandeer a photo, video or Bubble's local gestures.
        card.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.84 : 0.16, dy: 0.15)).press(
            forDuration: 0.05,
            thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.16 : 0.84, dy: 0.15))
        )
    }

    @MainActor
    private func selectPage(_ index: Int, app: XCUIApplication) {
        let page = currentPage(app)
        XCTAssertTrue(page.waitForExistence(timeout: 3), "The visible progress must expose the current update")
        let position = pagePosition(app)
        guard (0..<position.count).contains(index) else {
            XCTFail("Cannot select update \(index + 1) of \(position.count)")
            return
        }
        guard position.index != index else { return }
        let oldID = page.identifier
        XCTAssertTrue(page.isHittable, "The visible progress strip must be directly tappable")
        page.coordinate(withNormalizedOffset: CGVector(
            dx: (CGFloat(index) + 0.5) / CGFloat(position.count), dy: 0.5
        )).tap()
        waitForPageChange(from: oldID, app: app)
        XCTAssertEqual(pagePosition(app).index, index, "The tapped segment selects that exact update")
    }

    @MainActor
    private func assertSharedHeader(_ app: XCUIApplication) {
        let navigation = storyNavigation(app)
        XCTAssertTrue(navigation.waitForExistence(timeout: 3))
        let card = storyCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(card.frame.minY - navigation.frame.maxY, 8,
                                    "The author identity must float above the content card, with actual map space between them")
        let headerHeight = navigation.frame.height
        let progressHeight = currentPage(app).frame.height
        // Native compact sheets can scale the whole surface slightly. Keep
        // checking the authored 44 + 24 layout without mistaking that uniform
        // presentation transform for content clipping or a different header.
        XCTAssertGreaterThanOrEqual(headerHeight, 64)
        XCTAssertLessThanOrEqual(headerHeight, 69)
        XCTAssertGreaterThanOrEqual(progressHeight, 22)
        XCTAssertLessThanOrEqual(progressHeight, 25)
        XCTAssertEqual(headerHeight / max(progressHeight, 1), 68.0 / 24.0, accuracy: 0.04,
                       "POI and Reel retain the same author-to-progress proportions under native sheet scaling")
        if card.value as? String == "Expanded" {
            XCTAssertEqual(headerHeight, 68, accuracy: 1,
                           "Expanded stories retain the original fixed-height shared header")
            XCTAssertEqual(progressHeight, 24, accuracy: 1,
                           "The expanded selector retains its bounded 24 pt tap strip")
        }
        let profile = app.buttons["friend-story.open-author"]
        XCTAssertEqual(app.buttons.matching(identifier: "friend-story.open-author").count, 1,
                       "There is exactly one floating author-navigation control")
        XCTAssertTrue(profile.isHittable)
        let timestamp = app.descendants(matching: .any)["friend-story.timestamp"].firstMatch
        XCTAssertTrue(timestamp.exists, "The navigation bar identifies the current update without replacing the card's own timestamp")
        XCTAssertGreaterThanOrEqual(profile.frame.minY, navigation.frame.minY - 1)
        XCTAssertLessThanOrEqual(profile.frame.maxY, navigation.frame.maxY + 1)
        XCTAssertEqual(navigation.images.matching(identifier: "chevron.left").count, 0)
        XCTAssertEqual(navigation.images.matching(identifier: "chevron.right").count, 0)
        XCTAssertFalse(app.buttons["friend-story.previous-page"].exists)
        XCTAssertFalse(app.buttons["friend-story.next-page"].exists)
        XCTAssertFalse(app.buttons["friend-story.close"].exists,
                       "The existing floating identity stays minimal; downward dismissal remains the exit")
    }

    @MainActor
    private func assertStoryHeaderHidden(_ app: XCUIApplication) {
        let profile = app.buttons["friend-story.open-author"]
        let page = currentPage(app)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (!profile.exists || !profile.isHittable) && (!page.exists || !page.isHittable)
        }, object: profile)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "Nested content must not expose the parent story's floating identity or progress controls")
    }

    @MainActor
    private func storyCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["friend-story.card"].firstMatch
    }

    @MainActor
    private func assertOriginalReelIdentity(_ reelID: String, app: XCUIApplication) {
        for field in ["avatar", "author", "timestamp"] {
            XCTAssertTrue(app.descendants(matching: .any)["experience.real.\(field).\(reelID)"].firstMatch.exists,
                          "The original Reel card must retain its own \(field) beneath the independent floating navigation")
        }
    }

    @MainActor
    private func waitForPageChange(from oldID: String, app: XCUIApplication) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "identifier != %@", oldID), object: currentPage(app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "A navigation tap must advance the update")
    }

    @MainActor
    private func waitForAuthorChange(from handle: String, app: XCUIApplication) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", handle), object: currentAuthor(app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    @MainActor
    private func waitForDetent(_ value: String, app: XCUIApplication) {
        let card = storyCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let expectedValue = value == "Half screen" ? "Compact" : value
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expectedValue), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private struct CameraCenter {
        let latitude: Double
        let longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init?(value: Any?) {
            guard let value = value as? String else { return nil }
            let components = value.split(separator: ",")
            guard components.count == 2,
                  let latitude = Double(components[0]),
                  let longitude = Double(components[1]),
                  latitude.isFinite, longitude.isFinite else { return nil }
            self.init(latitude: latitude, longitude: longitude)
        }

        func isNear(_ expected: Self, tolerance: Double) -> Bool {
            abs(latitude - expected.latitude) <= tolerance
                && abs(longitude - expected.longitude) <= tolerance
        }
    }

    @MainActor
    private func waitForCamera(near expected: CameraCenter, app: XCUIApplication) {
        let canvas = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3),
                      "The existing map canvas must expose its actual settled camera while a story is open")
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            CameraCenter(value: canvas.value)?.isNear(expected, tolerance: 0.08) == true
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 8), .completed,
                       "The actual MapKit camera must reach the selected fixture's location; the tolerance allows card-occlusion framing")
    }

    @MainActor
    private func waitForCameraDeparture(from previous: CameraCenter, app: XCUIApplication) {
        let canvas = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = CameraCenter(value: canvas.value) else { return false }
            return !current.isNear(previous, tolerance: 0.15)
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 8), .completed,
                       "Switching people must move the actual map camera, not only the selected page")
    }

    @MainActor
    private func waitUntilAbsent(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func evidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

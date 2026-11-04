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
        // This checks the existing demo place projection, not a server history
        // fetch. Expansion keeps the original POI page, overlays its heading
        // and counters on this visit's media, and keeps visitors below it.
        for _ in 0..<pagePosition(app).count {
            if poiMediaID(from: currentPage(app).identifier) != nil { break }
            XCTAssertTrue(advancePage(app), "The demo author must have a POI media update")
        }
        let pageID = currentPage(app).identifier
        let mediaID = try XCTUnwrap(poiMediaID(from: pageID))
        let author = currentAuthor(app).value as? String
        let authorID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: false)
        let media = app.buttons["friend-story.poi.media.\(mediaID)"]
        XCTAssertTrue(media.isHittable)
        evidence(app, name: "POI compact — full-card media and non-button place name")
        media.tap()
        let close = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The media opens the existing lightbox directly")
        assertStoryHeaderHidden(app)
        evidence(app, name: "POI media — existing lightbox")
        close.tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Half screen", app: app)
        XCTAssertTrue(media.isHittable)

        expandStoryForReading(app)
        XCTAssertEqual(currentPage(app).identifier, pageID,
                       "Native expansion keeps the exact story page selected")
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertOriginalPOICard(app, expanded: true)
        assertSharedHeader(app)
        let heading = app.descendants(matching: .any)["experience.poi.expanded.heading"].firstMatch
        let featuredMedia = app.buttons["experience.poi.featured-media.\(mediaID)"]
        XCTAssertTrue(heading.waitForExistence(timeout: 3))
        XCTAssertFalse(heading.frame.intersection(app.frame).isEmpty,
                       "The original place heading remains visible over the media")
        XCTAssertTrue(featuredMedia.waitForExistence(timeout: 3))
        XCTAssertTrue(featuredMedia.isHittable, "The selected visit is visible immediately inside the POI page")
        // Expanded photos and videos share one full-width portrait viewport;
        // downloading or decoding media must not resize the place page.
        let portraitLayout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            featuredMedia.exists && featuredMedia.frame.width > 0 &&
                abs(featuredMedia.frame.height - featuredMedia.frame.width * 16 / 9) < 2
        }, object: featuredMedia)
        XCTAssertEqual(XCTWaiter.wait(for: [portraitLayout], timeout: 3), .completed,
                       "The expanded media uses a stable portrait viewport, not a provisional square")
        assertOverlayFrame(heading.frame, inside: featuredMedia.frame,
                           "The original place heading overlays the media, not a separate row")
        XCTAssertLessThan(heading.frame.maxY, featuredMedia.frame.midY,
                          "The place heading belongs at the top of the media")
        let stats = app.descendants(matching: .any)["experience.poi.expanded.stats"].firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 3))
        assertOverlayFrame(stats.frame, inside: featuredMedia.frame,
                           "The activity counters overlay the media, not a separate row")
        XCTAssertGreaterThan(stats.frame.minY, featuredMedia.frame.midY,
                             "Activity counters belong at the bottom of the media")
        XCTAssertEqual(featuredMedia.frame.width, storyCard(app).frame.width, accuracy: 2,
                       "The media viewport spans the expanded card width")
        XCTAssertEqual(featuredMedia.frame.height, featuredMedia.frame.width * 16 / 9, accuracy: 2,
                       "Photos and videos share the same portrait stage; place history follows below")
        evidence(app, name: "POI expanded — selected media inside the original place page")
        let otherVisitor = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@",
            "experience.poi.footprint.", "experience.poi.footprint.\(authorID)"
        )).firstMatch
        for _ in 0..<4 {
            if otherVisitor.isHittable { break }
            storyCard(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).press(
                forDuration: 0.05,
                thenDragTo: storyCard(app).coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
            )
        }
        XCTAssertTrue(otherVisitor.isHittable,
                      "Other visitors remain reachable below the selected media in the original place scroll")
        XCTAssertGreaterThanOrEqual(otherVisitor.frame.minY, featuredMedia.frame.maxY - 2,
                                    "Visitor history follows below the media instead of covering it")
        XCTAssertFalse(app.buttons["maptalk.friend-story.back"].exists,
                       "Expanding the same sheet must not push a separate place route")
        evidence(app, name: "POI expanded — original visitors below the selected media")

        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Half screen", app: app)
        XCTAssertEqual(currentPage(app).identifier, pageID)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: false)
        XCTAssertTrue(media.isHittable)
        evidence(app, name: "POI collapsed — exact original story media restored")
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
        expandStoryForReading(app)
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
        selectPage(13, app: app)
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
    func testSamePlacePagesShareOneStopAndCanReturnFromAnotherStop() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))

        // The existing night-market visit has three media slices. Their
        // grouping uses the same production projection as repeated visits.
        selectPage(12, app: app)
        XCTAssertTrue(currentPage(app).identifier.hasPrefix(
            "friend-story.page.poi:00000000-0000-0000-0000-000000006006:"
        ))
        let stop = stopPosition(app)
        selectStop(stop.index, app: app)
        let firstPage = currentPage(app).identifier
        let firstIndex = pagePosition(app).index
        let firstItem = try XCTUnwrap(momentPosition(app))
        let author = currentAuthor(app).value as? String
        XCTAssertEqual(author, "chengsi")
        XCTAssertEqual(firstItem.index, 0)
        XCTAssertEqual(firstItem.count, 3)
        XCTAssertLessThan(stop.count, pagePosition(app).count,
                          "Several media pages at the same place share one top-level stop")
        let compactHeading = app.descendants(matching: .any)["friend-story.poi.place-name"].firstMatch
        let compactStats = app.descendants(matching: .any)["friend-story.poi.stats"].firstMatch
        XCTAssertTrue(compactHeading.isHittable)
        let compactHeadingFrame = compactHeading.frame
        let compactStatsFrame = compactStats.frame
        let compactCardFrame = storyCard(app).frame
        evidence(app, name: "Same place — one stop with three original media pages")

        swipeCard(to: firstIndex + 1, app: app)
        let secondPage = currentPage(app).identifier
        XCTAssertNotEqual(secondPage, firstPage)
        XCTAssertEqual(stopPosition(app).index, stop.index,
                       "Paging inside a place does not advance its top-level progress segment")
        XCTAssertEqual(stopPosition(app).count, stop.count)
        XCTAssertEqual(momentPosition(app)?.index, 1)
        XCTAssertEqual(momentPosition(app)?.count, 3)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        assertFrame(compactHeading.frame, matches: compactHeadingFrame,
                    "Same-place media paging keeps the compact place heading fixed")
        assertFrame(compactStats.frame, matches: compactStatsFrame,
                    "Same-place media paging keeps the compact activity counters fixed")
        assertFrame(storyCard(app).frame, matches: compactCardFrame,
                    "Same-place media paging does not move or resize the card shell")

        // Reverse repeatedly after a progress-bar jump. A late native pager
        // callback must not snap a later slice back to this stop's first page.
        for _ in 0..<2 {
            swipeCard(to: firstIndex + 2, app: app)
            XCTAssertEqual(momentPosition(app)?.index, 2)
            swipeCard(to: firstIndex + 1, app: app)
            XCTAssertEqual(currentPage(app).identifier, secondPage)
            assertVisiblePOIMediaMatchesPage(secondPage, app: app)
            swipeCard(to: firstIndex, app: app)
            XCTAssertEqual(currentPage(app).identifier, firstPage)
            assertVisiblePOIMediaMatchesPage(firstPage, app: app)
            swipeCard(to: firstIndex + 1, app: app)
            XCTAssertEqual(currentPage(app).identifier, secondPage)
            assertVisiblePOIMediaMatchesPage(secondPage, app: app)
        }

        expandStoryForReading(app)
        XCTAssertEqual(currentPage(app).identifier, secondPage)
        let expandedHeading = app.descendants(matching: .any)["experience.poi.expanded.heading"].firstMatch
        XCTAssertTrue(expandedHeading.waitForExistence(timeout: 3))
        XCTAssertFalse(expandedHeading.frame.intersection(app.frame).isEmpty)
        let expandedHeadingFrame = expandedHeading.frame
        let expandedCardFrame = storyCard(app).frame
        swipeCard(to: firstIndex + 2, app: app)
        XCTAssertEqual(momentPosition(app)?.index, 2)
        XCTAssertEqual(stopPosition(app).index, stop.index)
        assertFrame(expandedHeading.frame, matches: expandedHeadingFrame,
                    "The expanded POI heading stays outside its media pager")
        assertFrame(storyCard(app).frame, matches: expandedCardFrame,
                    "The expanded place remains the same sheet while its media changes")
        swipeCard(to: firstIndex + 1, app: app)
        XCTAssertEqual(currentPage(app).identifier, secondPage)
        assertFrame(expandedHeading.frame, matches: expandedHeadingFrame,
                    "Reversing a same-place swipe preserves the original heading position")
        let secondMediaID = try XCTUnwrap(poiMediaID(from: secondPage))
        let featuredMedia = app.buttons["experience.poi.featured-media.\(secondMediaID)"]
        XCTAssertTrue(featuredMedia.isHittable)
        visibleMediaCenter(featuredMedia, app: app).tap()
        let closeMedia = app.buttons["experience.media-lightbox.close"]
        XCTAssertTrue(closeMedia.waitForExistence(timeout: 5))
        closeMedia.tap()
        waitForDetent("Expanded", app: app)
        XCTAssertEqual(currentPage(app).identifier, secondPage,
                       "Closing the selected media returns to the same slice, not the first one")
        XCTAssertEqual(momentPosition(app)?.index, 1)
        assertFrame(expandedHeading.frame, matches: expandedHeadingFrame,
                    "Opening and closing media leaves the fixed place shell intact")
        evidence(app, name: "Same place expanded — only media pages, heading and shell stay fixed")

        let grabber = app.buttons["Sheet Grabber"].firstMatch
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.08,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        waitForDetent("Half screen", app: app)
        XCTAssertEqual(currentPage(app).identifier, secondPage)
        assertFrame(compactHeading.frame, matches: compactHeadingFrame,
                    "Collapsing returns to the unchanged compact place heading")

        XCTAssertLessThan(stop.index + 1, stop.count)
        selectStop(stop.index + 1, app: app)
        XCTAssertNotEqual(currentPage(app).identifier, secondPage)
        XCTAssertEqual(stopPosition(app).index, stop.index + 1)
        XCTAssertEqual(currentAuthor(app).value as? String, author,
                       "Tapping another stop must not change people")
        selectStop(stop.index, app: app)
        XCTAssertEqual(currentPage(app).identifier, firstPage,
                       "Selecting the grouped stop again opens its first original page")
        XCTAssertEqual(momentPosition(app)?.index, 0)
        swipeCard(to: firstIndex + 1, app: app)
        XCTAssertEqual(currentPage(app).identifier, secondPage)
        XCTAssertEqual(currentAuthor(app).value as? String, author)
        waitForDetent("Half screen", app: app)
        evidence(app, name: "Same place — independent page swipe and exact stop re-entry")
    }

    @MainActor
    func testRapidCompactPOISwipesAndAuthorBoundaryReturnKeepSelection() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        try exerciseRapidPOISwipes(app, expanded: false)

        selectPage(pagePosition(app).count - 1, app: app)
        let lastPage = currentPage(app).identifier
        let lastIndex = pagePosition(app).index
        fastCardSwipeBurst([true], app: app)
        waitForAuthorChange(from: "chengsi", app: app)
        let nextAuthor = try XCTUnwrap(currentAuthor(app).value as? String)
        XCTAssertEqual(pagePosition(app).index, 0)
        XCTAssertEqual(storyCard(app).value as? String, "Compact")
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)

        fastCardSwipeBurst([false], app: app)
        waitForAuthorChange(from: nextAuthor, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        XCTAssertEqual(currentPage(app).identifier, lastPage)
        XCTAssertEqual(pagePosition(app).index, lastIndex)
        let reelID = try XCTUnwrap(UUID(uuidString: String(lastPage.dropFirst("friend-story.page.reel:".count))))
        assertOriginalReelIdentity(reelID.uuidString, app: app)
        XCTAssertTrue(app.descendants(matching: .any)["experience.real.author.\(reelID.uuidString)"].firstMatch.isHittable)
        assertStorySelectionStays(pageID: lastPage, author: "chengsi", detent: "Compact", app: app)
        evidence(app, name: "Fast compact bursts and author-boundary reversal — exact visible selection")
    }

    @MainActor
    func testRapidExpandedPOISwipesAndReversalsKeepVisibleMediaAndDetent() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        try exerciseRapidPOISwipes(app, expanded: true)
        evidence(app, name: "Fast expanded POI bursts — visible media and header stay synchronized")
    }

    @MainActor
    private func exerciseRapidPOISwipes(_ app: XCUIApplication, expanded: Bool) throws {
        selectPage(12, app: app)
        XCTAssertTrue(currentPage(app).identifier.hasPrefix(
            "friend-story.page.poi:00000000-0000-0000-0000-000000006006:"
        ))
        let stop = stopPosition(app)
        selectStop(stop.index, app: app)
        let firstIndex = pagePosition(app).index
        XCTAssertEqual(momentPosition(app)?.count, 3)
        if expanded { expandStoryForReading(app) }
        let detent = expanded ? "Expanded" : "Compact"
        var pages = [currentPage(app).identifier]
        // Record the actual fixture IDs through normal navigation, then begin
        // bursts at the first slice. Expected results never come from whatever
        // page the burst happened to leave selected.
        for offset in 1...2 {
            swipeCard(to: firstIndex + offset, app: app)
            pages.append(currentPage(app).identifier)
        }
        XCTAssertEqual(Set(pages).count, 3)
        selectStop(stop.index, app: app)
        assertVisiblePOIMediaMatchesPage(pages[0], app: app)
        let cardFrame = storyCard(app).frame

        let bursts: [(directions: [Bool], expectedItem: Int)] = [
            ([true, true], 2),
            ([false, false], 0),
            ([true, false, true, true, false], 1)
        ]
        for burst in bursts {
            fastCardSwipeBurst(burst.directions, app: app)
            let expected = pages[burst.expectedItem]
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "identifier == %@", expected), object: currentPage(app)
            )
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed,
                           "Each full-width fast drag must select exactly one adjacent media slice")
            XCTAssertEqual(pagePosition(app).index, firstIndex + burst.expectedItem)
            XCTAssertEqual(momentPosition(app)?.index, burst.expectedItem)
            XCTAssertEqual(momentPosition(app)?.count, 3)
            XCTAssertEqual(stopPosition(app).index, stop.index)
            XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
            XCTAssertEqual(currentPage(app).value as? String, "chengsi")
            XCTAssertEqual(storyCard(app).value as? String, detent)
            XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists,
                           "A fast media drag must never become a photo tap")
            assertVisiblePOIMediaMatchesPage(expected, app: app)
            assertFrame(storyCard(app).frame, matches: cardFrame,
                        "Repeated horizontal gestures must not move or resize the sheet")
        }
        assertSharedHeader(app)
        assertOriginalPOICard(app, expanded: expanded)
        assertStorySelectionStays(pageID: pages[1], author: "chengsi", detent: detent, app: app)
        assertVisiblePOIMediaMatchesPage(pages[1], app: app)
        XCTAssertEqual(pagePosition(app).index, firstIndex + 1)
        XCTAssertEqual(momentPosition(app)?.index, 1)
    }

    @MainActor
    func testExpandedPOIMediaPagingKeepsStableViewport() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))

        // Own Kirkland visit precedes the restaurant and location-only
        // footprint, not just the night-market stop. Select its first page.
        selectPage(7, app: app)
        XCTAssertTrue(currentPage(app).identifier.hasPrefix(
            "friend-story.page.poi:00000000-0000-0000-0000-000000006003:"
        ), "The regression must exercise the existing photo/video check-in, got \(currentPage(app).identifier)")
        XCTAssertEqual(momentPosition(app)?.count, 2)
        let firstIndex = pagePosition(app).index
        let originalStop = stopPosition(app).index
        expandStoryForReading(app)
        var baseline: (media: CGRect, heading: CGRect, stats: CGRect, card: CGRect)?

        func capture(_ label: String) throws {
            XCTAssertTrue(currentPage(app).identifier.hasPrefix(
                "friend-story.page.poi:00000000-0000-0000-0000-000000006003:"
            ), "Media paging must stay in the same original POI check-in")
            XCTAssertEqual(stopPosition(app).index, originalStop)
            let mediaID = try XCTUnwrap(poiMediaID(from: currentPage(app).identifier))
            let media = app.buttons["experience.poi.featured-media.\(mediaID)"]
            XCTAssertTrue(media.waitForExistence(timeout: 3))
            if let baseline {
                assertFrame(media.frame, matches: baseline.media,
                            "The newly selected media must immediately inherit the same viewport")
            }
            // Sample again after one bounded settling interval. This is a
            // layout regression, not a claim that remote video playback is ready.
            let sampleAfter = Date().addingTimeInterval(1)
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Date() >= sampleAfter
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 2), .completed)
            let heading = app.descendants(matching: .any)["experience.poi.expanded.heading"].firstMatch
            let stats = app.descendants(matching: .any)["experience.poi.expanded.stats"].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 3))
            XCTAssertTrue(stats.waitForExistence(timeout: 3))
            let hero = app.descendants(matching: .any)["experience.poi.expanded"].firstMatch
            let frame = media.frame
            XCTAssertEqual(frame.width, storyCard(app).frame.width, accuracy: 2,
                           "Expanded POI media spans the card width")
            XCTAssertEqual(frame.height, frame.width * 16 / 9, accuracy: 2,
                           "Photo/video decoding cannot replace the fixed portrait viewport")
            assertOverlayFrame(heading.frame, inside: frame,
                               "The fixed place heading stays inside the media viewport")
            XCTAssertLessThan(heading.frame.maxY, frame.midY,
                              "The place heading stays at the top of the media")
            assertOverlayFrame(stats.frame, inside: frame,
                               "The fixed activity counters stay inside the media viewport")
            XCTAssertGreaterThan(stats.frame.minY, frame.midY,
                                 "The activity counters stay at the bottom of the media")
            if let baseline {
                assertFrame(frame, matches: baseline.media,
                            "Swiping between photo and video must not resize or shift the media viewport")
                assertFrame(heading.frame, matches: baseline.heading,
                            "The place heading remains fixed while only its media changes")
                assertFrame(stats.frame, matches: baseline.stats,
                            "The overlaid activity counters remain fixed while only media changes")
                assertFrame(storyCard(app).frame, matches: baseline.card,
                            "The original card shell remains fixed across media pages")
            } else {
                baseline = (frame, heading.frame, stats.frame, storyCard(app).frame)
            }
            let report = """
                \(label)
                Layout sampled after a 1 s settling interval; playback readiness is not exposed.
                page=\(currentPage(app).identifier)
                media=\(frame), height/width=\(frame.height / max(frame.width, 1))
                heading=\(heading.frame)
                stats=\(stats.frame)
                card=\(storyCard(app).frame)
                Expanded POI hierarchy, including statistic positions where exposed:
                \(hero.debugDescription)
                """
            print(report)
            let attachment = XCTAttachment(string: report)
            attachment.name = "POI geometry — \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
            evidence(app, name: "POI geometry — \(label)")
        }

        try capture("Photo before paging")
        swipeCard(to: firstIndex + 1, app: app)
        try capture("Video after forward swipe")
        swipeCard(to: firstIndex, app: app)
        try capture("Photo after reverse swipe")
        swipeCard(to: firstIndex + 1, app: app)
        try capture("Video after second forward swipe")
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
    func testCompactIntercontinentalFlightVisualReplay() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        let canvas = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch

        func arrived(id: String, near center: CameraCenter, notBefore: Date) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Date() >= notBefore && self.currentPage(app).identifier == id
                    && CameraCenter(value: canvas.value)?.isNear(center, tolerance: 0.08) == true
            }, object: canvas)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            XCTAssertEqual(storyCard(app).value as? String, "Compact")
        }

        let nairobiID = "friend-story.page.reel:00000000-0000-0000-0000-000000009122"
        let spokaneID = "friend-story.page.reel:00000000-0000-0000-0000-000000000101"
        let nairobi = CameraCenter(latitude: -1.2921, longitude: 36.8219)
        let spokane = CameraCenter(latitude: 47.72, longitude: -117)
        selectPage(18, app: app)
        arrived(id: nairobiID, near: nairobi, notBefore: Date().addingTimeInterval(6))
        print("[GlobalFlightReplay] Nairobi -> Spokane at \(Date().timeIntervalSince1970)")
        // Center movement finishes before the zoom. Count from the completed
        // gesture, not before XCTest's element lookup and gesture synthesis.
        // Record the entire 5.2 s flight plus settling before reversing.
        swipeCard(to: 17, app: app)
        arrived(id: spokaneID, near: spokane, notBefore: Date().addingTimeInterval(6))
        evidence(app, name: "Intercontinental compact — Spokane arrival")
        print("[GlobalFlightReplay] Spokane -> Nairobi at \(Date().timeIntervalSince1970)")
        swipeCard(to: 18, app: app)
        arrived(id: nairobiID, near: nairobi, notBefore: Date().addingTimeInterval(6))
        evidence(app, name: "Intercontinental compact — Nairobi return")
    }

    @MainActor
    func testCompactIntercontinentalFastReversalsKeepLatestStoryAndLanding() throws {
        try verifyIntercontinentalReversals(delayBeforeLastSwipe: 0)
    }

    @MainActor
    func testCompactIntercontinentalPausedReversalKeepsLatestStoryAndLanding() throws {
        try verifyIntercontinentalReversals(delayBeforeLastSwipe: 3.2)
    }

    @MainActor
    private func verifyIntercontinentalReversals(delayBeforeLastSwipe: TimeInterval) throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        let canvas = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch
        let spokaneID = "friend-story.page.reel:00000000-0000-0000-0000-000000000101"
        let spokane = CameraCenter(latitude: 47.72, longitude: -117)

        func waitForSpokane(after notBefore: Date) {
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Date() >= notBefore
                    && self.currentPage(app).identifier == spokaneID
                    && self.currentAuthor(app).value as? String == "chengsi"
                    && self.storyCard(app).value as? String == "Compact"
                    && CameraCenter(value: canvas.value)?.isNear(spokane, tolerance: 0.08) == true
            }, object: canvas)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed,
                           "The final story and camera must settle on Spokane after the complete global flight")
        }

        selectPage(17, app: app)
        waitForSpokane(after: Date().addingTimeInterval(6))
        XCTAssertEqual(pagePosition(app).index, 17)
        // Start at 17: 18, 17, 18, 17. Never swipe forward from 18 into another
        // person. Cache-based gestures have no deliberate inter-swipe wait.
        fastCardSwipeBurst([true, false, true, false], app: app,
                          delayBeforeLastSwipe: delayBeforeLastSwipe)
        // Measure from the LAST completed gesture. A near-center coordinate
        // alone can appear before the 5.2-second zoom has finished landing.
        waitForSpokane(after: Date().addingTimeInterval(6))
        XCTAssertEqual(pagePosition(app).index, 17)
        XCTAssertEqual(currentPage(app).identifier, spokaneID)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        XCTAssertEqual(storyCard(app).value as? String, "Compact")
        XCTAssertTrue(CameraCenter(value: canvas.value)?.isNear(spokane, tolerance: 0.08) == true)
        assertStorySelectionStays(pageID: spokaneID, author: "chengsi", detent: "Compact", app: app)
        evidence(app, name: "Intercontinental fast reversal — final Spokane story and landing")
    }

    @MainActor
    func testCompactGlobalFlightVisualReplay() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))

        func settled(_ index: Int, id: String, near center: CameraCenter, label: String) {
            XCTAssertEqual(pagePosition(app).index, index)
            XCTAssertEqual(currentPage(app).identifier, id)
            waitForCamera(near: center, app: app)
            waitForDetent("Half screen", app: app)
            XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
            XCTAssertEqual(currentPage(app).identifier, id,
                           "The selected card must not revert while its global flight settles")
            XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)
            evidence(app, name: label)
        }

        let waikikiPage = "friend-story.page.reel:00000000-0000-0000-0000-000000009301"
        let waikiki = CameraCenter(latitude: 21.2866, longitude: -157.8399)
        selectPage(13, app: app)
        settled(13, id: waikikiPage, near: waikiki, label: "Global compact 1 — Waikiki departure")
        print("[GlobalFlightReplay] Waikiki -> Walla Walla")
        swipeCard(to: 14, app: app)
        settled(14, id: "friend-story.page.reel:00000000-0000-0000-0000-000000009101",
                near: .init(latitude: 46.065, longitude: -118.343),
                label: "Global compact 2 — Walla Walla arrival")
        print("[GlobalFlightReplay] Walla Walla -> Waikiki")
        swipeCard(to: 13, app: app)
        settled(13, id: waikikiPage, near: waikiki, label: "Global compact 3 — Waikiki reverse arrival")
        print("[GlobalFlightReplay] Waikiki -> Nairobi")
        selectPage(18, app: app)
        settled(18, id: "friend-story.page.reel:00000000-0000-0000-0000-000000009122",
                near: .init(latitude: -1.2921, longitude: 36.8219),
                label: "Global compact 4 — Nairobi arrival")
        print("[GlobalFlightReplay] Nairobi -> previous own update")
        swipeCard(to: 17, app: app)
        // The live mock feed's101 is Spokane; its older profile fixture uses
        // the same ID in Tacoma. Assert the source actually shown in this feed.
        settled(17, id: "friend-story.page.reel:00000000-0000-0000-0000-000000000101",
                near: .init(latitude: 47.72, longitude: -117.0),
                label: "Global compact 5 — exact previous own update restored")
    }

    @MainActor
    func testManualMapPanThenRegionalStoryFlightAndProfileReturnKeepCameraOwnership() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        // Existing early own POIs: Port Townsend -> Bellingham, about 74 km.
        // This exercises the native regional path, not a global hop or a
        // same-place media change (which intentionally does not fly).
        selectPage(6, app: app)
        XCTAssertTrue(currentPage(app).identifier.hasPrefix(
            "friend-story.page.poi:00000000-0000-0000-0000-000000006515:"
        ))
        let departurePage = currentPage(app).identifier
        let departure = CameraCenter(latitude: 48.117, longitude: -122.76)
        let destination = CameraCenter(latitude: 48.754, longitude: -122.478)
        waitForCamera(near: departure, app: app)
        let canvas = app.descendants(matching: .any)["maptalk.map-canvas"].firstMatch
        let beforePan = try XCTUnwrap(CameraCenter(value: canvas.value))
        let panStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.34))
        let panEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.34))

        print("[MapStoryPanProbe] phase=manual-pan-before-regional-flight")
        panStart.press(forDuration: 0.05, thenDragTo: panEnd,
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let camera = CameraCenter(value: canvas.value) else { return false }
            return !camera.isNear(beforePan, tolerance: 0.002)
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .completed,
                       "The exposed map must accept a genuine user pan while a story stays open")
        XCTAssertEqual(currentPage(app).identifier, departurePage)

        print("[MapStoryPanProbe] phase=regional-flight-after-user-pan")
        fastCardSwipeBurst([true], app: app)
        waitForPageChange(from: departurePage, app: app)
        let destinationPage = currentPage(app).identifier
        XCTAssertTrue(destinationPage.hasPrefix(
            "friend-story.page.poi:00000000-0000-0000-0000-000000006003:"
        ))
        XCTAssertEqual(pagePosition(app).index, 7)
        waitForCamera(near: destination, app: app)
        assertVisiblePOIMediaMatchesPage(destinationPage, app: app)

        print("[MapStoryPanProbe] phase=reverse-regional-flight-then-immediate-map-pan")
        fastCardSwipeBurst([false], app: app)
        // No intentional flight-arrival wait. XCTest may nevertheless idle
        // before injecting this public gesture; traces distinguish that case.
        panStart.press(forDuration: 0.05, thenDragTo: panEnd,
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        let interrupted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let camera = CameraCenter(value: canvas.value) else { return false }
            return abs(camera.longitude - departure.longitude) > 0.02
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [interrupted], timeout: 3), .completed,
                       "The manual pan must displace the regional flight's destination")
        let manuallyPositioned = try XCTUnwrap(CameraCenter(value: canvas.value))
        XCTAssertEqual(currentPage(app).identifier, departurePage)
        let snappedBack = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let camera = CameraCenter(value: canvas.value) else { return false }
            return abs(camera.longitude - departure.longitude) < 0.01
        }, object: canvas)
        snappedBack.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [snappedBack], timeout: 2), .completed,
                       "An interrupted flight must not reclaim the map after the user pans")

        print("[MapStoryPanProbe] phase=profile-open-return-after-manual-pan")
        app.buttons["friend-story.open-author"].tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(currentPage(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, departurePage)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            CameraCenter(value: canvas.value)?.isNear(manuallyPositioned, tolerance: 0.01) == true
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Profile return preserves the user's actual panned camera")

        print("[MapStoryPanProbe] phase=regional-flight-after-profile-return")
        fastCardSwipeBurst([true], app: app)
        waitForPageChange(from: departurePage, app: app)
        XCTAssertEqual(currentPage(app).identifier, destinationPage)
        waitForCamera(near: destination, app: app)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        waitForDetent("Half screen", app: app)
        assertVisiblePOIMediaMatchesPage(destinationPage, app: app)
        XCTAssertFalse(app.buttons["experience.media-lightbox.close"].exists)
        print("[MapStoryPanProbe] phase=complete")
    }

    @MainActor
    func testImmediateBubbleReturnAfterReelSwipeRestoresSelectedDestination() throws {
        let app = launchDemo()
        defer { app.terminate() }
        revealAuthor("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1", app: app).tap()
        XCTAssertTrue(storyNavigation(app).waitForExistence(timeout: 5))
        selectPage(14, app: app)
        waitForCamera(near: .init(latitude: 46.065, longitude: -118.343), app: app)

        // Open the existing Bubble as soon as the adjacent Honolulu card is
        // selected. Do not wait for its map arrival before entering the child.
        // XCTest may still idle automatically, so this is not a guaranteed
        // 250 ms interruption of the native flight.
        swipeCard(to: 13, app: app)
        let capsule = app.buttons["Journey memories"].firstMatch
        XCTAssertTrue(capsule.isHittable)
        capsule.tap()
        let back = app.buttons["maptalk.friend-story.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        let expectedPage = "friend-story.page.reel:00000000-0000-0000-0000-000000009301"
        XCTAssertTrue(currentPage(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentPage(app).identifier, expectedPage)
        XCTAssertEqual(pagePosition(app).index, 13)
        XCTAssertEqual(currentAuthor(app).value as? String, "chengsi")
        waitForDetent("Half screen", app: app)
        waitForCamera(near: .init(latitude: 21.2866, longitude: -157.8399), app: app)
        assertStorySelectionStays(pageID: expectedPage, author: "chengsi", detent: "Compact", app: app)
        evidence(app, name: "Immediate Bubble return — selected Honolulu Reel and destination restored")
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
        // The current demo fixture places Waikiki at update 14 of 19. Select
        // through the grouped progress and card pager, with a discovery fallback.
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
    private func launchDemo(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
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
            format: "identifier IN %@", ["friend-story.poi.preview", "experience.poi.collapsed", "experience.poi.expanded"]
        )).firstMatch
    }

    private func poiMediaID(from pageID: String) -> String? {
        guard pageID.hasPrefix("friend-story.page.poi:"),
              let last = pageID.split(separator: ":").last,
              let mediaID = UUID(uuidString: String(last)) else { return nil }
        return mediaID.uuidString
    }

    @MainActor
    private func assertVisiblePOIMediaMatchesPage(_ pageID: String, app: XCUIApplication) {
        guard let mediaID = poiMediaID(from: pageID) else {
            XCTFail("Expected a POI media page")
            return
        }
        let media = app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["friend-story.poi.media.\(mediaID)",
                                         "experience.poi.featured-media.\(mediaID)"]
        )).firstMatch
        XCTAssertTrue(media.isHittable, "The actual visible media must agree with the floating progress header")
        XCTAssertEqual(media.frame.midX, storyCard(app).frame.midX, accuracy: 2,
                       "An offscreen cached neighbor is not the selected page")
    }

    @MainActor
    private func assertOriginalPOICard(_ app: XCUIApplication, expanded: Bool) {
        if !expanded, let mediaID = poiMediaID(from: currentPage(app).identifier) {
            let preview = app.descendants(matching: .any)["friend-story.poi.preview"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 3))
            let media = app.buttons["friend-story.poi.media.\(mediaID)"]
            XCTAssertTrue(media.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(media.frame.width, preview.frame.width - 2,
                                        "The current media fills the compact POI preview's width")
            XCTAssertGreaterThanOrEqual(media.frame.height, preview.frame.height - 2,
                                        "The current media fills the compact POI preview's height")
            let heading = app.descendants(matching: .any)["friend-story.poi.place-name"].firstMatch
            XCTAssertTrue(heading.exists)
            XCTAssertLessThan(heading.frame.maxY, preview.frame.midY,
                              "The original place heading stays at the top of the media card")
            let stats = app.descendants(matching: .any)["friend-story.poi.stats"].firstMatch
            XCTAssertTrue(stats.exists, "Keep the original check-in, comment and favorite counters")
            XCTAssertGreaterThan(stats.frame.minY, preview.frame.midY,
                                 "Place activity stays at the bottom, separate from the top heading")
            XCTAssertLessThanOrEqual(stats.frame.maxY, preview.frame.maxY,
                                     "The counters stay inside the compact card")
            XCTAssertFalse(app.buttons["friend-story.poi.place-name"].exists,
                           "The place name is a label, not a navigation button")
            XCTAssertFalse(app.buttons["friend-story.open-place"].exists)
            return
        }
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
    private func stopPosition(_ app: XCUIApplication) -> (index: Int, count: Int) {
        let value = authorNavigation(app).value as? String ?? ""
        let words = value.split(separator: " ")
        guard words.count == 4, words[0] == "Stop", words[2] == "of",
              let number = Int(words[1]), let count = Int(words[3]),
              count > 0, (1...count).contains(number) else {
            XCTFail("Expected the grouped position 'Stop N of M', got '\(value)'")
            return (0, 1)
        }
        return (number - 1, count)
    }

    @MainActor
    private func momentPosition(_ app: XCUIApplication) -> (index: Int, count: Int)? {
        let item = app.descendants(matching: .any)["friend-story.moment-position"].firstMatch
        guard item.exists else { return nil }
        let words = item.label.split(separator: " ")
        guard words.count == 7, words[3] == "item", words[5] == "of",
              let number = Int(words[4]), let count = Int(words[6]),
              count > 1, (1...count).contains(number) else {
            XCTFail("Expected 'At this place, item X of Y', got '\(item.label)'")
            return nil
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
        if let mediaID = poiMediaID(from: currentPage(app).identifier) {
            let media = app.buttons.matching(NSPredicate(
                format: "identifier IN %@", ["friend-story.poi.media.\(mediaID)",
                                             "experience.poi.featured-media.\(mediaID)"]
            )).firstMatch
            if media.exists && media.isHittable {
                // POI titles and activity belong to a fixed place shell.
                // Page through its media from the media itself, including at
                // the boundary into another place or person's next update.
                // A natural-height portrait may continue below the viewport;
                // drag within the visible portion, not its off-screen center.
                let visibleFrame = media.frame.intersection(card.frame).intersection(app.frame)
                XCTAssertFalse(visibleFrame.isNull || visibleFrame.isEmpty)
                let visibleCenterY = (visibleFrame.midY - media.frame.minY) / media.frame.height
                media.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.84 : 0.16, dy: visibleCenterY)).press(
                    forDuration: 0.05,
                    thenDragTo: media.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.16 : 0.84, dy: visibleCenterY))
                )
                return
            }
        }
        // Original Reels (and a place without media) still use the card pager;
        // preserve photo, video and Bubble tap/drag ownership inside Reels.
        card.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.84 : 0.16, dy: 0.15)).press(
            forDuration: 0.05,
            thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: next ? 0.16 : 0.84, dy: 0.15))
        )
    }

    @MainActor
    private func fastCardSwipeBurst(_ directions: [Bool], app: XCUIApplication,
                                   delayBeforeLastSwipe: TimeInterval = 0) {
        let card = storyCard(app)
        XCTAssertTrue(card.isHittable)
        let cardFrame = card.frame.intersection(app.frame)
        var dragY = cardFrame.minY + cardFrame.height * 0.15
        if let mediaID = poiMediaID(from: currentPage(app).identifier) {
            let media = app.buttons.matching(NSPredicate(
                format: "identifier IN %@", ["friend-story.poi.media.\(mediaID)",
                                             "experience.poi.featured-media.\(mediaID)"]
            )).firstMatch
            XCTAssertTrue(media.isHittable)
            let visible = media.frame.intersection(cardFrame)
            XCTAssertFalse(visible.isNull || visible.isEmpty)
            dragY = visible.midY
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let left = origin.withOffset(CGVector(dx: cardFrame.minX + cardFrame.width * 0.08 - app.frame.minX,
                                             dy: dragY - app.frame.minY))
        let right = origin.withOffset(CGVector(dx: cardFrame.minX + cardFrame.width * 0.92 - app.frame.minX,
                                              dy: dragY - app.frame.minY))
        // Cache screen coordinates so there are no page queries or deliberate
        // settling waits between drags. XCTest still performs its own idling;
        // this tests fast gestures, not a guaranteed sub-frame input cadence.
        for (index, next) in directions.enumerated() {
            // Mix a pause into the burst without blocking the app. XCTest's
            // own idling can delay it further; native-map tests, not this UI
            // delay, prove interruption at an exact late-animation phase.
            if index == directions.count - 1, delayBeforeLastSwipe > 0 {
                Thread.sleep(forTimeInterval: delayBeforeLastSwipe)
            }
            (next ? right : left).press(forDuration: 0.01,
                thenDragTo: next ? left : right, withVelocity: .fast, thenHoldForDuration: 0)
        }
    }

    @MainActor
    private func assertStorySelectionStays(pageID: String, author: String, detent: String,
                                          app: XCUIApplication) {
        let reverted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.currentPage(app).identifier != pageID
                || self.currentAuthor(app).value as? String != author
                || self.storyCard(app).value as? String != detent
                || app.buttons["experience.media-lightbox.close"].exists
        }, object: nil)
        reverted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 1.5), .completed,
                       "A late pager callback must not revert the final page, author or sheet state")
    }

    @MainActor
    private func visibleMediaCenter(_ media: XCUIElement, app: XCUIApplication) -> XCUICoordinate {
        let visibleFrame = media.frame.intersection(storyCard(app).frame).intersection(app.frame)
        XCTAssertFalse(visibleFrame.isNull || visibleFrame.isEmpty)
        return media.coordinate(withNormalizedOffset: CGVector(
            dx: (visibleFrame.midX - media.frame.minX) / media.frame.width,
            dy: (visibleFrame.midY - media.frame.minY) / media.frame.height
        ))
    }

    private func assertOverlayFrame(_ overlay: CGRect, inside media: CGRect, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(overlay.width, 0, message, file: file, line: line)
        XCTAssertGreaterThan(overlay.height, 0, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(overlay.minX, media.minX - 2, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(overlay.minY, media.minY - 2, message, file: file, line: line)
        XCTAssertLessThanOrEqual(overlay.maxX, media.maxX + 2, message, file: file, line: line)
        XCTAssertLessThanOrEqual(overlay.maxY, media.maxY + 2, message, file: file, line: line)
    }

    private func assertFrame(_ actual: CGRect, matches expected: CGRect, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 2, message, file: file, line: line)
    }

    @MainActor
    private func selectPage(_ index: Int, app: XCUIApplication) {
        XCTAssertTrue(currentPage(app).waitForExistence(timeout: 3), "The visible progress must expose the current update")
        let position = pagePosition(app)
        guard (0..<position.count).contains(index) else {
            XCTFail("Cannot select update \(index + 1) of \(position.count)")
            return
        }
        guard position.index != index else { return }
        if abs(position.index - index) == 1 {
            swipeCard(to: index, app: app)
            return
        }

        // The top strip now represents stops, not individual media pages.
        // Locate the containing stop with real taps (bounded binary search),
        // then use the original lower-card swipe for its remaining slices.
        // This avoids either assuming equal stop sizes or swiping through
        // every earlier post when a regression needs the author's last card.
        var lowerStop = 0
        var upperStop = stopPosition(app).count - 1
        while lowerStop <= upperStop {
            let current = pagePosition(app)
            let stop = stopPosition(app)
            let item = momentPosition(app) ?? (index: 0, count: 1)
            let firstPage = current.index - item.index
            let lastPage = firstPage + item.count - 1
            if (firstPage...lastPage).contains(index) { break }
            if index < firstPage { upperStop = stop.index - 1 }
            else { lowerStop = stop.index + 1 }
            guard lowerStop <= upperStop else {
                XCTFail("No visible stop contains update \(index + 1)")
                return
            }
            let targetStop = index == 0 ? lowerStop
                : index == position.count - 1 ? upperStop : (lowerStop + upperStop) / 2
            selectStop(targetStop, app: app)
        }
        while pagePosition(app).index != index {
            let current = pagePosition(app).index
            swipeCard(to: current + (index > current ? 1 : -1), app: app)
        }
        XCTAssertEqual(pagePosition(app).index, index)
    }

    @MainActor
    private func selectStop(_ index: Int, app: XCUIApplication) {
        let stop = stopPosition(app)
        guard (0..<stop.count).contains(index) else {
            XCTFail("Cannot select stop \(index + 1) of \(stop.count)")
            return
        }
        if stop.index == index, (momentPosition(app)?.index ?? 0) == 0 { return }
        let page = currentPage(app)
        let oldID = page.identifier
        let author = currentAuthor(app).value as? String
        XCTAssertTrue(page.isHittable, "The visible progress strip must be directly tappable")
        page.coordinate(withNormalizedOffset: CGVector(
            dx: (CGFloat(index) + 0.5) / CGFloat(stop.count), dy: 0.5
        )).tap()
        waitForPageChange(from: oldID, app: app)
        XCTAssertEqual(stopPosition(app).index, index)
        XCTAssertEqual(momentPosition(app)?.index ?? 0, 0,
                       "A stop selection opens its first original media page")
        XCTAssertEqual(currentAuthor(app).value as? String, author)
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

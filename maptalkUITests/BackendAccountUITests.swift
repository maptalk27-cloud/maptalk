import Foundation
import ImageIO
import XCTest

/// Runs against the ordinary local HTTP API with fresh accounts and isolated Keychain storage.
/// The caller supplies the existing simulator's real simulated location; no fixture launch path
/// or mock data is injected into the app.
final class BackendAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoEntersWithOneTapOfflineAndReturnsToSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--local-backend"]
        app.launchEnvironment["MAPTALK_BACKEND_URL"] = "http://127.0.0.1:1"
        app.launchEnvironment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] = UUID().uuidString
        defer { app.terminate() }
        app.launch()
        let mockEntry = app.buttons["account.demo"]
        XCTAssertTrue(mockEntry.waitForExistence(timeout: 10))
        XCTAssertEqual(mockEntry.label, "Use demo")
        let providers = ["apple", "google", "wechat"].map { app.buttons["account.\($0)"] }
        for button in providers {
            XCTAssertTrue(button.exists)
            XCTAssertEqual(button.frame.height, 54, accuracy: 1)
            XCTAssertEqual(button.frame.minX, providers[0].frame.minX, accuracy: 1)
            XCTAssertEqual(button.frame.width, providers[0].frame.width, accuracy: 1)
        }
        let landing = XCTAttachment(screenshot: app.screenshot())
        landing.name = "Unified login buttons and one-tap demo"
        landing.lifetime = .keepAlways
        add(landing)
        mockEntry.tap()
        XCTAssertTrue(app.tabBars.buttons["MyMap"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["account.mock.username"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        app.tabBars.buttons["MyMap"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mymap.list-record.")).firstMatch
            .waitForExistence(timeout: 5), "The mock account should have the original demo memories, not an empty real account")
        app.tabBars.buttons["Me"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let signOut = app.buttons["account.demo.signout"]
        for _ in 0..<4 where !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(mockEntry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["MyMap"].exists)
        // Re-entering never restores the deleted username/password sheet.
        mockEntry.tap()
        XCTAssertTrue(app.tabBars.buttons["MyMap"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAppleLandingHasNoPasswordFormAndConfigurationFailureIsRetryable() throws {
        guard let address = ProcessInfo.processInfo.environment["MAPTALK_BACKEND_TEST_URL"] else {
            throw XCTSkip("Set MAPTALK_BACKEND_TEST_URL to an unconfigured local test server.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--local-backend"]
        app.launchEnvironment["MAPTALK_BACKEND_URL"] = address
        app.launchEnvironment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] = UUID().uuidString
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.buttons["account.apple"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account.google"].exists)
        XCTAssertTrue(app.buttons["account.wechat"].exists)
        XCTAssertTrue(app.buttons["account.demo"].exists)
        XCTAssertFalse(app.textFields["account.handle"].exists)
        XCTAssertFalse(app.secureTextFields["account.password"].exists)
        let error = app.staticTexts["Apple sign-in is not configured on this development server yet."]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        app.buttons["account.signin.retry"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["MyMap"].exists, "A configuration failure must not enter a mock account")
    }

    @MainActor
    func testRegisterPublishRestoreAndSwitchAccountsKeepsPrivateMemoriesPrivate() async throws {
        guard let value = ProcessInfo.processInfo.environment["MAPTALK_BACKEND_TEST_URL"] else {
            throw XCTSkip("Set MAPTALK_BACKEND_TEST_URL to run the real local backend UI flow.")
        }
        let baseURL = try XCTUnwrap(URL(string: value))
        guard baseURL.scheme == "http", ["127.0.0.1", "localhost"].contains(baseURL.host ?? "") else {
            XCTFail("The UI integration test requires a localhost HTTP backend.")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = ["--local-backend", "--developer-login"]
        app.launchEnvironment["MAPTALK_BACKEND_URL"] = baseURL.absoluteString
        app.launchEnvironment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] = UUID().uuidString
        let alertMonitor = addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for title in ["Allow While Using App", "Allow While Using the App"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        defer {
            removeUIInterruptionMonitor(alertMonitor)
            app.terminate()
        }
        app.launch()
        let alice = TestAccount(prefix: "ui_alice")
        try register(alice, in: app)
        let share = app.buttons["maptalk.share-reel"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "Registration should enter the real map, not the mock account")

        let publicText = "Public walk \(UUID().uuidString.prefix(8))"
        share.tap()
        let text = app.textViews["maptalk.reel.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText(publicText)
        XCTAssertTrue(app.staticTexts["Current location"].waitForExistence(timeout: 15),
                      "The existing simulator needs a simulated GPS location before a live publish")
        // SwiftUI propagates the composer's container identifier onto its
        // header buttons; use the unique visible action, as a person does.
        let publish = app.buttons["Share"]
        waitUntilEnabled(publish, timeout: 15,
                         message: "Publishing requires location permission and a location on the existing simulator")
        publish.tap()
        let composer = app.descendants(matching: .any)["maptalk.publish-composer"].firstMatch
        waitUntilGone(composer, timeout: 20, message: "A durable local save should close the composer without waiting for upload")
        openTab("MyMap", in: app)
        XCTAssertTrue(app.staticTexts[publicText].waitForExistence(timeout: 10))

        // This is a normal authenticated server write, not a test-only app injection route.
        // It ensures the second account never receives the first account's private archive.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let auth = try await authenticate(alice, baseURL: baseURL, session: session)
        // Composer dismissal now confirms local acceptance, not remote
        // publication. Wait for the ordinary API before cross-account checks.
        try await waitForServerPublication(text: publicText, token: auth.token, baseURL: baseURL, session: session)
        let privateText = "Private walk \(UUID().uuidString.prefix(8))"
        let privateID = UUID()
        try await createPrivateReel(id: privateID, text: privateText, token: auth.token,
                                    baseURL: baseURL, session: session)

        // Reusing the same app configuration preserves only this test's isolated saved session.
        app.terminate()
        app.launch()
        XCTAssertTrue(share.waitForExistence(timeout: 20), "Relaunch should restore the saved account")
        XCTAssertFalse(app.textFields["account.handle"].exists)
        openTab("MyMap", in: app)
        XCTAssertTrue(app.staticTexts[publicText].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[privateText].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mymap.list-record.\(privateID.uuidString)"].exists)

        openTab("Me", in: app)
        XCTAssertTrue(app.staticTexts["@\(alice.handle)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[publicText].waitForExistence(timeout: 10),
                      "The profile should retain the publicly published Reel")
        XCTAssertFalse(app.staticTexts[privateText].exists, "A public profile must not contain private archive records")
        signOut(in: app)

        let bob = TestAccount(prefix: "ui_bob")
        try register(bob, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        openTab("MyMap", in: app)
        XCTAssertTrue(app.staticTexts["No memories found"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[publicText].exists)
        XCTAssertFalse(app.staticTexts[privateText].exists)
        XCTAssertFalse(app.buttons["mymap.list-record.\(privateID.uuidString)"].exists)

        openTab("MapTalk", in: app)
        let story = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", alice.handle)).firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10), "The second account should see the first account's public feed story")
        story.tap()
        XCTAssertTrue(app.buttons[publicText].firstMatch.waitForExistence(timeout: 10),
                      "The shared text is part of the original tappable compact card")
        XCTAssertFalse(app.staticTexts[privateText].exists)

        // The compact accessibility group contains the author's separate
        // profile button. Expand with the sheet's ordinary grabber instead of
        // tapping the group's center, which can hit the author.
        let previewGrabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(previewGrabber.waitForExistence(timeout: 5))
        previewGrabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16)))
        let options = app.buttons["post.safety.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "Safety actions belong on the original expanded card")
        XCTAssertTrue(options.isHittable)
        let expandedCard = XCTAttachment(screenshot: app.screenshot())
        expandedCard.name = "Original expanded card with report menu"
        expandedCard.lifetime = .keepAlways
        add(expandedCard)
        options.tap()
        let report = app.buttons["Report post"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        let reason = app.buttons["Spam or misleading content"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.tap()
        XCTAssertTrue(app.staticTexts["Report sent. The test organizer will review it."].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()

        // Remove this test's saved app session so later manual testing starts cleanly.
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        if grabber.waitForExistence(timeout: 3) {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            )
        }
        openTab("Me", in: app)
        app.buttons["Settings"].tap()
        let deleteAccount = app.buttons["account.delete"]
        for _ in 0..<4 where !deleteAccount.isHittable { app.swipeUp() }
        XCTAssertTrue(deleteAccount.waitForExistence(timeout: 5))
        deleteAccount.tap()
        let confirmDeletion = app.buttons["Delete account and posts"]
        XCTAssertTrue(confirmDeletion.waitForExistence(timeout: 5))
        confirmDeletion.tap()
        XCTAssertTrue(app.textFields["account.handle"].waitForExistence(timeout: 10),
                      "Deleting this disposable local test account must clear its saved session")
        _ = try await sendJSON(["handle": bob.handle, "password": bob.password],
            path: "v1/auth/login", token: nil, expectedStatus: 401, baseURL: baseURL, session: session)
    }

    /// Opt-in: seed a landscape photo in the existing Simulator's library and
    /// supply a disposable localhost server. This never accesses the live API.
    @MainActor
    func testAvatarCropCancelThenDragPinchAndSaveUploadsOnlyConfirmedSquare() async throws {
        guard let value = ProcessInfo.processInfo.environment["MAPTALK_BACKEND_TEST_URL"] else {
            throw XCTSkip("Set MAPTALK_BACKEND_TEST_URL and seed a Simulator photo to run avatar acceptance.")
        }
        let baseURL = try XCTUnwrap(URL(string: value))
        guard baseURL.scheme == "http", ["127.0.0.1", "localhost"].contains(baseURL.host ?? "") else {
            XCTFail("Avatar acceptance is restricted to a disposable localhost HTTP backend.")
            return
        }
        let app = XCUIApplication()
        app.launchArguments = ["--local-backend", "--developer-login",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MAPTALK_BACKEND_URL"] = baseURL.absoluteString
        app.launchEnvironment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] = UUID().uuidString
        let alertMonitor = addUIInterruptionMonitor(withDescription: "Avatar test location permission") { alert in
            for title in ["Allow While Using App", "Allow While Using the App"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        defer {
            removeUIInterruptionMonitor(alertMonitor)
            app.terminate()
        }
        app.launch()
        let account = TestAccount(prefix: "ui_avatar")
        try register(account, in: app)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let auth = try await authenticate(account, baseURL: baseURL, session: session)

        openTab("Me", in: app)
        let edit = app.buttons["profile.edit"]
        waitForAvatarControl(edit)
        edit.tap()
        let save = app.buttons["profile.edit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "An unchanged profile must not become dirty just by opening it")

        try chooseAvatarPhoto(in: app)
        let cropCanvas = app.descendants(matching: .any)["profile.crop.canvas"].firstMatch
        waitForAvatarControl(cropCanvas)
        assertAvatarCropHeaderBelowStatusBar(in: app)
        attachAvatarScreenshot(app, name: "Avatar crop — full photo and circular framing")
        let cancelCrop = app.buttons["profile.crop.cancel"]
        waitForAvatarControl(cancelCrop)
        cancelCrop.tap()
        waitUntilGone(cancelCrop, timeout: 5, message: "Cancel should return to Edit Profile")
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "Cancelling the first crop must leave the original avatar unchanged")
        let afterCancel = try await localAvatarProfile(token: auth.token, baseURL: baseURL, session: session)
        XCTAssertNil(afterCancel.user.avatar, "Opening and cancelling a crop must not update the server profile")

        // Re-selecting the same library asset must open a fresh crop session,
        // rather than being ignored because PhotosPicker retained its item.
        try chooseAvatarPhoto(in: app)
        waitForAvatarControl(cropCanvas)
        assertAvatarCropHeaderBelowStatusBar(in: app)
        cropCanvas.pinch(withScale: 1.7, velocity: 1.2)
        let start = cropCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.42))
        let end = cropCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.58))
        start.press(forDuration: 0.05, thenDragTo: end)
        attachAvatarScreenshot(app, name: "Avatar crop — dragged and zoomed before Use")
        let use = app.buttons["profile.crop.use"]
        waitUntilEnabled(use, timeout: 5, message: "A completed crop must be confirmable")
        use.tap()
        waitUntilGone(use, timeout: 10, message: "Use should return the confirmed crop to the edit draft")
        waitUntilEnabled(save, timeout: 5, message: "Confirming a crop should enable Save")
        attachAvatarScreenshot(app, name: "Avatar crop — confirmed draft before Save")
        let beforeSave = try await localAvatarProfile(token: auth.token, baseURL: baseURL, session: session)
        XCTAssertNil(beforeSave.user.avatar, "Use only confirms a local draft; Save owns the profile update")

        save.tap()
        waitUntilGone(save, timeout: 20, message: "Saving a cropped avatar must finish without hanging or crashing")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        attachAvatarScreenshot(app, name: "Avatar crop — saved profile")
        let saved = try await localAvatarProfile(token: auth.token, baseURL: baseURL, session: session)
        XCTAssertEqual(saved.user.handle, account.handle)
        let avatar = try XCTUnwrap(saved.user.avatar)
        XCTAssertEqual(avatar.mimeType, "image/jpeg")
        XCTAssertTrue(avatar.path.hasPrefix("/v1/media/"))
        let mediaID = try XCTUnwrap(UUID(uuidString: avatar.id))
        // Construct from the verified local base and UUID, never a server-
        // supplied remote URL, so this integration test cannot leave localhost.
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/media/\(mediaID.uuidString.lowercased())"))
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        XCTAssertEqual(width, height, "The actual authenticated avatar bytes must match the square crop")
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, 1_024)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    @MainActor
    private func chooseAvatarPhoto(in app: XCUIApplication) throws {
        let choose = app.buttons["profile.edit.photo"]
        waitForAvatarControl(choose)
        choose.tap()
        // Observed iOS 26 PhotosPicker AX contract: assets are remote Images
        // with PXGGridLayout-Info and labels beginning "Photo," or "Video,".
        // Query the known asset directly; asking isHittable of every remote
        // image can hang even while the grid is visibly ready to receive taps.
        let photo = app.images.matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@", "PXGGridLayout-Info", "Photo,"
        )).firstMatch
        guard photo.waitForExistence(timeout: 5) else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Missing avatar photo — PhotosPicker accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            throw NSError(domain: "MapTalkAvatarUITest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No seeded Photo thumbnail in the native picker; inspect the attached tree."
            ])
        }
        let frame = photo.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard frame.width > 0, frame.height > 0, app.frame.contains(center) else {
            throw NSError(domain: "MapTalkAvatarUITest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The native photo thumbnail does not have a visible on-screen frame."
            ])
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: center.x, dy: center.y)).tap()
        XCTAssertTrue(app.buttons["profile.crop.use"].waitForExistence(timeout: 15),
                      "Selecting a library photo must open framing before changing the profile draft")
    }

    @MainActor
    private func assertAvatarCropHeaderBelowStatusBar(in app: XCUIApplication) {
        let bar = app.navigationBars["Adjust photo"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The fullscreen crop needs its own safe-area-aware header")
        let cancel = app.buttons["profile.crop.cancel"]
        let use = app.buttons["profile.crop.use"]
        waitForAvatarControl(cancel)
        waitForAvatarControl(use)
        XCTAssertTrue(bar.frame.contains(CGPoint(x: cancel.frame.midX, y: cancel.frame.midY)))
        XCTAssertTrue(bar.frame.contains(CGPoint(x: use.frame.midX, y: use.frame.midY)))
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists, statusBar.frame.height > 0 {
            XCTAssertGreaterThanOrEqual(cancel.frame.minY, statusBar.frame.maxY - 1,
                                        "Cancel must not overlap the status bar or Dynamic Island")
            XCTAssertGreaterThanOrEqual(use.frame.minY, statusBar.frame.maxY - 1,
                                        "Use must not overlap the status bar or Dynamic Island")
            let title = bar.staticTexts["Adjust photo"]
            XCTAssertGreaterThanOrEqual(title.frame.minY, statusBar.frame.maxY - 1,
                                        "The crop title must remain below system chrome")
        }
    }

    @MainActor
    private func waitForAvatarControl(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed,
                       "Expected visible avatar control: \(element.identifier)")
    }

    @MainActor
    private func attachAvatarScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private struct AvatarProfileResponse: Decodable {
        struct Profile: Decodable {
            struct Avatar: Decodable {
                let id: String
                let path: String
                let mimeType: String
            }
            let handle: String
            let avatar: Avatar?
        }
        let user: Profile
    }

    private func localAvatarProfile(token: String, baseURL: URL, session: URLSession) async throws -> AvatarProfileResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(AvatarProfileResponse.self, from: data)
    }

    @MainActor
    private func register(_ account: TestAccount, in app: XCUIApplication) throws {
        let handle = app.textFields["account.handle"]
        guard handle.waitForExistence(timeout: 15) else { throw RegistrationFailure.formMissing }
        let mode = app.buttons["account.mode"]
        XCTAssertTrue(mode.exists)
        if mode.label.contains("New here") { mode.tap() }
        let submit = app.buttons["account.submit"]
        let registrationReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Create account"), object: submit)
        guard XCTWaiter.wait(for: [registrationReady], timeout: 5) == .completed else {
            throw RegistrationFailure.formMissing
        }
        handle.tap()
        handle.typeText(account.handle)
        XCTAssertEqual(handle.value as? String, account.handle)
        let password = app.secureTextFields["account.password"]
        XCTAssertTrue(password.exists)
        password.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            throw RegistrationFailure.keyboardMissing
        }
        // SwiftUI's .newPassword field can replace its underlying secure input when it first
        // acquires focus. Resolve the field for each keystroke instead of sending one bulk
        // synthesized event immediately after tapping it. Only random test credentials are used.
        for character in account.password {
            app.secureTextFields["account.password"].typeText(String(character))
        }
        let completePassword = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value.length == %d", account.password.count), object: password)
        guard XCTWaiter.wait(for: [completePassword], timeout: 5) == .completed else {
            // Report the count only, never the secure value or generated password. Do not send
            // a request with incomplete input and mistake its validation error for a server bug.
            let enteredCount = (password.value as? String)?.count ?? 0
            throw RegistrationFailure.incompletePassword(expected: account.password.count, observed: enteredCount)
        }
        if submit.isHittable {
            XCTAssertTrue(submit.isEnabled)
            submit.tap()
        } else {
            // The secure field's standard Go action submits the same form when its button is
            // below the keyboard on a smaller device.
            password.typeText("\n")
        }
        guard app.buttons["maptalk.share-reel"].waitForExistence(timeout: 20) else {
            throw RegistrationFailure.registrationDidNotComplete
        }
    }

    @MainActor
    private func openTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.tap()
    }

    @MainActor
    private func signOut(in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let signOut = app.buttons["account.signout"]
        for _ in 0..<4 where !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        XCTAssertTrue(signOut.isHittable)
        signOut.tap()
        XCTAssertTrue(app.textFields["account.handle"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, message)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, message)
    }

    private struct TestAccount {
        let handle: String
        // 24 random ASCII characters satisfy the real server rules without changing keyboard
        // layouts mid-input. Production password validation remains untouched.
        let password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        init(prefix: String) {
            handle = "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))"
        }
    }

    private enum RegistrationFailure: LocalizedError {
        case formMissing
        case keyboardMissing
        case incompletePassword(expected: Int, observed: Int)
        case registrationDidNotComplete

        var errorDescription: String? {
            switch self {
            case .formMissing: return "The registration form did not become ready."
            case .keyboardMissing: return "The password field did not acquire its software keyboard."
            case let .incompletePassword(expected, observed):
                return "Secure input was incomplete before submission: expected \(expected) characters, observed \(observed) masked characters."
            case .registrationDidNotComplete: return "Registration did not enter the app; the test stopped before attempting to publish."
            }
        }
    }

    private struct Auth: Decodable { let token: String }

    private func authenticate(_ account: TestAccount, baseURL: URL, session: URLSession) async throws -> Auth {
        let data = try await sendJSON(["handle": account.handle, "password": account.password],
            path: "v1/auth/login", token: nil, expectedStatus: 200, baseURL: baseURL, session: session)
        return try JSONDecoder().decode(Auth.self, from: data)
    }

    private func createPrivateReel(id: UUID, text: String, token: String, baseURL: URL, session: URLSession) async throws {
        _ = try await sendJSON([
            "id": id.uuidString, "kind": "reel", "visibility": "private", "caption": text,
            "location": ["latitude": 37.3688, "longitude": -122.0363]
        ], path: "v1/memories", token: token, expectedStatus: 201, baseURL: baseURL, session: session)
    }

    private func waitForServerPublication(text: String, token: String, baseURL: URL, session: URLSession) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/memories"), timeoutInterval: 5)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let page = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = page?["items"] as? [[String: Any]] ?? []
            if items.contains(where: { $0["caption"] as? String == text && $0["visibility"] as? String == "public" }) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The locally accepted Reel did not reach the backend before cross-account verification")
    }

    private func sendJSON(_ body: [String: Any], path: String, token: String?, expectedStatus: Int,
                          baseURL: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
        return data
    }
}

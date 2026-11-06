import XCTest

final class TrackTextReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(readOnly: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixtures"]
        if readOnly { app.launchArguments.append("-uiTestReadOnly") }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-uiTestLongHeader"]
        }
        app.launch()
        app.buttons["Songs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alpha Song"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openPlayer(_ app: XCUIApplication) {
        app.staticTexts["Alpha Song"].tap()
        XCTAssertTrue(app.buttons["nowPlayingBar"].waitForExistence(timeout: 5))
        app.buttons["nowPlayingBar"].tap()
        XCTAssertTrue(app.buttons["showLyrics"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertLabel(_ element: XCUIElement, _ label: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLiveLyricsFollowPlaybackAndResetActualScroll() {
        let app = launch()
        openPlayer(app)
        app.buttons["showLyrics"].tap()
        let title = app.staticTexts["readerTrackTitle"]
        assertLabel(title, "Alpha Song")
        let text = app.staticTexts["readerText"]
        XCTAssertTrue(text.label.contains("café 第二行 🎵\nAlpha Song line 2"))
        let scroll = app.scrollViews["trackTextScroll"]
        let initialY = text.frame.minY
        scroll.swipeUp()
        XCTAssertLessThan(text.frame.minY, initialY - 20)
        app.buttons["skipNext"].tap()
        assertLabel(title, "Beta Song")
        XCTAssertEqual(text.frame.minY, initialY, accuracy: 3)
        XCTAssertTrue(text.label.hasPrefix("Beta Song line 1:"))
        capture("live lyrics after track change")
    }

    @MainActor
    func testTrackMenuLyricsPinsSelectionAndOpensOriginalEditor() {
        let app = launch()
        openPlayer(app)
        app.buttons["nowPlayingMenu"].tap()
        app.buttons["trackLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Lyrics"].waitForExistence(timeout: 5))
        assertLabel(app.staticTexts["readerTrackTitle"], "Alpha Song")
        app.buttons["readerEdit"].tap()
        let name = app.textFields["editName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Alpha Song")
        app.buttons["Cancel"].tap()
        assertLabel(app.staticTexts["readerTrackTitle"], "Alpha Song")
    }

    @MainActor
    func testCommentsSaveRefreshesReader() {
        let app = launch()
        app.staticTexts["Beta Song"].press(forDuration: 1.5)
        app.buttons["trackComments"].tap()
        XCTAssertTrue(app.navigationBars["Comments"].waitForExistence(timeout: 5))
        assertLabel(app.staticTexts["readerTrackTitle"], "Beta Song")
        assertLabel(app.staticTexts["readerText"], "Beta Song notes\nsecond line")
        app.buttons["readerEdit"].tap()
        let comments = app.textViews["editComments"]
        let form = app.collectionViews["editTrackForm"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if comments.exists && comments.isHittable { break }
            form.swipeUp()
        }
        XCTAssertTrue(comments.isHittable)
        comments.tap()
        comments.typeText(" saved")
        app.buttons["editSave"].tap()
        let text = app.staticTexts["readerText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(text.label.contains("saved"))
        XCTAssertTrue(text.label.contains("Beta Song notes"))
        capture("saved comments reader")
    }

    @MainActor
    func testReadOnlyReadersAndEmptyText() {
        let app = launch(readOnly: true)
        app.staticTexts["Alpha Song"].press(forDuration: 1.5)
        XCTAssertFalse(app.buttons["Edit"].exists)
        app.buttons["trackComments"].tap()
        XCTAssertTrue(app.navigationBars["Comments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["readerText"].exists)
        XCTAssertFalse(app.buttons["readerEdit"].exists)
        capture("read only comments")
        app.buttons["Done"].tap()
        app.staticTexts["Gamma Song"].press(forDuration: 1.5)
        app.buttons["trackLyrics"].tap()
        XCTAssertTrue(app.staticTexts["readerEmpty"].waitForExistence(timeout: 5))
        assertLabel(app.staticTexts["readerEmpty"], "No lyrics for this track.")
        XCTAssertFalse(app.buttons["readerEdit"].exists)
    }

    @MainActor
    func testLargeAccessibilityTextRemainsScrollable() {
        let app = launch(largeText: true)
        app.staticTexts["Alpha Song"].press(forDuration: 1.5)
        app.buttons["trackLyrics"].tap()
        XCTAssertTrue(app.staticTexts["readerText"].waitForExistence(timeout: 5))
        let text = app.staticTexts["readerText"]
        let title = app.staticTexts["readerTrackTitle"]
        let edit = app.buttons["readerEdit"]
        XCTAssertGreaterThanOrEqual(edit.frame.minY, title.frame.maxY)
        XCTAssertGreaterThan(app.scrollViews["trackTextScroll"].frame.height, 80)
        let initialY = text.frame.minY
        app.scrollViews["trackTextScroll"].swipeUp()
        XCTAssertLessThan(text.frame.minY, initialY - 20)
        XCTAssertTrue(app.buttons["readerEdit"].isHittable)
        capture("large accessibility lyrics")
        app.buttons["readerEdit"].tap()
        XCTAssertTrue(app.textFields["editName"].waitForExistence(timeout: 5))
        capture("large accessibility editor")
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        openPlayer(app)
        app.buttons["showLyrics"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.scrollViews["trackTextScroll"].frame.height, 80)
        let liveInitialY = text.frame.minY
        app.scrollViews["trackTextScroll"].swipeUp()
        XCTAssertLessThan(text.frame.minY, liveInitialY - 20)
        XCTAssertTrue(app.buttons["skipNext"].isHittable)
        capture("large accessibility live lyrics")
    }
}

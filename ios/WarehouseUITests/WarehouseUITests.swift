import XCTest

final class WarehouseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// launches the app against the fixture library from UITestSupport
    @MainActor
    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixtures"]
        app.launch()
        return app
    }

    /// waits for an element to be on screen, not just in the hierarchy, since
    /// the scroll to a track settles shortly after the list appears
    @MainActor
    private func waitForVisible(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func testShowInSongsScrollsToSong() throws {
        let app = launchWithFixtures()

        // library tab → playlists → the fixture playlist, where song 100 is
        // pinned near the top in playlist order
        app.buttons["Playlists"].firstMatch.tap()
        let playlistRow = app.buttons["Fixture Playlist"]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 5))
        playlistRow.tap()

        // hold the track & jump to it in the full songs list
        let song = app.staticTexts["Song 100"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.press(forDuration: 1.5)
        let showInSongs = app.buttons["Go to Song"]
        XCTAssertTrue(showInSongs.waitForExistence(timeout: 5))
        showInSongs.tap()

        // the songs list sorts by title, so song 100 is deep in the list &
        // only on screen if the scroll to it worked
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForVisible(app.staticTexts["Song 100"].firstMatch))
        XCTAssertFalse(app.staticTexts["Alpha Song"].firstMatch.isHittable)
    }

    @MainActor
    func testShowInPlaylistScrollsToSong() throws {
        let app = launchWithFixtures()

        // library tab → songs, where gamma song is third by title
        app.buttons["Songs"].firstMatch.tap()
        let gamma = app.staticTexts["Gamma Song"]
        XCTAssertTrue(gamma.waitForExistence(timeout: 5))
        gamma.press(forDuration: 1.5)

        // hold the track & jump to it in the fixture playlist
        let showInPlaylist = app.buttons["Show in Playlist"]
        XCTAssertTrue(showInPlaylist.waitForExistence(timeout: 5))
        showInPlaylist.tap()
        let playlistButton = app.buttons["Fixture Playlist"]
        XCTAssertTrue(playlistButton.waitForExistence(timeout: 5))
        playlistButton.tap()

        // gamma song is last in playlist order, so it's only on screen if
        // the scroll to it worked
        XCTAssertTrue(app.navigationBars["Fixture Playlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForVisible(app.staticTexts["Gamma Song"].firstMatch))
        XCTAssertFalse(app.staticTexts["Alpha Song"].firstMatch.isHittable)
    }

    @MainActor
    func testPlayingFilteredSongClearsFilterAndScrolls() throws {
        let app = launchWithFixtures()

        // library tab → songs, sorted by title
        app.buttons["Songs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alpha Song"].waitForExistence(timeout: 5))

        // the search bar sits above the first row, so pull the list down to
        // reveal it, then filter down to a single song deep in the list
        app.collectionViews.firstMatch.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Song 100")

        // the filter hides everything else, including song 100's neighbours
        let match = app.staticTexts["Song 100"]
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Song 101"].exists)
        XCTAssertFalse(app.staticTexts["Alpha Song"].exists)

        // tapping the filtered song clears the search & plays the whole list
        match.tap()

        // song 101 was filtered out and sorts right after song 100, so it's
        // only back on screen if the filter cleared and the list scrolled here
        XCTAssertTrue(waitForVisible(app.staticTexts["Song 101"].firstMatch))
        // ...and the top of the list is scrolled away
        XCTAssertFalse(app.staticTexts["Alpha Song"].firstMatch.isHittable)
    }

    @MainActor
    func testNoShowInSongsInSongsList() throws {
        let app = launchWithFixtures()

        // library tab → songs
        app.buttons["Songs"].firstMatch.tap()

        // holding a track in the songs list shouldn't offer go to songs
        let beta = app.staticTexts["Beta Song"]
        XCTAssertTrue(beta.waitForExistence(timeout: 5))
        beta.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Play Next"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Go to Song"].exists)
    }
}

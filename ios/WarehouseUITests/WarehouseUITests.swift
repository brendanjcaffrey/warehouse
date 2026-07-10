import XCTest

final class WarehouseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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

    /// plays the songs list & opens the full player, returning the app so the
    /// queue & track menu tests can share the setup
    @MainActor
    private func openNowPlaying() -> XCUIApplication {
        let app = launchWithFixtures()

        // library tab → songs, then play alpha song so the rest of the list
        // becomes the upcoming queue
        app.buttons["Songs"].firstMatch.tap()
        let alpha = app.staticTexts["Alpha Song"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.tap()

        // the now playing bar appears once something is playing; tapping it
        // opens the full screen player
        let bar = app.buttons["nowPlayingBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()
        return app
    }

    /// the on screen match for a label, skipping the duplicate the tab view
    /// leaves mounted behind the now playing sheet
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let matches = app.staticTexts.matching(identifier: label)
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    @MainActor
    func testQueueRowHasSongContextMenu() throws {
        let app = openNowPlaying()

        // switch the player over to the queue list
        let showQueue = app.buttons["showQueue"]
        XCTAssertTrue(showQueue.waitForExistence(timeout: 5))
        showQueue.tap()

        // beta song is first in the upcoming queue after alpha; holding it
        // should bring up the full track context menu
        XCTAssertTrue(app.staticTexts["Playing Next"].waitForExistence(timeout: 5))
        onScreen(app, "Beta Song").press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Play Next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Go to Song"].exists)
        XCTAssertTrue(app.buttons["Go to Artist"].exists)
    }

    @MainActor
    func testNowPlayingMenuNavigatesLibraryTab() throws {
        let app = openNowPlaying()

        // the three dots menu next to the track name offers the go to entries
        // but not play or play next, since the track is already playing
        let menu = app.buttons["nowPlayingMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertFalse(app.buttons["Play Next"].exists)
        XCTAssertTrue(app.buttons["Go to Song"].exists)
        let goToArtist = app.buttons["Go to Artist"]
        XCTAssertTrue(goToArtist.waitForExistence(timeout: 5))
        goToArtist.tap()

        // it dismisses the modal & pushes the artist view onto the library tab
        XCTAssertTrue(app.navigationBars["Fixture Artist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nowPlayingMenu"].exists)
        // the mini player stays put with the track still playing
        XCTAssertTrue(app.buttons["nowPlayingBar"].exists)
    }

    @MainActor
    func testNowPlayingMenuLeavesSettingsTab() throws {
        let app = launchWithFixtures()

        // play something from the library so the now playing bar appears
        app.buttons["Songs"].firstMatch.tap()
        let alpha = app.staticTexts["Alpha Song"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.tap()

        // move over to the settings tab, then open the player from the bar
        app.tabBars.buttons["Settings"].tap()
        let bar = app.buttons["nowPlayingBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()

        // go to album drops the modal, leaves settings & lands on the album
        // view in the library tab
        let menu = app.buttons["nowPlayingMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let goToAlbum = app.buttons["Go to Album"]
        XCTAssertTrue(goToAlbum.waitForExistence(timeout: 5))
        goToAlbum.tap()

        XCTAssertTrue(app.navigationBars["Fixture Album"].waitForExistence(timeout: 5))
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

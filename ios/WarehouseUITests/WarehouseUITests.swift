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

        // library tab → the fixture playlist in the playlists section, where
        // song 100 is pinned near the top in playlist order
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

    /// plays the songs list so alpha is current & the rest becomes the queue,
    /// returning once the now playing bar has appeared
    @MainActor
    private func playFixtureSongs() -> XCUIApplication {
        let app = launchWithFixtures()

        // library tab → songs, then play alpha song so the rest of the list
        // becomes the upcoming queue
        app.buttons["Songs"].firstMatch.tap()
        let alpha = app.staticTexts["Alpha Song"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.tap()

        // the now playing bar appears once something is playing
        XCTAssertTrue(app.buttons["nowPlayingBar"].waitForExistence(timeout: 5))
        return app
    }

    /// plays the songs list & opens the full player, returning the app so the
    /// queue & track menu tests can share the setup
    @MainActor
    private func openNowPlaying() -> XCUIApplication {
        let app = playFixtureSongs()
        app.buttons["nowPlayingBar"].tap()
        return app
    }

    /// waits for an element's accessibility label to become an exact value,
    /// re-reading it as the underlying view updates
    @MainActor
    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// waits for an element's accessibility label to contain a substring, used
    /// for the bar whose label merges the track name & artist
    @MainActor
    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    @MainActor
    func testMiniBarTransportControls() throws {
        let app = playFixtureSongs()

        // the fixtures have no audio to stream, so playback sits paused & the
        // bar's play button reflects that; tapping it toggles the state
        let playPause = app.buttons["barPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "Play")
        playPause.tap()
        XCTAssertTrue(waitFor(playPause, label: "Pause"))
        playPause.tap()
        XCTAssertTrue(waitFor(playPause, label: "Play"))

        // the forward button advances to beta, the next track in the list
        let bar = app.buttons["nowPlayingBar"]
        XCTAssertTrue(waitFor(bar, labelContaining: "Alpha Song"))
        app.buttons["barNext"].tap()
        XCTAssertTrue(waitFor(bar, labelContaining: "Beta Song"))
    }

    @MainActor
    func testFullPlayerTransportControls() throws {
        let app = openNowPlaying()

        // the title starts on alpha, the first song in the list
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(waitFor(title, label: "Alpha Song"))

        // skip forward to beta, then back to alpha; still near the start so
        // previous steps back a track instead of restarting the current one
        app.buttons["skipNext"].tap()
        XCTAssertTrue(waitFor(title, label: "Beta Song"))
        app.buttons["skipPrevious"].tap()
        XCTAssertTrue(waitFor(title, label: "Alpha Song"))

        // play/pause reflects & toggles the paused fixture playback
        let playPause = app.buttons["playPause"]
        XCTAssertEqual(playPause.label, "Play")
        playPause.tap()
        XCTAssertTrue(waitFor(playPause, label: "Pause"))
        playPause.tap()
        XCTAssertTrue(waitFor(playPause, label: "Play"))
    }

    @MainActor
    func testEditTrackUpdatesListAndNowPlaying() throws {
        // play alpha so the edit's effect on the now playing bar is visible
        let app = playFixtureSongs()
        let bar = app.buttons["nowPlayingBar"]
        XCTAssertTrue(waitFor(bar, labelContaining: "Alpha Song"))

        // hold the track's list row (the bar shows the same name) & open the
        // edit sheet from its context menu
        let row = app.collectionViews.firstMatch.staticTexts["Alpha Song"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.5)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        // replace the name field's contents
        let name = app.textFields["editName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        name.typeText("Edited Song")
        app.buttons["editSave"].tap()

        // the songs list & the now playing bar both pick up the new name
        XCTAssertTrue(app.staticTexts["Edited Song"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha Song"].exists)
        XCTAssertTrue(waitFor(bar, labelContaining: "Edited Song"))
    }

    @MainActor
    func testTappingUpcomingRowJumpsToTrack() throws {
        let app = openNowPlaying()

        // switch the player over to the queue list
        let showQueue = app.buttons["showQueue"]
        XCTAssertTrue(showQueue.waitForExistence(timeout: 5))
        showQueue.tap()

        // beta leads the upcoming queue after alpha; tapping the row should
        // jump straight to it and make it the current track
        XCTAssertTrue(app.staticTexts["Playing Next"].waitForExistence(timeout: 5))
        onScreen(app, "Beta Song").tap()
        XCTAssertTrue(waitFor(app.staticTexts["nowPlayingTitle"], label: "Beta Song"))
    }
}

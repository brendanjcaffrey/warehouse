import Foundation

/// launching with -uiTestFixtures skips the login flow and runs the app
/// against a small in-memory library, so ui tests don't need a server
enum UITestSupport {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-uiTestFixtures")

    static func seed(_ database: LibraryDatabase) async {
        try? await database.replaceLibrary(with: fixtureLibrary())
    }

    private static func fixtureLibrary() -> Library {
        var library = Library()
        library.artists = [1: sortName("Fixture Artist")]
        library.albums = [1: sortName("Fixture Album")]
        library.genres = [1: name("Fixture Genre")]
        let numbered = (1...120).map {
            track(
                id: String(format: "n%03d", $0),
                name: String(format: "Song %03d", $0),
                playlistIds: ["p1"])
        }
        library.tracks = [
            track(id: "t1", name: "Alpha Song", playlistIds: ["p1"]),
            track(id: "t2", name: "Beta Song", playlistIds: []),
            track(id: "t3", name: "Gamma Song", playlistIds: ["p1"])
        ] + numbered
        var playlist = Playlist()
        playlist.id = "p1"
        playlist.name = "Fixture Playlist"
        // song 100 is pinned near the top so tests can hold it without
        // scrolling & gamma song is last so show in playlist has to scroll
        playlist.trackIds = ["t1", "n100"]
            + numbered.map(\.id).filter { $0 != "n100" }
            + ["t3"]
        library.playlists = [playlist]
        return library
    }

    private static func track(id: String, name: String, playlistIds: [String]) -> Track {
        var track = Track()
        track.id = id
        track.name = name
        track.artistID = 1
        track.albumArtistID = 1
        track.albumID = 1
        track.genreID = 1
        track.duration = 100
        track.finish = 100
        track.trackNumber = 1
        track.discNumber = 1
        track.musicFilename = "\(id).mp3"
        track.playlistIds = playlistIds
        return track
    }

    private static func sortName(_ value: String) -> SortName {
        var out = SortName()
        out.name = value
        return out
    }

    private static func name(_ value: String) -> Name {
        var out = Name()
        out.name = value
        return out
    }
}

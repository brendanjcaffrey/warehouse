import CoreData
import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("LibraryDatabase")
@MainActor
struct LibraryDatabaseTests {
    static func makeLibrary() -> Library {
        var library = Library()
        library.genres = [7: Name.with { $0.name = "Rock" }]
        library.artists = [
            1: SortName.with { $0.name = "The Beatles"; $0.sortName = "Beatles, The" },
            2: SortName.with { $0.name = "Cher"; $0.sortName = "Cher" }
        ]
        library.albums = [3: SortName.with { $0.name = "Abbey Road" }]

        var track1 = Track()
        track1.id = "t1"
        track1.name = "Come Together"
        track1.sortName = ""
        track1.artistID = 1
        track1.albumArtistID = 2
        track1.albumID = 3
        track1.genreID = 7
        track1.year = 1969
        track1.duration = 259.7
        track1.start = 0
        track1.finish = 259.7
        track1.trackNumber = 1
        track1.discNumber = 1
        track1.playCount = 5
        track1.rating = 100
        track1.musicFilename = "m1.mp3"
        track1.artworkFilename = "a1.jpg"
        track1.addedDate = 1_600_000_000
        track1.playlistIds = ["lib", "c1"]

        var track2 = Track()
        track2.id = "t2"
        track2.name = "Believe"
        track2.artistID = 2
        track2.albumArtistID = 999 // missing on purpose
        track2.albumID = 999
        track2.genreID = 999
        track2.musicFilename = "m2.mp3"
        track2.artworkFilename = ""
        track2.playlistIds = ["lib"]

        library.tracks = [track1, track2]

        var libraryPlaylist = Playlist()
        libraryPlaylist.id = "lib"
        libraryPlaylist.name = "Library"
        libraryPlaylist.parentID = ""
        libraryPlaylist.isLibrary = true

        var folder = Playlist()
        folder.id = "f1"
        folder.name = "Folder"
        folder.parentID = ""

        var child = Playlist()
        child.id = "c1"
        child.name = "Child"
        child.parentID = "f1"
        child.trackIds = ["t1"]

        var grandchild = Playlist()
        grandchild.id = "g1"
        grandchild.name = "Grandchild"
        grandchild.parentID = "c1"

        library.playlists = [libraryPlaylist, folder, child, grandchild]
        library.trackUserChanges = true
        library.totalFileSize = 12345
        library.updateTimeNs = 43
        return library
    }

    static func allTracks(_ database: LibraryDatabase) throws -> [String: TrackEntity] {
        let request = NSFetchRequest<TrackEntity>(entityName: "TrackEntity")
        let tracks = try database.container.viewContext.fetch(request)
        return Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    static func allPlaylists(_ database: LibraryDatabase) throws -> [String: PlaylistEntity] {
        let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
        let playlists = try database.container.viewContext.fetch(request)
        return Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
    }

    @Test("import denormalizes artist, album & genre names into tracks")
    func importDenormalizesTracks() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        let tracks = try Self.allTracks(database)
        let track1 = try #require(tracks["t1"])
        #expect(track1.name == "Come Together")
        #expect(track1.artistName == "The Beatles")
        #expect(track1.artistSortName == "Beatles, The")
        #expect(track1.albumArtistName == "Cher")
        #expect(track1.albumArtistSortName.isEmpty) // same as name, dropped
        #expect(track1.albumName == "Abbey Road")
        #expect(track1.albumSortName.isEmpty) // empty sort name, dropped
        #expect(track1.genre == "Rock")
        #expect(track1.year == 1969)
        #expect(abs(track1.duration - 259.7) < 0.001)
        #expect(track1.trackNumber == 1)
        #expect(track1.playCount == 5)
        #expect(track1.rating == 100)
        #expect(track1.musicFilename == "m1.mp3")
        #expect(track1.artworkFilename == "a1.jpg")
        #expect(track1.addedDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(track1.playlistIds == ["lib", "c1"])

        let track2 = try #require(tracks["t2"])
        #expect(track2.artistName == "Cher")
        #expect(track2.albumArtistName.isEmpty) // unknown ids resolve to empty
        #expect(track2.albumName.isEmpty)
        #expect(track2.addedDate == nil) // unset on the wire stays nil
        #expect(track2.genre.isEmpty)
        #expect(track2.artworkFilename == nil) // empty artwork becomes nil
    }

    @Test("import computes transitive parent & child playlist ids")
    func importComputesPlaylistRelationships() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        let playlists = try Self.allPlaylists(database)
        #expect(playlists.count == 4)

        let folder = try #require(playlists["f1"])
        #expect(folder.parentPlaylistIds.isEmpty)
        #expect(Set(folder.childPlaylistIds) == ["c1", "g1"])

        let child = try #require(playlists["c1"])
        #expect(child.parentPlaylistIds == ["f1"])
        #expect(child.childPlaylistIds == ["g1"])
        #expect(child.trackIds == ["t1"])

        let grandchild = try #require(playlists["g1"])
        #expect(grandchild.parentPlaylistIds == ["c1", "f1"])
        #expect(grandchild.childPlaylistIds.isEmpty)

        let libraryPlaylist = try #require(playlists["lib"])
        #expect(libraryPlaylist.isLibrary)
    }

    @Test("import replaces all existing data")
    func importReplacesExistingData() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        var replacement = Library()
        var track = Track()
        track.id = "t3"
        track.name = "New Track"
        track.musicFilename = "m3.mp3"
        replacement.tracks = [track]

        try await database.replaceLibrary(with: replacement)

        let tracks = try Self.allTracks(database)
        #expect(tracks.count == 1)
        #expect(tracks["t3"] != nil)
        let playlists = try Self.allPlaylists(database)
        #expect(playlists.isEmpty)
    }

    @Test("allSongs returns lightweight copies of every track")
    func allSongs() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        let songs = try await database.allSongs()
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        #expect(songs.count == 2)

        let song1 = try #require(byId["t1"])
        #expect(song1.name == "Come Together")
        #expect(song1.artistName == "The Beatles")
        #expect(song1.artistSortName == "Beatles, The")
        #expect(song1.albumArtistName == "Cher")
        #expect(song1.albumName == "Abbey Road")
        #expect(song1.genre == "Rock")
        #expect(song1.year == 1969)
        #expect(abs(song1.duration - 259.7) < 0.001)
        #expect(song1.start == 0)
        #expect(abs(song1.finish - 259.7) < 0.001)
        #expect(song1.discNumber == 1)
        #expect(song1.trackNumber == 1)
        #expect(song1.playCount == 5)
        #expect(song1.rating == 100)
        #expect(song1.musicFilename == "m1.mp3")
        #expect(song1.artworkFilename == "a1.jpg")
        #expect(song1.addedDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(song1.titleSortKey == "Come Together")
        #expect(song1.artistSortKey == "Beatles, The")

        let song2 = try #require(byId["t2"])
        #expect(song2.albumName.isEmpty)
        #expect(song2.artworkFilename == nil)
        #expect(song2.addedDate == nil)
        #expect(song2.artistSortKey == "Cher")
    }

    @Test("allPlaylists returns lightweight copies with folder flags")
    func allPlaylists() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        let playlists = try await database.allPlaylists()
        let byId = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        #expect(playlists.count == 4)

        let library = try #require(byId["lib"])
        #expect(library.isLibrary)
        #expect(!library.isFolder)

        let folder = try #require(byId["f1"])
        #expect(folder.name == "Folder")
        #expect(folder.parentId.isEmpty)
        #expect(folder.isFolder)

        let child = try #require(byId["c1"])
        #expect(child.parentId == "f1")
        #expect(child.isFolder) // it has a child playlist
        #expect(child.trackIds == ["t1"])

        let grandchild = try #require(byId["g1"])
        #expect(!grandchild.isFolder)
        #expect(grandchild.trackIds.isEmpty)
    }

    static func editedSong(id: String = "t1", artworkFilename: String? = "b2.jpg") -> Song {
        Song(
            id: id,
            name: "Something",
            sortName: "ignored",
            artistName: "George Harrison",
            artistSortName: "ignored",
            albumArtistName: "The Beatles",
            albumArtistSortName: "ignored",
            albumName: "Abbey Road (Remaster)",
            albumSortName: "ignored",
            genre: "Classic Rock",
            year: 1970,
            duration: 259.7,
            start: 1.5,
            finish: 200,
            discNumber: 1,
            trackNumber: 1,
            playCount: 999, // ignored, updates never touch the play count
            rating: 80,
            musicFilename: "m1.mp3",
            artworkFilename: artworkFilename)
    }

    @Test("updateTrack rewrites the edited fields & leaves sort names alone")
    func updateTrack() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        try await database.updateTrack(Self.editedSong())

        let songs = try await database.allSongs()
        let song = try #require(songs.first { $0.id == "t1" })
        #expect(song.name == "Something")
        #expect(song.artistName == "George Harrison")
        #expect(song.albumArtistName == "The Beatles")
        #expect(song.albumName == "Abbey Road (Remaster)")
        #expect(song.genre == "Classic Rock")
        #expect(song.year == 1970)
        #expect(abs(song.start - 1.5) < 0.0001)
        #expect(abs(song.finish - 200) < 0.0001)
        #expect(song.rating == 80)
        #expect(song.playCount == 5)
        #expect(song.artworkFilename == "b2.jpg")
        // sort names go stale until the next sync, matching the web app
        #expect(song.sortName.isEmpty)
        #expect(song.artistSortName == "Beatles, The")
        #expect(song.albumArtistSortName.isEmpty)
        #expect(song.albumSortName.isEmpty)
        #expect(abs(song.duration - 259.7) < 0.001)
    }

    @Test("updateTrack can clear artwork & skips unknown tracks")
    func updateTrackEdgeCases() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        try await database.updateTrack(Self.editedSong(artworkFilename: nil))
        let songs = try await database.allSongs()
        let song = try #require(songs.first { $0.id == "t1" })
        #expect(song.artworkFilename == nil)

        try await database.updateTrack(Self.editedSong(id: "missing"))
        #expect(try await database.trackCount() == 2)
    }

    @Test("filename queries return referenced files")
    func filenameQueries() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())

        #expect(try await database.musicFilenames() == ["m1.mp3", "m2.mp3"])
        #expect(try await database.artworkFilenames() == ["a1.jpg"])
        #expect(try await database.trackCount() == 2)
    }
}

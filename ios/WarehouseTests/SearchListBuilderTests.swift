import Foundation
import Testing
@testable import Warehouse

@Suite("SearchListBuilder")
struct SearchListBuilderTests {
    static func song(
        id: String = "id",
        name: String = "Song",
        artist: String = "",
        album: String = "",
        year: Int = 0
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: "",
            artistName: artist,
            artistSortName: "",
            albumArtistName: "",
            albumArtistSortName: "",
            albumName: album,
            albumSortName: "",
            genre: "",
            year: year,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).mp3",
            artworkFilename: nil)
    }

    static let songs = [
        song(id: "1", name: "Believe", artist: "Cher", album: "Believe", year: 1998),
        song(id: "2", name: "Strong Enough", artist: "Cher", album: "Believe", year: 1998),
        song(id: "3", name: "Yesterday", artist: "The Beatles", album: "Help!", year: 1965),
        song(id: "4", name: "Cherry Bomb", artist: "The Runaways", album: "The Runaways", year: 1976)
    ]

    @Test("an empty or blank query returns no results")
    func blankQuery() {
        #expect(SearchListBuilder.results(Self.songs, scope: .songs, matching: "").isEmpty)
        #expect(SearchListBuilder.results(Self.songs, scope: .artists, matching: "   ").isEmpty)
    }

    @Test("song scope matches song title and artist, sorted by title")
    func songScope() {
        let results = SearchListBuilder.results(Self.songs, scope: .songs, matching: "cher")
        #expect(results.songs.map(\.name) == ["Believe", "Cherry Bomb", "Strong Enough"])
        #expect(results.artists.isEmpty)
        #expect(results.albums.isEmpty)
    }

    @Test("album scope matches album title and artist")
    func albumScope() {
        let byTitle = SearchListBuilder.results(Self.songs, scope: .albums, matching: "help")
        #expect(byTitle.albums.map(\.name) == ["Help!"])

        let byArtist = SearchListBuilder.results(Self.songs, scope: .albums, matching: "cher")
        #expect(byArtist.albums.map(\.name) == ["Believe"])
    }

    @Test("artist scope matches artist names in sorted order")
    func artistScope() {
        let results = SearchListBuilder.results(Self.songs, scope: .artists, matching: "the")
        #expect(results.artists.map(\.name) == ["The Beatles", "The Runaways"])
        #expect(results.songs.isEmpty)
    }

    @Test("no matches returns empty results")
    func noMatches() {
        #expect(SearchListBuilder.results(Self.songs, scope: .songs, matching: "xyz").isEmpty)
    }
}

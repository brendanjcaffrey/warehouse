import Foundation
import Testing
@testable import Warehouse

@Suite("ArtistListBuilder")
struct ArtistListBuilderTests {
    static func song(
        id: String = "id",
        name: String = "Song",
        artist: String = "",
        artistSortName: String = "",
        albumArtist: String = "",
        album: String = "",
        albumSortName: String = "",
        year: Int = 0
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: "",
            artistName: artist,
            artistSortName: artistSortName,
            albumArtistName: albumArtist,
            albumArtistSortName: "",
            albumName: album,
            albumSortName: albumSortName,
            genre: "",
            year: year,
            duration: 0,
            start: 0,
            finish: 0,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).mp3",
            artworkFilename: nil)
    }

    @Test("artists group songs by track artist with albums in year order")
    func grouping() {
        let songs = [
            Self.song(id: "1", artist: "The Beatles", album: "Abbey Road", year: 1969),
            Self.song(id: "2", artist: "Cher", album: "Believe", year: 1998),
            Self.song(id: "3", artist: "The Beatles", album: "Rubber Soul", year: 1965)
        ]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 2)
        #expect(artists[0].name == "The Beatles")
        #expect(artists[0].albums.map(\.name) == ["Rubber Soul", "Abbey Road"])
        #expect(artists[1].name == "Cher")
    }

    @Test("artists with only non-album singles get an unknown album")
    func singlesOnly() {
        let songs = [Self.song(id: "1", name: "Single", artist: "Cher")]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 1)
        #expect(artists[0].name == "Cher")
        #expect(artists[0].albums.map(\.name) == ["Unknown Album"])
        #expect(artists[0].albums[0].songs.map(\.id) == ["1"])
    }

    @Test("songs without an album collect into an unknown album at the end")
    func unknownAlbumLast() {
        let songs = [
            Self.song(id: "1", name: "Single", artist: "Cher"),
            Self.song(id: "2", artist: "Cher", album: "No Year"),
            Self.song(id: "3", artist: "Cher", album: "Believe", year: 1998)
        ]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 1)
        #expect(artists[0].albums.map(\.name) == ["Believe", "No Year", "Unknown Album"])
        #expect(artists[0].albums[2].songs.map(\.id) == ["1"])
    }

    @Test("songs without an artist are left out")
    func noArtist() {
        let songs = [Self.song(id: "1", name: "Mystery")]
        #expect(ArtistListBuilder.artists(from: songs).isEmpty)
    }

    @Test("albums with unknown years sort last, ties broken by title")
    func albumOrder() {
        let songs = [
            Self.song(id: "1", artist: "Cher", album: "No Year"),
            Self.song(id: "2", artist: "Cher", album: "Twins", year: 1998),
            Self.song(id: "3", artist: "Cher", album: "Believe", year: 1998)
        ]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 1)
        #expect(artists[0].albums.map(\.name) == ["Believe", "Twins", "No Year"])
    }

    @Test("artists with the same folded name group together")
    func foldedGrouping() {
        let songs = [
            Self.song(id: "1", artist: "Beyoncé", album: "Dangerously in Love"),
            Self.song(id: "2", artist: "beyonce", album: "Lemonade")
        ]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 1)
        #expect(artists[0].name == "Beyoncé")
        #expect(artists[0].albums.count == 2)
    }

    @Test("artist sort name comes from the first song that has one")
    func sortNameFallback() {
        let songs = [
            Self.song(id: "1", artist: "The Who"),
            Self.song(id: "2", artist: "The Who", artistSortName: "Who, The")
        ]

        let artists = ArtistListBuilder.artists(from: songs)
        #expect(artists.count == 1)
        #expect(artists[0].sortName == "Who, The")
    }

    @Test("sections use sort names and put symbols in a # section last")
    func sections() {
        let artists = ArtistListBuilder.artists(from: [
            Self.song(id: "1", artist: "The Beatles", artistSortName: "Beatles, The"),
            Self.song(id: "2", artist: "Cher"),
            Self.song(id: "3", artist: "311")
        ])

        let sections = ArtistListBuilder.sections(artists, matching: "")
        #expect(sections.map(\.title) == ["B", "C", "#"])
        #expect(sections[0].artists.map(\.name) == ["The Beatles"])
        #expect(sections[2].artists.map(\.name) == ["311"])
    }

    @Test("search matches artist names, case insensitively")
    func search() {
        let artists = ArtistListBuilder.artists(from: [
            Self.song(id: "1", artist: "Cher"),
            Self.song(id: "2", artist: "The Beatles")
        ])

        let matched = ArtistListBuilder.sections(artists, matching: "cher")
        #expect(matched.flatMap { $0.artists.map(\.name) } == ["Cher"])

        #expect(ArtistListBuilder.sections(artists, matching: "xyz").isEmpty)
    }

    @Test("blank search returns everything")
    func blankSearch() {
        let artists = ArtistListBuilder.artists(from: [Self.song(id: "1", artist: "Cher")])
        let sections = ArtistListBuilder.sections(artists, matching: "   ")
        #expect(sections.flatMap(\.artists).count == 1)
    }

    @Test("artist lookup matches folded names and returns nil otherwise")
    func artistLookup() {
        let songs = [
            Self.song(id: "1", artist: "Beyoncé", album: "Lemonade"),
            Self.song(id: "2", artist: "Cher", album: "Believe")
        ]

        let artist = ArtistListBuilder.artist(named: "beyonce", in: songs)
        #expect(artist?.name == "Beyoncé")
        #expect(artist?.albums.map(\.name) == ["Lemonade"])

        #expect(ArtistListBuilder.artist(named: "The Beatles", in: songs) == nil)
        #expect(ArtistListBuilder.artist(named: "", in: songs) == nil)
    }

    @Test("album artist lookup falls back to a standalone artist for compilations")
    func albumArtistLookup() {
        let songs = [
            Self.song(id: "1", artist: "Cher", albumArtist: "Various Artists", album: "Now Vol. 1"),
            Self.song(id: "2", artist: "The Beatles", albumArtist: "Various Artists", album: "Now Vol. 1"),
            Self.song(id: "3", artist: "Cher", album: "Believe")
        ]
        let albums = AlbumListBuilder.albums(from: songs)

        let compilation = ArtistListBuilder.artist(for: albums[0], in: songs)
        #expect(compilation?.name == "Various Artists")
        #expect(compilation?.albums == [albums[0]])

        let known = ArtistListBuilder.artist(for: albums[1], in: songs)
        #expect(known?.name == "Cher")
        // compilations she appears on show up under her too
        #expect(known?.albums.map(\.name) == ["Believe", "Now Vol. 1"])
    }
}

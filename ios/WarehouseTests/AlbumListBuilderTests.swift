import Foundation
import Testing
@testable import Warehouse

@Suite("AlbumListBuilder")
struct AlbumListBuilderTests {
    static func song(
        id: String = "id",
        name: String = "Song",
        artist: String = "",
        artistSortName: String = "",
        albumArtist: String = "",
        albumArtistSortName: String = "",
        album: String = "",
        albumSortName: String = "",
        genre: String = "",
        year: Int = 0,
        disc: Int = 0,
        track: Int = 0,
        artwork: String? = nil
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: "",
            artistName: artist,
            artistSortName: artistSortName,
            albumArtistName: albumArtist,
            albumArtistSortName: albumArtistSortName,
            albumName: album,
            albumSortName: albumSortName,
            genre: genre,
            year: year,
            discNumber: disc,
            trackNumber: track,
            musicFilename: "\(id).mp3",
            artworkFilename: artwork)
    }

    @Test("albums group by album artist & name with tracks in disc & track order")
    func grouping() {
        let songs = [
            Self.song(id: "1", name: "Polythene Pam", albumArtist: "The Beatles", album: "Abbey Road",
                      disc: 1, track: 10),
            Self.song(id: "2", name: "Come Together", albumArtist: "The Beatles", album: "Abbey Road",
                      disc: 1, track: 1),
            Self.song(id: "3", name: "Believe", albumArtist: "Cher", album: "Believe", track: 1),
            Self.song(id: "4", name: "Her Majesty", albumArtist: "The Beatles", album: "Abbey Road",
                      disc: 2, track: 1)
        ]

        let albums = AlbumListBuilder.albums(from: songs)
        #expect(albums.count == 2)

        let abbeyRoad = albums[0]
        #expect(abbeyRoad.name == "Abbey Road")
        #expect(abbeyRoad.artistName == "The Beatles")
        #expect(abbeyRoad.songs.map(\.id) == ["2", "1", "4"])
        #expect(albums[1].name == "Believe")
    }

    @Test("album artist falls back to the track artist")
    func albumArtistFallback() {
        let songs = [
            Self.song(id: "1", artist: "Cher", artistSortName: "Cher, The", album: "Believe")
        ]

        let albums = AlbumListBuilder.albums(from: songs)
        #expect(albums.count == 1)
        #expect(albums[0].artistName == "Cher")
        #expect(albums[0].artistSortName == "Cher, The")
    }

    @Test("album year, genre & artwork come from the tracks")
    func albumMetadata() {
        let songs = [
            Self.song(id: "1", album: "Mixed", year: 0, track: 1),
            Self.song(id: "2", album: "Mixed", genre: "Rock", year: 1969, track: 2, artwork: "a2.jpg"),
            Self.song(id: "3", album: "Mixed", genre: "Pop", year: 1968, track: 3, artwork: "a3.jpg")
        ]

        let albums = AlbumListBuilder.albums(from: songs)
        #expect(albums.count == 1)
        #expect(albums[0].year == 1969)
        #expect(albums[0].genre == "Rock")
        #expect(albums[0].artworkFilename == "a2.jpg")
    }

    @Test("songs without an album are left out")
    func noAlbum() {
        let songs = [Self.song(id: "1", name: "Single")]
        #expect(AlbumListBuilder.albums(from: songs).isEmpty)
    }

    @Test("title sort uses album sort names and sections by first letter")
    func titleSort() {
        let albums = AlbumListBuilder.albums(from: [
            Self.song(id: "1", album: "The Wall", albumSortName: "Wall, The"),
            Self.song(id: "2", album: "Abbey Road"),
            Self.song(id: "3", album: "Who's Next")
        ])

        let sections = AlbumListBuilder.sections(albums, sortedBy: .title, matching: "")
        #expect(sections.map(\.title) == ["A", "W"])
        #expect(sections[1].albums.map(\.name) == ["The Wall", "Who's Next"])
    }

    @Test("artist sort uses artist sort names and breaks ties by title")
    func artistSort() {
        let albums = AlbumListBuilder.albums(from: [
            Self.song(id: "1", albumArtist: "The Beatles", albumArtistSortName: "Beatles, The", album: "Revolver"),
            Self.song(id: "2", albumArtist: "Cher", album: "Believe"),
            Self.song(id: "3", albumArtist: "The Beatles", albumArtistSortName: "Beatles, The", album: "Abbey Road")
        ])

        let sections = AlbumListBuilder.sections(albums, sortedBy: .artist, matching: "")
        #expect(sections.map(\.title) == ["B", "C"])
        #expect(sections[0].albums.map(\.name) == ["Abbey Road", "Revolver"])
        #expect(sections[1].albums.map(\.name) == ["Believe"])
    }

    @Test("year sort groups by year, oldest first, with unknown years last")
    func yearSort() {
        let albums = AlbumListBuilder.albums(from: [
            Self.song(id: "1", album: "Believe", year: 1998),
            Self.song(id: "2", album: "No Year"),
            Self.song(id: "3", albumArtist: "The Who", albumArtistSortName: "Who, The", album: "Tommy", year: 1969),
            Self.song(id: "4", albumArtist: "The Beatles", albumArtistSortName: "Beatles, The",
                      album: "Abbey Road", year: 1969)
        ])

        let sections = AlbumListBuilder.sections(albums, sortedBy: .year, matching: "")
        #expect(sections.map(\.title) == ["1969", "1998", "Unknown Year"])
        #expect(sections[0].albums.map(\.name) == ["Abbey Road", "Tommy"])
    }

    @Test("search matches album name or artist, case insensitively")
    func search() {
        let albums = AlbumListBuilder.albums(from: [
            Self.song(id: "1", albumArtist: "Cher", album: "Believe"),
            Self.song(id: "2", albumArtist: "The Runaways", album: "Cherry Bomb"),
            Self.song(id: "3", albumArtist: "The Beatles", album: "Abbey Road")
        ])

        let sections = AlbumListBuilder.sections(albums, sortedBy: .title, matching: "cher")
        let names = sections.flatMap { $0.albums.map(\.name) }
        #expect(Set(names) == ["Believe", "Cherry Bomb"])

        #expect(AlbumListBuilder.sections(albums, sortedBy: .title, matching: "xyz").isEmpty)
    }

    @Test("albums with the same name but different artists stay separate")
    func sameNameDifferentArtists() {
        let albums = AlbumListBuilder.albums(from: [
            Self.song(id: "1", albumArtist: "The Beatles", album: "Greatest Hits"),
            Self.song(id: "2", albumArtist: "Cher", album: "Greatest Hits")
        ])
        #expect(albums.count == 2)
    }

    @Test("album lookup finds a song's album with all of its tracks")
    func albumLookup() {
        let songs = [
            Self.song(id: "1", albumArtist: "The Beatles", album: "Greatest Hits", track: 1),
            Self.song(id: "2", albumArtist: "The Beatles", album: "Greatest Hits", track: 2),
            Self.song(id: "3", albumArtist: "Cher", album: "Greatest Hits", track: 1)
        ]

        let album = AlbumListBuilder.album(for: songs[1], in: songs)
        #expect(album?.artistName == "The Beatles")
        #expect(album?.songs.map(\.id) == ["1", "2"])
    }

    @Test("album lookup returns nil for songs without an album")
    func albumLookupNoAlbum() {
        let songs = [Self.song(id: "1", name: "Single")]
        #expect(AlbumListBuilder.album(for: songs[0], in: songs) == nil)
    }
}

import Foundation
import Testing
@testable import Warehouse

@Suite("SongListBuilder")
struct SongListBuilderTests {
    static func song(
        id: String = "id",
        name: String,
        sortName: String = "",
        artist: String = "",
        artistSortName: String = ""
    ) -> Song {
        Song(
            id: id,
            name: name,
            sortName: sortName,
            artistName: artist,
            artistSortName: artistSortName,
            albumArtistName: "",
            albumArtistSortName: "",
            albumName: "",
            albumSortName: "",
            genre: "",
            year: 0,
            duration: 0,
            start: 0,
            finish: 0,
            discNumber: 0,
            trackNumber: 0,
            musicFilename: "\(id).mp3",
            artworkFilename: nil)
    }

    @Test("title sort uses sort names and sections by first letter")
    func titleSortAndSections() {
        let songs = [
            Self.song(id: "1", name: "The End", sortName: "End, The", artist: "The Beatles"),
            Self.song(id: "2", name: "Believe", artist: "Cher"),
            Self.song(id: "3", name: "Baba O'Riley", artist: "The Who")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .title, matching: "")
        #expect(sections.map(\.title) == ["B", "E"])
        #expect(sections[0].songs.map(\.id) == ["3", "2"])
        #expect(sections[1].songs.map(\.id) == ["1"])
    }

    @Test("artist sort uses artist sort names and breaks ties by title")
    func artistSort() {
        let songs = [
            Self.song(id: "1", name: "Let It Be", artist: "The Beatles", artistSortName: "Beatles, The"),
            Self.song(id: "2", name: "Come Together", artist: "The Beatles", artistSortName: "Beatles, The"),
            Self.song(id: "3", name: "Believe", artist: "Cher")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .artist, matching: "")
        #expect(sections.map(\.title) == ["B", "C"])
        #expect(sections[0].songs.map(\.id) == ["2", "1"])
        #expect(sections[1].songs.map(\.id) == ["3"])
    }

    @Test("numbers and symbols go in a # section at the end")
    func symbolSectionLast() {
        let songs = [
            Self.song(id: "1", name: "99 Luftballons"),
            Self.song(id: "2", name: "...Baby One More Time"),
            Self.song(id: "3", name: "Zombie"),
            Self.song(id: "4", name: "Angie")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .title, matching: "")
        #expect(sections.map(\.title) == ["A", "Z", "#"])
        #expect(Set(sections[2].songs.map(\.id)) == ["1", "2"])
    }

    @Test("diacritics fold into plain letter sections")
    func diacriticsFold() {
        let songs = [
            Self.song(id: "1", name: "Élan"),
            Self.song(id: "2", name: "Echo")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .title, matching: "")
        #expect(sections.map(\.title) == ["E"])
        #expect(sections[0].songs.map(\.id) == ["2", "1"])
    }

    @Test("search matches name or artist, case insensitively")
    func searchFilters() {
        let songs = [
            Self.song(id: "1", name: "Believe", artist: "Cher"),
            Self.song(id: "2", name: "Cherry Bomb", artist: "The Runaways"),
            Self.song(id: "3", name: "Angie", artist: "The Rolling Stones")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .title, matching: "cher")
        let ids = sections.flatMap { $0.songs.map(\.id) }
        #expect(Set(ids) == ["1", "2"])

        let empty = SongListBuilder.sections(songs, sortedBy: .title, matching: "xyz")
        #expect(empty.isEmpty)
    }

    @Test("blank search returns everything")
    func blankSearch() {
        let songs = [Self.song(id: "1", name: "Angie")]
        let sections = SongListBuilder.sections(songs, sortedBy: .title, matching: "   ")
        #expect(sections.flatMap(\.songs).count == 1)
    }

    @Test("playlist order keeps the incoming order in a single untitled section")
    func playlistOrder() {
        let songs = [
            Self.song(id: "1", name: "Zombie"),
            Self.song(id: "2", name: "Angie"),
            Self.song(id: "3", name: "Believe", artist: "Cher")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .playlistOrder, matching: "")
        #expect(sections.map(\.title) == [""])
        #expect(sections[0].songs.map(\.id) == ["1", "2", "3"])
    }

    @Test("playlist order still filters by search")
    func playlistOrderSearch() {
        let songs = [
            Self.song(id: "1", name: "Zombie"),
            Self.song(id: "2", name: "Believe", artist: "Cher")
        ]

        let sections = SongListBuilder.sections(songs, sortedBy: .playlistOrder, matching: "cher")
        #expect(sections.count == 1)
        #expect(sections[0].songs.map(\.id) == ["2"])

        let empty = SongListBuilder.sections(songs, sortedBy: .playlistOrder, matching: "xyz")
        #expect(empty.isEmpty)
    }

    @Test("playlistSongs maps track ids in order, skipping unknowns and duplicates")
    func playlistSongs() {
        let songs = [
            Self.song(id: "1", name: "Angie"),
            Self.song(id: "2", name: "Believe"),
            Self.song(id: "3", name: "Zombie")
        ]

        let ordered = SongListBuilder.playlistSongs(songs, trackIds: ["3", "missing", "1", "3"])
        #expect(ordered.map(\.id) == ["3", "1"])
    }

    @Test("empty names fall into the # section")
    func emptyName() {
        let sections = SongListBuilder.sections(
            [Self.song(id: "1", name: "")], sortedBy: .title, matching: "")
        #expect(sections.map(\.title) == ["#"])
    }
}

import Foundation
import Testing
@testable import Warehouse

@Suite("EntityMatcher")
struct EntityMatcherTests {
    static let songs = [
        SearchListBuilderTests.song(id: "1", name: "Believe", artist: "Cher", album: "Believe", year: 1998),
        SearchListBuilderTests.song(id: "2", name: "Strong Enough", artist: "Cher", album: "Believe", year: 1998),
        SearchListBuilderTests.song(id: "3", name: "Yesterday", artist: "The Beatles", album: "Help!", year: 1965),
        SearchListBuilderTests.song(id: "4", name: "Cherry Bomb", artist: "The Runaways", album: "The Runaways", year: 1976)
    ]

    static func playlist(
        id: String,
        name: String,
        trackIds: [String] = [],
        isLibrary: Bool = false,
        isFolder: Bool = false
    ) -> PlaylistItem {
        PlaylistItem(
            id: id, name: name, parentId: "", isLibrary: isLibrary, isFolder: isFolder, trackIds: trackIds)
    }

    static let playlists = [
        playlist(id: "lib", name: "Library", trackIds: ["1", "2", "3", "4"], isLibrary: true),
        playlist(id: "f1", name: "Folder", isFolder: true),
        playlist(id: "p1", name: "Road Trip", trackIds: ["3", "1"]),
        playlist(id: "p2", name: "Empty")
    ]

    @Test("albums resolve by name and by id")
    func albumLookup() {
        let byName = EntityMatcher.albums(in: Self.songs, matching: "believe")
        #expect(byName.map(\.name) == ["Believe"])

        let byId = EntityMatcher.albums(in: Self.songs, ids: byName.map(\.id))
        #expect(byId.map(\.name) == ["Believe"])
        #expect(byId.first?.songs.map(\.id) == ["1", "2"])
    }

    @Test("stale album ids resolve to nothing")
    func staleAlbumId() {
        #expect(EntityMatcher.albums(in: Self.songs, ids: ["cher\u{1F}renamed"]).isEmpty)
    }

    @Test("artists resolve by name and by id, with their songs in album order")
    func artistLookup() throws {
        let byName = EntityMatcher.artists(in: Self.songs, matching: "cher")
        #expect(byName.map(\.name) == ["Cher"])

        let byId = EntityMatcher.artists(in: Self.songs, ids: byName.map(\.id))
        let artist = try #require(byId.first)
        #expect(EntityMatcher.songs(for: artist).map(\.id) == ["1", "2"])
    }

    @Test("songs resolve by name and preserve requested id order")
    func songLookup() {
        let byName = EntityMatcher.songs(in: Self.songs, matching: "cher")
        #expect(byName.map(\.name) == ["Believe", "Cherry Bomb", "Strong Enough"])

        let byId = EntityMatcher.songs(in: Self.songs, ids: ["4", "1", "missing"])
        #expect(byId.map(\.id) == ["4", "1"])
    }

    @Test("playlists exclude folders & the library playlist")
    func playlistLookup() {
        #expect(EntityMatcher.playlists(in: Self.playlists).map(\.name) == ["Empty", "Road Trip"])
        #expect(EntityMatcher.playlists(in: Self.playlists, matching: "road").map(\.id) == ["p1"])
        #expect(EntityMatcher.playlists(in: Self.playlists, matching: "library").isEmpty)
        #expect(EntityMatcher.playlists(in: Self.playlists, ids: ["p1", "f1", "lib"]).map(\.id) == ["p1"])
    }

    @Test("playlist songs come back in playlist order, skipping unknown ids")
    func playlistSongs() {
        let playlist = Self.playlist(id: "p", name: "Mix", trackIds: ["3", "missing", "1"])
        #expect(EntityMatcher.songs(for: playlist, in: Self.songs).map(\.id) == ["3", "1"])
    }
}

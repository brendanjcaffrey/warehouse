import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("LibraryFilter")
struct LibraryFilterTests {
    static func makeLibrary() -> Library {
        var library = Library()
        library.tracks = ["t1", "t2", "t3", "t4"].map { id in
            var track = Track()
            track.id = id
            track.name = "Track \(id)"
            return track
        }

        var playlist1 = Playlist()
        playlist1.id = "p1"
        playlist1.name = "First"
        playlist1.parentID = "folder"
        playlist1.trackIds = ["t1", "t2"]

        var playlist2 = Playlist()
        playlist2.id = "p2"
        playlist2.name = "Second"
        playlist2.trackIds = ["t2", "t3"]

        var folder = Playlist()
        folder.id = "folder"
        folder.name = "Folder"

        var libraryPlaylist = Playlist()
        libraryPlaylist.id = "lib"
        libraryPlaylist.isLibrary = true
        libraryPlaylist.trackIds = ["t1", "t2", "t3", "t4"]

        library.playlists = [playlist1, playlist2, folder, libraryPlaylist]
        library.genres = [1: Name.with { $0.name = "Rock" }]
        library.artists = [2: SortName.with { $0.name = "Artist" }]
        library.albums = [3: SortName.with { $0.name = "Album" }]
        library.trackUserChanges = true
        library.totalFileSize = 999
        library.updateTimeNs = 43
        return library
    }

    @Test("keeps only the selected playlists and the union of their tracks")
    func keepsSelectedPlaylistsAndTracks() {
        let filtered = LibraryFilter.filter(Self.makeLibrary(), playlistIds: ["p1", "p2"])

        #expect(filtered.playlists.map(\.id) == ["p1", "p2"])
        // t2 appears in both playlists but is kept once
        #expect(filtered.tracks.map(\.id) == ["t1", "t2", "t3"])
    }

    @Test("clears parent ids so the watch menu is flat")
    func clearsParentIds() {
        let filtered = LibraryFilter.filter(Self.makeLibrary(), playlistIds: ["p1"])
        #expect(filtered.playlists.count == 1)
        #expect(filtered.playlists[0].parentID.isEmpty)
    }

    @Test("preserves the name maps and library metadata")
    func preservesMetadata() {
        let filtered = LibraryFilter.filter(Self.makeLibrary(), playlistIds: ["p1"])

        #expect(filtered.genres[1]?.name == "Rock")
        #expect(filtered.artists[2]?.name == "Artist")
        #expect(filtered.albums[3]?.name == "Album")
        #expect(filtered.trackUserChanges)
        #expect(filtered.totalFileSize == 999)
        #expect(filtered.updateTimeNs == 43)
    }

    @Test("an empty selection keeps no playlists or tracks")
    func emptySelectionKeepsNothing() {
        let filtered = LibraryFilter.filter(Self.makeLibrary(), playlistIds: [])
        #expect(filtered.playlists.isEmpty)
        #expect(filtered.tracks.isEmpty)
    }

    @Test("unknown playlist ids are ignored")
    func unknownIdsAreIgnored() {
        let filtered = LibraryFilter.filter(Self.makeLibrary(), playlistIds: ["p1", "missing"])
        #expect(filtered.playlists.map(\.id) == ["p1"])
        #expect(filtered.tracks.map(\.id) == ["t1", "t2"])
    }
}

import Foundation
import Testing
@testable import Warehouse

@Suite("PlaylistListBuilder")
struct PlaylistListBuilderTests {
    static func playlist(
        id: String,
        name: String,
        parentId: String = "",
        isLibrary: Bool = false,
        isFolder: Bool = false,
        trackIds: [String] = []
    ) -> PlaylistItem {
        PlaylistItem(
            id: id,
            name: name,
            parentId: parentId,
            isLibrary: isLibrary,
            isFolder: isFolder,
            trackIds: trackIds)
    }

    @Test("top level excludes the library playlist and sorts folders first")
    func topLevel() {
        let playlists = [
            Self.playlist(id: "lib", name: "Library", isLibrary: true),
            Self.playlist(id: "p1", name: "Workout"),
            Self.playlist(id: "f1", name: "Rock", isFolder: true),
            Self.playlist(id: "p2", name: "chill")
        ]

        let rows = PlaylistListBuilder.children(of: "", in: playlists)
        #expect(rows.map(\.id) == ["f1", "p2", "p1"])
    }

    @Test("children returns only a folder's direct children")
    func folderChildren() {
        let playlists = [
            Self.playlist(id: "f1", name: "Rock", isFolder: true),
            Self.playlist(id: "p1", name: "Classic Rock", parentId: "f1"),
            Self.playlist(id: "f2", name: "Subfolder", parentId: "f1", isFolder: true),
            Self.playlist(id: "p2", name: "Nested", parentId: "f2")
        ]

        let rows = PlaylistListBuilder.children(of: "f1", in: playlists)
        #expect(rows.map(\.id) == ["f2", "p1"])
    }

    @Test("empty parent id returns nothing when everything is nested")
    func emptyTopLevel() {
        let playlists = [Self.playlist(id: "p1", name: "Nested", parentId: "f1")]
        #expect(PlaylistListBuilder.children(of: "", in: playlists).isEmpty)
    }

    @Test("watch sections group leaf playlists under their folders")
    func watchSections() {
        let playlists = [
            Self.playlist(id: "lib", name: "Library", isLibrary: true),
            Self.playlist(id: "p1", name: "Workout"),
            Self.playlist(id: "f1", name: "Rock", isFolder: true),
            Self.playlist(id: "p2", name: "Classic Rock", parentId: "f1"),
            Self.playlist(id: "f2", name: "Subfolder", parentId: "f1", isFolder: true),
            Self.playlist(id: "p3", name: "Nested", parentId: "f2")
        ]

        let sections = PlaylistListBuilder.watchSections(in: playlists)
        #expect(sections.map(\.title) == ["", "Rock", "Rock › Subfolder"])
        #expect(sections.map { $0.playlists.map(\.id) } == [["p1"], ["p2"], ["p3"]])
    }

    @Test("watch sections skip folders with no leaf playlists")
    func watchSectionsSkipEmptyFolders() {
        let playlists = [
            Self.playlist(id: "f1", name: "Empty", isFolder: true),
            Self.playlist(id: "p1", name: "Workout")
        ]

        let sections = PlaylistListBuilder.watchSections(in: playlists)
        #expect(sections.map(\.title) == [""])
        #expect(sections[0].playlists.map(\.id) == ["p1"])
    }

    @Test("containing finds a track's playlists but not folders or the library")
    func containing() {
        let playlists = [
            Self.playlist(id: "lib", name: "Library", isLibrary: true, trackIds: ["t1", "t2"]),
            Self.playlist(id: "f1", name: "Folder", isFolder: true, trackIds: ["t1"]),
            Self.playlist(id: "p1", name: "Workout", trackIds: ["t1", "t2"]),
            Self.playlist(id: "p2", name: "chill", trackIds: ["t1"]),
            Self.playlist(id: "p3", name: "Empty", trackIds: [])
        ]

        #expect(PlaylistListBuilder.containing(trackId: "t1", in: playlists).map(\.id) == ["p2", "p1"])
        #expect(PlaylistListBuilder.containing(trackId: "t2", in: playlists).map(\.id) == ["p1"])
        #expect(PlaylistListBuilder.containing(trackId: "t9", in: playlists).isEmpty)
    }
}

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
}

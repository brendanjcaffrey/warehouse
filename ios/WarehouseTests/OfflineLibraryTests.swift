import Foundation
import Testing
@testable import Warehouse

@Suite("legacy watch retention")
@MainActor
struct OfflineLibraryTests {
    static func saveSelection(_ files: FileStore) throws {
        try files.prepare()
        let selections = ["p": ["name": "old selection", "trackIds": ["1"], "filenames": ["1": "1.wav"], "paused": false]]
        try JSONSerialization.data(withJSONObject: selections).write(to: files.rootURL.appending(path: "offline-playlists.json"))
    }

    @Test("saved legacy intent protects local music until phone selection becomes durable")
    func restore() throws {
        let files = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        try Self.saveSelection(files)
        try files.write(.music, "1.wav", data: Data("saved".utf8))
        let cache = FileCache(fileStore: files, budget: { _ in .init(music: 0, artwork: 0) })
        let legacy = OfflineLibrary(fileCache: cache)
        cache.evict()
        #expect(legacy.selectedPlaylistIds == ["p"])
        #expect(files.exists(.music, "1.wav"))
        legacy.retireForPhoneSelection()
        #expect(FileManager.default.fileExists(atPath: files.rootURL.appending(path: "offline-playlists.json").path))
    }
}

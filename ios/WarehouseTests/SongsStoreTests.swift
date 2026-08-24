import Foundation
import Testing
@testable import Warehouse

@Suite("SongsStore")
@MainActor
struct SongsStoreTests {
    static func makeFileStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "songs-store-tests-\(UUID().uuidString)"))
    }

    static func makeLibrary() -> Library {
        var track = Track()
        track.id = "t1"
        track.name = "Believe"
        track.musicFilename = "m1.mp3"
        var library = Library()
        library.tracks = [track]
        return library
    }

    @Test("loading reads which tracks are on disk")
    func loadReadsDownloadedTracks() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())
        let fileStore = Self.makeFileStore()
        try fileStore.write(.music, "m1.mp3", data: Data(count: 10))
        let store = SongsStore(database: database, fileStore: fileStore)

        await store.load()

        let song = try #require(store.songs.first)
        #expect(store.isDownloaded(song))
    }

    @Test("refreshing downloads follows the cache without reloading the library")
    func refreshDownloadsFollowsTheFiles() async throws {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: Self.makeLibrary())
        let fileStore = Self.makeFileStore()
        let store = SongsStore(database: database, fileStore: fileStore)
        await store.load()
        let song = try #require(store.songs.first)
        #expect(!store.isDownloaded(song))

        // the watch pulls tracks in as they play & drops them again once the
        // cache is over budget, both without a sync
        try fileStore.write(.music, "m1.mp3", data: Data(count: 10))
        store.refreshDownloads()
        #expect(store.isDownloaded(song))

        try fileStore.delete(.music, "m1.mp3")
        store.refreshDownloads()
        #expect(!store.isDownloaded(song))
    }
}

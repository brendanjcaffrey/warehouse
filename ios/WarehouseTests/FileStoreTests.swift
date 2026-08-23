import Foundation
import Testing
@testable import Warehouse

@Suite("FileStore")
struct FileStoreTests {
    static func makeStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "filestore-tests-\(UUID().uuidString)"))
    }

    /// names that could climb out of, or stand in for, the type directory
    static let rejectedFilenames = ["../evil.mp3", "a/b.mp3", ""]

    /// a file standing in for what `LibraryClient.downloadFile` hands over
    static func makeSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filestore-source-\(UUID().uuidString)")
        try Data("downloaded".utf8).write(to: url)
        return url
    }

    @Test("prepare creates the music & artwork directories")
    func prepareCreatesDirectories() throws {
        let store = Self.makeStore()
        try store.prepare()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.directoryURL(.music).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: store.directoryURL(.artwork).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("write, exists, list & delete round trip")
    func writeExistsListDelete() throws {
        let store = Self.makeStore()
        let data = Data("hello".utf8)

        #expect(!store.exists(.music, "a.mp3"))
        try store.write(.music, "a.mp3", data: data)
        try store.write(.music, "b.mp3", data: data)
        try store.write(.artwork, "a.jpg", data: data)

        #expect(store.exists(.music, "a.mp3"))
        #expect(!store.exists(.artwork, "a.mp3")) // types are separate directories
        #expect(store.list(.music) == ["a.mp3", "b.mp3"])
        #expect(store.list(.artwork) == ["a.jpg"])
        #expect(try Data(contentsOf: store.fileURL(.music, "a.mp3")) == data)

        try store.delete(.music, "a.mp3")
        #expect(!store.exists(.music, "a.mp3"))
        #expect(store.list(.music) == ["b.mp3"])
    }

    @Test("deleteFiles keeps only the given filenames")
    func deleteFilesKeeping() throws {
        let store = Self.makeStore()
        let data = Data("x".utf8)
        try store.write(.music, "keep.mp3", data: data)
        try store.write(.music, "stale1.mp3", data: data)
        try store.write(.music, "stale2.mp3", data: data)

        store.deleteFiles(.music, keeping: ["keep.mp3", "missing.mp3"])

        #expect(store.list(.music) == ["keep.mp3"])
    }

    @Test("download stats count files & sum their sizes")
    func downloadStats() throws {
        let store = Self.makeStore()
        #expect(store.downloadStats() == DownloadStats())

        try store.write(.music, "a.mp3", data: Data(count: 100))
        try store.write(.music, "b.mp3", data: Data(count: 50))
        try store.write(.artwork, "a.jpg", data: Data(count: 8))

        let stats = store.downloadStats()
        #expect(stats.trackCount == 2)
        #expect(stats.artworkCount == 1)
        #expect(stats.totalBytes == 158)
    }

    @Test("write, moveIn & delete reject filenames that could leave the type directory")
    func mutatorsRejectTraversingFilenames() throws {
        let store = Self.makeStore()
        try store.prepare()
        // sits where "../evil.mp3" would land from the music directory
        let canary = store.rootURL.appending(path: "evil.mp3")
        try Data("canary".utf8).write(to: canary)
        try store.write(.music, "keep.mp3", data: Data("keep".utf8))

        for filename in Self.rejectedFilenames {
            #expect(throws: FileStore.FilenameError.invalid(filename)) {
                try store.write(.music, filename, data: Data("bad".utf8))
            }
            let source = try Self.makeSource()
            #expect(throws: FileStore.FilenameError.invalid(filename)) {
                try store.moveIn(.music, filename, from: source)
            }
            // the temp file is consumed on the rejection path too
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(throws: FileStore.FilenameError.invalid(filename)) {
                try store.delete(.music, filename)
            }
        }

        #expect(try Data(contentsOf: canary) == Data("canary".utf8))
        #expect(store.list(.music) == ["keep.mp3"])
        #expect(store.list(.artwork).isEmpty)
    }

    @Test("an md5 style filename round trips through write, moveIn & delete")
    func validFilenameRoundTrips() throws {
        let store = Self.makeStore()
        let filename = "d41d8cd98f00b204e9800998ecf8427e.mp3"

        try store.write(.music, filename, data: Data("written".utf8))
        #expect(try Data(contentsOf: store.fileURL(.music, filename)) == Data("written".utf8))

        let source = try Self.makeSource()
        try store.moveIn(.music, filename, from: source)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: store.fileURL(.music, filename)) == Data("downloaded".utf8))

        try store.delete(.music, filename)
        #expect(!store.exists(.music, filename))
    }

    @Test("device storage reports a sensible used & total")
    func deviceStorage() throws {
        let storage = try #require(FileStore.deviceStorage())
        #expect(storage.totalBytes > 0)
        #expect(storage.usedBytes > 0)
        #expect(storage.usedBytes <= storage.totalBytes)
        #expect(storage.availableBytes > 0)
        #expect(storage.availableBytes <= storage.totalBytes)
    }
}

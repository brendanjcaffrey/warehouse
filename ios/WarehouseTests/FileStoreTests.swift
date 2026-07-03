import Foundation
import Testing
@testable import Warehouse

@Suite("FileStore")
struct FileStoreTests {
    static func makeStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "filestore-tests-\(UUID().uuidString)"))
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
}

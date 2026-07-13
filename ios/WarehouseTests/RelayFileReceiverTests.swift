import Foundation
import Testing
@testable import Warehouse

@Suite("RelayFileReceiver")
struct RelayFileReceiverTests {
    private func makeStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "receiver-tests-\(UUID().uuidString)"))
    }

    private func makeArrival(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arrival-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("a media file is moved into the store")
    func mediaFileIsMoved() throws {
        let store = makeStore()
        let receiver = RelayFileReceiver(fileStore: store)
        let file = FileToDownload(type: .music, filename: "a.mp3")
        let source = try makeArrival("song bytes")

        let received = receiver.receive(fileAt: source, metadata: FileTransferMetadata.file(file).encode())

        #expect(received == .file(file))
        #expect(store.exists(.music, "a.mp3"))
        // moved, not copied: the system deletes the source after the call
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("a file already in the store is reported without a move")
    func existingFileSkipsMove() throws {
        let store = makeStore()
        try store.write(.music, "a.mp3", data: Data("already here".utf8))
        var moves = 0
        var receiver = RelayFileReceiver(fileStore: store)
        receiver.move = { _, _ in moves += 1 }
        let file = FileToDownload(type: .music, filename: "a.mp3")

        let received = receiver.receive(fileAt: try makeArrival("dupe"), metadata: FileTransferMetadata.file(file).encode())

        #expect(received == .file(file))
        #expect(moves == 0)
    }

    @Test("library data is read into memory")
    func libraryDataIsRead() throws {
        let receiver = RelayFileReceiver(fileStore: makeStore())
        let source = try makeArrival("proto bytes")

        let received = receiver.receive(
            fileAt: source, metadata: FileTransferMetadata.library(updateTimeNs: 9).encode())

        #expect(received == .library(Data("proto bytes".utf8)))
    }

    @Test("an out-of-space move failure is classified as such")
    func outOfSpaceIsClassified() throws {
        var receiver = RelayFileReceiver(fileStore: makeStore())
        receiver.move = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let file = FileToDownload(type: .artwork, filename: "b.jpg")

        let received = receiver.receive(fileAt: try makeArrival("art"), metadata: FileTransferMetadata.file(file).encode())

        #expect(received == .fileOutOfSpace(file))
    }

    @Test("any other move failure is just a failed file")
    func otherFailuresAreFailedFiles() throws {
        var receiver = RelayFileReceiver(fileStore: makeStore())
        receiver.move = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let file = FileToDownload(type: .music, filename: "c.mp3")

        let received = receiver.receive(fileAt: try makeArrival("song"), metadata: FileTransferMetadata.file(file).encode())

        #expect(received == .fileFailed(file))
    }

    @Test("junk metadata is ignored")
    func junkMetadataIsIgnored() throws {
        let receiver = RelayFileReceiver(fileStore: makeStore())

        #expect(receiver.receive(fileAt: try makeArrival("x"), metadata: nil) == .ignored)
        #expect(receiver.receive(fileAt: try makeArrival("x"), metadata: ["kind": "mystery"]) == .ignored)
    }
}

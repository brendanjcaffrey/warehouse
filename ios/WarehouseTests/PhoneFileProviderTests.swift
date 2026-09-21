import Foundation
import Testing
@testable import Warehouse

@Suite("phone cached file provider")
@MainActor
struct PhoneFileProviderTests {
    @Test("incoming files survive the system delegate lifetime")
    func stagesIncomingFile() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("file".utf8).write(to: source)
        let transfer = WatchFileTransfer(type: .artwork, filename: "cover.jpg")
        let (staged, temporary) = try #require(WatchFileTransfer.stage(source, metadata: transfer.encode()))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.removeItem(at: source)
        #expect(staged == transfer)
        #expect(try Data(contentsOf: temporary) == Data("file".utf8))
        #expect(WatchFileTransfer.stage(temporary, metadata: [:]) == nil)
    }

    @Test("only safe file metadata is decoded")
    func validatesMetadata() {
        let transfer = WatchFileTransfer(type: .music, filename: "hash.m4a")
        #expect(WatchFileTransfer(dictionary: transfer.encode()) == transfer)
        for filename in ["", "../secret", "/secret", ".hidden", "nested/file", "null\0file"] {
            var message = transfer.encode()
            message["filename"] = filename
            #expect(WatchFileTransfer(dictionary: message) == nil)
        }
        var message = transfer.encode()
        message["fileType"] = "other"
        #expect(WatchFileTransfer(dictionary: message) == nil)
        message = transfer.encode()
        message["id"] = "bad"
        #expect(WatchFileTransfer(dictionary: message) == nil)
    }

    @Test("the phone serves disk hits, rejects misses and stale credentials, and bounds outstanding transfers")
    func servesDisk() throws {
        let store = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try store.write(.music, "song.m4a", data: Data("music".utf8))
        var queued = [WatchFileTransfer]()
        var urls = [URL]()
        let provider = PhoneFileProvider(
            fileStore: store, currentToken: { "token" }, outstanding: { queued },
            enqueue: { transfer, url in queued.append(transfer); urls.append(url) })
        let hit = WatchFileTransfer(type: .music, filename: "song.m4a")
        #expect(!provider.request(hit, token: "old"))
        #expect(!provider.request(hit, token: ""))
        #expect(!provider.request(WatchFileTransfer(type: .music, filename: "missing"), token: "token"))
        #expect(!provider.request(WatchFileTransfer(type: .music, filename: "../secret"), token: "token"))
        #expect(provider.request(hit, token: "token"))
        #expect(urls == [store.fileURL(.music, hit.filename)])
        #expect(provider.request(hit, token: "token"))
        #expect(queued == [hit])
        #expect(!provider.request(WatchFileTransfer(type: .music, filename: hit.filename), token: "token"))
        queued = (0..<PhoneFileProvider.maximumTransfers).map {
            WatchFileTransfer(type: .music, filename: "\($0).m4a")
        }
        #expect(!provider.request(hit, token: "token"))
    }
}

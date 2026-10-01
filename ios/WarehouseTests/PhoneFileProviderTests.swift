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
        let (staged, temporary) = try #require(try WatchFileTransfer.stage(source, metadata: transfer.encode()))
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(staged == transfer)
        #expect(try Data(contentsOf: temporary) == Data("file".utf8))
        #expect(try WatchFileTransfer.stage(temporary, metadata: [:]) == nil)
    }

    @Test("staging surfaces disk full without consuming the incoming file")
    func stagingDiskFull() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("file".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let transfer = WatchFileTransfer(type: .music, filename: "song.m4a")
        #expect(throws: POSIXError.self) {
            try WatchFileTransfer.stage(source, metadata: transfer.encode(), move: { _, _ in
                throw POSIXError(.ENOSPC)
            })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
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
        #expect(provider.fileSize(.music, filename: "song.m4a", token: "token") == 5)
        #expect(provider.fileSize(.music, filename: "song.m4a", token: "old") == nil)
        #expect(provider.fileSize(.music, filename: "../secret", token: "token") == nil)
        #expect(provider.request(hit, token: "old") == .unauthorized)
        #expect(provider.request(hit, token: "") == .unauthorized)
        #expect(provider.request(WatchFileTransfer(type: .music, filename: "missing"), token: "token") == .cacheMiss)
        #expect(provider.request(WatchFileTransfer(type: .music, filename: "../secret"), token: "token") == .invalidRequest)
        #expect(provider.request(hit, token: "token") == .accepted)
        #expect(urls == [store.fileURL(.music, hit.filename)])
        #expect(provider.request(hit, token: "token") == .accepted)
        #expect(queued == [hit])
        #expect(provider.request(WatchFileTransfer(type: .music, filename: hit.filename), token: "token") == .duplicate)
        queued = (0..<PhoneFileProvider.maximumTransfers).map {
            WatchFileTransfer(type: .music, filename: "\($0).m4a")
        }
        #expect(provider.request(hit, token: "token") == .queueFull)
    }

    @Test("the system queue and progress survive provider recreation without enqueueing duplicates")
    func reconcilesSystemQueue() {
        let store = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let desired = WatchFileTransfer(type: .music, filename: "song.m4a")
        let stale = WatchFileTransfer(type: .music, filename: "old.m4a")
        var cancelled: [UUID] = []
        let provider = PhoneFileProvider(
            fileStore: store, currentToken: { "token" }, outstanding: { [desired, stale] },
            enqueue: { _, _ in Issue.record("reconciliation must use the existing system transfer") },
            cancel: { cancelled.append($0) }, progress: { _ in 0.75 })
        #expect(provider.progress(token: "wrong") == nil)
        #expect(cancelled.isEmpty)
        let restored = provider.progress(token: "token")
        #expect(restored?.map(\.transfer) == [desired, stale])
        #expect(restored?.first?.fraction == 0.75)
        #expect(cancelled.isEmpty)
        // an already queued file remains accepted even if the phone cache
        // no longer holds its source after a sync.
        #expect(provider.request(desired, token: "token") == .accepted)
    }

    @Test("wire progress rejects malformed metadata and nonfinite fractions")
    func progressMetadata() throws {
        let transfer = WatchFileTransfer(type: .music, filename: "song.m4a")
        let progress = PhoneFileProgress(transfer: transfer, fraction: 0.25)
        #expect(PhoneFileProgress(dictionary: progress.encode())?.fraction == 0.25)
        for fraction in [-1.0, 2.0, Double.infinity, Double.nan] {
            #expect(PhoneFileProgress(dictionary: PhoneFileProgress(transfer: transfer, fraction: fraction).encode()) == nil)
        }
        var message = transfer.encode()
        message["generation"] = nil
        #expect(WatchFileTransfer(dictionary: message) == nil)
    }
}

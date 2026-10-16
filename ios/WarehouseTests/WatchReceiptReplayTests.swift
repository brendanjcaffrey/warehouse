import Foundation
import SwiftProtobuf
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch receipt recovery", .serialized)
@MainActor
struct WatchReceiptReplayTests {
    @MainActor
    final class ReceiptForwarder {
        weak var session: WatchPhoneSession?
        func send(_ receipt: WatchContentReceipt) { session?.sendContentReceipt(receipt) }
    }

    @MainActor
    final class Transport {
        var available = false
        var queued = [[String: Any]]()
        var reads = 0
        var sent = 0

        var adapter: WatchPhoneSession.LibraryTransport {
            .init(available: { [self] in available }, outstanding: { [self] in reads += 1; return queued }, enqueue: { [self] in
                queued.append($0)
                if WatchContentReceipt(dictionary: $0) != nil {
                    sent += 1
                }
            })
        }
    }

    @MainActor
    final class Env {
        let metadata: WatchLibraryDeliveryTests.Env
        let content: WatchContentDeliveryTests.Env
        let snapshot: WatchLibrarySnapshot
        let receipts: [WatchContentReceipt]
        let receiver: WatchContentReceiver
        let forwarder = ReceiptForwarder()

        init(count: Int) throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            content = try WatchContentDeliveryTests.Env()
            let snapshot = try content.snapshot(count: count + 1)
            self.snapshot = snapshot
            receipts = (0..<count).map { index in
                WatchContentReceipt(file: WatchContentFile(head: snapshot.head, type: .music, filename: "m\(index).mp3",
                                                          bytes: 1, digest: String(repeating: "0", count: 64)), status: .delivered)
            }
            let directory = content.root.appending(path: "receiver")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(receipts).write(to: directory.appending(path: "receipts.json"))
            let forwarder = forwarder
            receiver = try WatchContentReceiver(fileCache: FileCache(fileStore: content.watchFiles), directory: directory,
                                                send: { forwarder.send($0) }, diagnostics: content.watchDiagnostics)
        }

        func cleanUp() { metadata.cleanUp(); content.cleanUp() }
    }

    @Test("a background activation does not resend the saved receipt history")
    func backgroundActivation() async throws {
        let env = try Env(count: 872)
        defer { env.cleanUp() }
        let library = env.metadata.receiver()
        await library.waitForImport()
        let transport = Transport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter,
                                        sessionState: { (true, false) }, diagnostics: env.content.watchDiagnostics)
        session.content = env.receiver
        session.receivedBackgroundTask()
        transport.available = true
        session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        var completed = false
        session.updateBackgroundLifetime()
        session.lifetime.hold { completed = true }
        try await PlayerStoreTests.waitFor { completed }
        await session.waitForLibraryRequest()
        #expect(transport.sent == 0)
        #expect(env.receiver.receipts == env.receipts)
    }

    @Test("specific phone queries repair receipts after restart without replaying unrelated history", arguments: [false, true])
    func queriedRecovery(missing: Bool) async throws {
        let env = try Env(count: 872)
        defer { env.cleanUp() }
        let source = env.content.root.appending(path: "source")
        let bytes = Data("saved music".utf8)
        try bytes.write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let file = WatchContentFile(head: env.snapshot.head, type: .music, filename: "m0.mp3",
                                    bytes: fingerprint.bytes, digest: fingerprint.digest)
        if !missing { try env.content.watchFiles.write(.music, file.filename, data: bytes) }
        let directory = env.content.root.appending(path: "receiver")
        var ledger = env.receipts
        ledger[0] = .init(file: file, status: .delivered)
        try JSONEncoder().encode(ledger).write(to: directory.appending(path: "receipts.json"))
        let receiver = try WatchContentReceiver(fileCache: FileCache(fileStore: env.content.watchFiles), directory: directory,
                                                send: { env.forwarder.send($0) }, allowsMaintenance: false)
        try await receiver.settledReconcile(head: env.snapshot.head, snapshot: env.snapshot)
        let library = env.metadata.receiver()
        await library.waitForImport()
        let transport = Transport()
        transport.available = true
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter,
                                        sessionState: { (true, false) }, diagnostics: env.content.watchDiagnostics)
        session.content = receiver
        env.forwarder.session = session
        var query = try file.encode()
        query["kind"] = "watchContentQuery"
        session.session(WCSession.default, didReceiveUserInfo: query)
        var completed = false
        session.updateBackgroundLifetime()
        session.lifetime.hold { completed = true }
        try await PlayerStoreTests.waitFor { completed }
        let sent = transport.queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(sent.count == 1)
        #expect(sent.first?.file == file)
        #expect(sent.first?.status == (missing ? .retrying : .delivered))
        #expect(receiver.receipts.count == 872)
        #expect(try env.content.receiver().receipts == receiver.receipts)
        #expect(receiver.receipts.contains { $0.file.id == ledger.last?.file.id })
    }

    @Test("receipt deduplication compares complete identities and permits a new send after system delivery")
    func fullReceiptIdentity() async throws {
        let env = try Env(count: 4)
        defer { env.cleanUp() }
        let transport = Transport()
        transport.available = true
        let original = env.receipts[0]
        let head = WatchLibraryHead(publisher: original.file.head.publisher, revision: 1, libraryID: "another-account",
                                    playlistIDs: original.file.head.playlistIDs, metadataReady: true)
        let impostor = WatchContentReceipt(file: WatchContentFile(id: original.file.id, head: head, type: original.file.type,
                                                                 filename: original.file.filename, bytes: original.file.bytes,
                                                                 digest: original.file.digest), status: .delivered)
        let retry = WatchContentReceipt(file: original.file, status: .retrying)
        transport.queued = try [impostor, retry].map { try $0.encode() }
        let library = env.metadata.receiver()
        await library.waitForImport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter)
        for _ in 0..<2 { session.sendContentReceipt(original) }
        #expect(transport.queued.compactMap(WatchContentReceipt.init(dictionary:)) == [impostor, retry, original])
        transport.queued.removeAll { WatchContentReceipt(dictionary: $0) == original }
        session.sendContentReceipt(original)
        #expect(transport.queued.compactMap(WatchContentReceipt.init(dictionary:)).filter { $0 == original }.count == 1)
    }
}

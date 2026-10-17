import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch background completion", .serialized)
@MainActor
struct WatchBackgroundCompletionReproTests {
    @Test("callbacks registered before idle retain their task through receipt processing")
    func callbackBeforeIdle() async throws {
        try await reproduce(lateMilliseconds: nil)
    }

    @Test("callbacks during settling retain their task through receipt processing", arguments: [0, 29, 58])
    func callbackAfterIdle(milliseconds: Int) async throws {
        try await reproduce(lateMilliseconds: milliseconds)
    }

    private func reproduce(lateMilliseconds: Int?) async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        let content = try WatchContentDeliveryTests.Env()
        let clock = WatchBackgroundLifetimeTests.Clock()
        defer { clock.releaseAll() }
        defer { metadata.cleanUp(); content.cleanUp() }
        let snapshot = try content.snapshot(count: 4)
        _ = try await metadata.watch.expectWatchLibrary(snapshot.head)
        _ = try await metadata.watch.importWatchLibrary(snapshot)
        let library = metadata.receiver()
        await library.waitForImport()

        let bytes = Data("verified local file".utf8)
        let filename = "m0.mp3"
        try content.watchFiles.write(.music, filename, data: bytes)
        let fingerprint = try WatchContentFile.fingerprint(content.watchFiles.fileURL(.music, filename))
        let file = WatchContentFile(head: snapshot.head, type: .music, filename: filename,
                                    bytes: fingerprint.bytes, digest: fingerprint.digest)
        let receipt = WatchContentReceipt(file: file, status: .delivered)
        let directory = content.root.appending(path: "receiver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([receipt]).write(to: directory.appending(path: "receipts.json"))
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let forwarder = WatchReceiptReplayTests.ReceiptForwarder()
        let receiver = try WatchContentReceiver(fileCache: FileCache(fileStore: content.watchFiles), directory: directory,
                                                send: { forwarder.send($0) }, diagnostics: content.watchDiagnostics,
                                                worker: WatchContentWorker(beforeWork: { try await gate.block() }),
                                                allowsMaintenance: false)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        var sent = [WatchContentReceipt]()
        let session = WatchPhoneSession(library: library, libraryTransport: .init(
            available: { true }, outstanding: { [] }, enqueue: { info in
                if let receipt = WatchContentReceipt(dictionary: info) { sent.append(receipt) }
            }), backgroundLifetime: clock.lifetime(), sessionState: { (true, false) },
                                        diagnostics: content.watchDiagnostics, contentDirectory: directory)
        session.allowsMaintenance = { false }
        session.content = receiver
        forwarder.session = session
        content.watchDiagnostics.startProcess()
        content.watchDiagnostics.applicationChanged(.background)
        content.watchDiagnostics.sceneChanged(.background)
        var query = try file.encode()
        query["kind"] = "watchContentQuery"
        var completions = 0
        var sentAtCompletion = [WatchContentReceipt]()
        if lateMilliseconds == nil { session.session(WCSession.default, didReceiveUserInfo: query) }

        // use the production watch delegate's ordering; only the system task completion is substituted.
        session.receivedBackgroundTask()
        library.resume()
        receiver.resume()
        session.updateBackgroundLifetime()
        session.lifetime.hold {
            completions += 1
            sentAtCompletion = sent
        }

        if let lateMilliseconds {
            await library.waitForImport()
            await receiver.waitForWork()
            try await clock.waitForSleeps(1)
            clock.advance(.milliseconds(lateMilliseconds))
            session.session(WCSession.default, didReceiveUserInfo: query)
        }
        #expect(await gate.waitForEntry())
        let pending = receiver.pendingOperations
        let held = session.lifetime.heldTasks
        let callbacks = session.contentActivity.count
        #expect(pending == 1)
        #expect(callbacks == 0)
        #expect(sent.isEmpty)
        // verification must remain protected even after the initial settling window expires.
        clock.advance(.milliseconds(300))
        #expect(completions == 0 && held == 1)
        #expect(session.lifetime.heldTasks == 1)

        let sleeps = clock.delays.count + 1
        gate.release()
        await receiver.waitForWork()
        await library.waitForImport()
        session.updateBackgroundLifetime()
        try await clock.waitForSleeps(sleeps)
        clock.advance(.milliseconds(250))
        try await PlayerStoreTests.waitFor { completions == 1 }
        #expect(sent == [receipt])
        #expect(receiver.receipts == [receipt])
        let events = content.watchDiagnostics.events
        let completed = try #require(events.first { $0.kind == .backgroundCompleted })
        let received = try #require(events.first { $0.kind == .contentQueryReceived && $0.id == file.id })
        let replied = try #require(events.first { $0.kind == .receiptSent && $0.id == file.id })
        #expect(sentAtCompletion == [receipt])
        #expect(received.date <= replied.date && replied.date <= completed.date)
    }
}

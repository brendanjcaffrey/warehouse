import Foundation
import SwiftProtobuf
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch receipt replay", .serialized)
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
        var onEnqueue: (() -> Void)?
        var onReceipt: ((WatchContentReceipt) -> Void)?
        var lastReplayHandledIncoming = false
        var onRead: (() -> Void)?

        var adapter: WatchPhoneSession.LibraryTransport {
            .init(available: { [self] in available }, outstanding: { [self] in reads += 1; onRead?(); return queued }, enqueue: { [self] in
                queued.append($0)
                if let receipt = WatchContentReceipt(dictionary: $0) {
                    sent += 1
                    onReceipt?(receipt)
                    let action = onEnqueue
                    onEnqueue = nil
                    action?()
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

        init(count: Int, persistDiagnostics: Bool = false) throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            content = try WatchContentDeliveryTests.Env()
            if persistDiagnostics {
                content.watchDiagnostics = WatchDiagnostics(logEvents: false, storeURL: content.root.appending(path: "capture.json"))
            }
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

    @Test("replay checkpoints queueing, indexing and sending before releasing its background hold", arguments: [false, true])
    func replayDiagnostics(alreadyQueued: Bool) async throws {
        let env = try Env(count: 32, persistDiagnostics: true)
        defer { env.cleanUp() }
        let transport = Transport()
        defer { transport.onRead = nil; transport.onReceipt = nil }
        if alreadyQueued { transport.queued = try env.receipts.map { try $0.encode() } }
        let library = env.metadata.receiver()
        await library.waitForImport()
        let capture = env.content.watchDiagnostics
        capture.startProcess()
        capture.applicationChanged(.background)
        func restored() -> WatchDiagnosticReport {
            WatchDiagnostics(logEvents: false, storeURL: env.content.root.appending(path: "capture.json"))
                .report(deviceModel: "watch", systemVersion: "26")
        }
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter,
                                        sessionState: { (true, false) }, diagnostics: capture)
        transport.available = true
        session.content = env.receiver
        let scheduled = restored().events.filter { $0.kind == .receiptReplayChanged }
        #expect(scheduled.map { $0.replay?.phase } == [.scheduled])
        let replayID = try #require(scheduled.first?.id)
        transport.onRead = { #expect(restored().events.last { $0.id == replayID }?.replay?.phase == .indexing) }
        transport.onReceipt = { _ in
            #expect(restored().events.last { $0.id == replayID }?.replay?.phase == .replaying)
            let active = session.contentActivity.count
            #expect(active > 0)
        }
        var finished = false
        session.lifetime.hold {
            let event = restored().events.last { $0.id == replayID }
            #expect(event?.replay?.phase == .finished && event?.replay?.result == .completed)
            finished = true
        }
        try await PlayerStoreTests.waitFor { finished }
        let report = restored()
        let events = report.events.filter { $0.id == replayID }
        #expect(events.map { $0.replay?.phase } == [.scheduled, .started, .indexing, .replaying, .passFinished, .finished])
        #expect(events.first { $0.replay?.phase == .replaying }?.replay?.receiptCount == 32)
        #expect(events.first { $0.replay?.phase == .replaying }?.replay?.outstandingCount == (alreadyQueued ? 32 : 0))
        #expect(events.allSatisfy { $0.lifecycle?.application == .background })
        let elapsed = events.compactMap(\.elapsed)
        #expect(elapsed.count == events.count && elapsed == elapsed.sorted())
        #expect(transport.reads == 1 && transport.sent == (alreadyQueued ? 0 : 32))
        #expect(env.receiver.receipts == env.receipts)
        #expect(report.capture?.persistenceFailed == false)
        #expect(report.totals?["receiptReplayChanged:metadata"]?.bytes == 0)
        let data = try #require(report.encoded())
        let decoded = try #require(WatchDiagnosticReport.decode(data))
        #expect(decoded.events.compactMap(\.replay) == report.events.compactMap(\.replay))
    }

    @Test("activation with a full saved ledger lets incoming file callbacks run before replay drains", arguments: [64, 1000])
    func activationReplay(count: Int) async throws {
        let env = try Env(count: count)
        defer { env.cleanUp() }
        try await env.receiver.settledReconcile(head: env.snapshot.head, snapshot: env.snapshot)
        let library = env.metadata.receiver()
        await library.waitForImport()
        let transport = Transport()
        defer { transport.onReceipt = nil; transport.onEnqueue = nil }
        transport.queued = try env.receipts.prefix(count / 2).map { try $0.encode() }
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (transport.available, false) },
                                        diagnostics: env.content.watchDiagnostics,
                                        contentDirectory: env.content.root.appending(path: "receiver"))
        session.content = env.receiver
        env.forwarder.session = session
        let source = env.content.root.appending(path: "incoming")
        try Data("incoming music".utf8).write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let incoming = WatchContentFile(head: env.snapshot.head, type: .music, filename: "m\(count).mp3",
                                        bytes: fingerprint.bytes, digest: fingerprint.digest)
        let info = try incoming.encode()
        transport.onEnqueue = { session.receiveFile(source, metadata: info) }
        transport.onReceipt = { receipt in
            if receipt.file.id == env.receipts.last?.file.id {
                transport.lastReplayHandledIncoming = env.content.watchDiagnostics.events.contains {
                    $0.kind == .contentCallbackHandled && $0.id == incoming.id
                }
            }
        }
        var sentWhenActivated: Int?
        session.onActivated = { sentWhenActivated = transport.sent }
        transport.available = true
        let start = ContinuousClock.now
        session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        try await PlayerStoreTests.waitFor(timeout: .seconds(10)) {
            let active = session.contentActivity.count
            return active == 0
        }
        await session.waitForLibraryRequest()
        await env.receiver.waitForWork()
        print("activation replay count: \(count), outstanding reads: \(transport.reads), duration: \(start.duration(to: .now))")
        #expect(sentWhenActivated == 0)
        #expect(transport.reads <= 4)
        #expect(transport.lastReplayHandledIncoming)
        let events = env.content.watchDiagnostics.events
        #expect(events.contains { $0.kind == .contentCallbackHandled && $0.id == incoming.id })
        #expect(env.receiver.receipts.contains(.init(file: incoming, status: .delivered)))
        let decoded = transport.queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(Set(decoded.map(\.file.id)).count == count + 1)
        #expect(decoded.count == count + 1)
    }

    @Test("interrupted replay preserves the ledger, releases its hold and resumes without duplicate sends")
    func interruptedReplay() async throws {
        let env = try Env(count: 64)
        defer { env.cleanUp() }
        let transport = Transport()
        defer { transport.onReceipt = nil }
        let library = env.metadata.receiver()
        await library.waitForImport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (true, false) },
                                        diagnostics: env.content.watchDiagnostics)
        session.content = env.receiver
        var completed = 0
        transport.onReceipt = { _ in
            let active = session.contentActivity.count
            #expect(active > 0 && completed == 0)
            if transport.sent == 3 { transport.available = false }
        }
        transport.available = true
        session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        session.updateBackgroundLifetime()
        session.lifetime.hold { completed += 1 }
        try await PlayerStoreTests.waitFor { completed == 1 }
        #expect(transport.sent == 3)
        #expect(env.content.watchDiagnostics.events.last { $0.kind == .receiptReplayChanged }?.replay?.result == .unavailable)
        #expect(env.receiver.receipts == env.receipts)
        let restored = try env.content.receiver()
        #expect(restored.receipts == env.receipts)
        transport.onReceipt = nil
        session.content = restored
        transport.available = true
        for _ in 0..<10 { session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil) }
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        await session.waitForLibraryRequest()
        let sent = transport.queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(sent.count == env.receipts.count)
        #expect(Set(sent.map(\.file.id)) == Set(env.receipts.map(\.file.id)))
        #expect(restored.receipts == env.receipts)
        #expect(transport.reads <= 4)
    }

    @Test("selection reconciliation retires receipt replay candidates before another batch sends them")
    func retiredReceipts() async throws {
        let env = try Env(count: 64)
        defer { env.cleanUp() }
        let transport = Transport()
        defer { transport.onReceipt = nil }
        let library = env.metadata.receiver()
        await library.waitForImport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (true, false) })
        session.content = env.receiver
        let head = WatchLibraryHead(publisher: env.snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        transport.onReceipt = { _ in
            do { try env.receiver.reconcile(head: head, snapshot: empty) } catch { Issue.record(error) }
        }
        transport.available = true
        session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        await env.receiver.waitForWork()
        #expect(transport.sent == 1)
        #expect(env.receiver.receipts.isEmpty)
        #expect(try env.content.receiver().receipts.isEmpty)
    }

    @Test("receiver replacement fences the old replay and coalesces delivery of the replacement ledger")
    func receiverReplacement() async throws {
        let old = try Env(count: 64)
        let new = try Env(count: 4)
        defer { old.cleanUp(); new.cleanUp() }
        let transport = Transport()
        let library = old.metadata.receiver()
        await library.waitForImport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (true, false) })
        session.content = old.receiver
        transport.onEnqueue = { session.content = new.receiver }
        transport.available = true
        session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        let sent = transport.queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(sent == [old.receipts[0]] + new.receipts)
        #expect(old.receiver.receipts == old.receipts)
        #expect(new.receiver.receipts == new.receipts)
    }

    @Test("indexed deduplication compares the full receipt across colliding transfer ids and statuses")
    func fullReceiptIdentity() async throws {
        let env = try Env(count: 4)
        defer { env.cleanUp() }
        let transport = Transport()
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
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (true, false) })
        session.content = env.receiver
        transport.available = true
        for _ in 0..<2 { session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil) }
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        let sent = transport.queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(sent == [impostor, retry] + env.receipts)
        transport.queued.removeAll { WatchContentReceipt(dictionary: $0) == original }
        session.sendContentReceipt(original)
        #expect(transport.queued.compactMap(WatchContentReceipt.init(dictionary:)).filter { $0 == original }.count == 1)
    }

    @Test("transport loss before replay starts avoids queue reads and releases the queued background hold")
    func unavailableBeforeStart() async throws {
        let env = try Env(count: 4)
        defer { env.cleanUp() }
        let transport = Transport()
        let library = env.metadata.receiver()
        await library.waitForImport()
        let session = WatchPhoneSession(library: library, libraryTransport: transport.adapter, sessionState: { (true, false) },
                                        diagnostics: env.content.watchDiagnostics)
        transport.available = true
        session.content = env.receiver
        transport.available = false
        var completed = false
        session.lifetime.hold { completed = true }
        #expect(!completed)
        try await PlayerStoreTests.waitFor { completed }
        #expect(transport.reads == 0)
        #expect(transport.queued.isEmpty)
        #expect(env.receiver.receipts == env.receipts)
        let events = env.content.watchDiagnostics.events.filter { $0.kind == .receiptReplayChanged }
        #expect(events.map { $0.replay?.phase } == [.scheduled, .started, .finished])
        #expect(events.last?.replay?.result == .unavailable)
    }
}

import Foundation
import Testing
@testable import Warehouse

@Suite("WatchInventory", .serialized)
@MainActor
struct WatchInventoryTests {
    typealias Env = WatchContentDeliveryTests.Env

    func deliver(_ env: Env, queue: PhoneWatchContentQueue, receiver: WatchContentReceiver) throws {
        while let file = env.outstanding.first {
            let url = try #require(env.queued.last { $0.0.id == file.id }?.1)
            try env.stage(file, url: url)
            receiver.staged(file)
            env.outstanding.removeAll { $0.id == file.id }
            try queue.receive(try #require(env.receipts.last { $0.file == file }))
        }
    }

    func prepared(_ env: Env, count: Int = 4) throws -> (WatchLibrarySnapshot, PhoneWatchContentQueue, WatchContentReceiver) {
        let snapshot = try env.snapshot(count: count)
        try env.cache(snapshot)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        try deliver(env, queue: queue, receiver: receiver)
        return (snapshot, queue, receiver)
    }

    @Test("lost or truncated watch music and artwork are repaired without resending retained files", arguments: [false, true])
    func repairsMissingFiles(_ truncated: Bool) throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
        let artwork = try #require(try snapshot.artwork.first)
        if truncated {
            try env.watchFiles.write(.music, "m0.mp3", data: Data([0]))
            try env.watchFiles.write(.artwork, artwork, data: Data([0]))
        } else {
            try env.watchFiles.delete(.music, "m0.mp3")
            try env.watchFiles.delete(.artwork, artwork)
        }
        let count = env.queued.count
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        try receiver.query(request)
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.progress().music.downloaded == 3)
        #expect(queue.progress().artwork.downloaded == 0)
        #expect(env.queued.count == count + 2)
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
        #expect(receiver.progress().music.downloaded == 4)
        #expect(receiver.progress().artwork.downloaded == 1)
    }

    @Test("bounded partial inventory replies survive relaunch, loss, reordering and duplicate delivery")
    func interruptedInventory() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, originalQueue, originalReceiver) = try prepared(env, count: 130)
        var queue = originalQueue
        var receiver = originalReceiver
        let count = env.queued.count
        for name in ["m0.mp3", "m65.mp3", "m129.mp3"] { try env.watchFiles.delete(.music, name) }
        let artwork = try #require(try snapshot.artwork.first)
        try env.watchFiles.delete(.artwork, artwork)
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        try receiver.query(request)
        let reports = env.inventoryReports
        #expect(reports.count == 3)
        #expect(reports.allSatisfy { $0.entries.count <= WatchInventoryReport.maximumEntries })
        #expect(reports.allSatisfy { ((try? JSONEncoder().encode($0).count) ?? Int.max) < 65_536 })
        try queue.receive(reports[2])
        try deliver(env, queue: queue, receiver: receiver)
        queue = try env.queue()
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.receive(reports[2])
        #expect(queue.diagnosticState().inventoryPending == 128)
        env.now += 61
        queue.resume()
        #expect(env.inventoryRequests.last == request)
        try receiver.query(request)
        for report in reports.reversed() { try queue.receive(report) }
        try deliver(env, queue: queue, receiver: receiver)
        for report in reports { try queue.receive(report) }
        #expect(env.queued.count == count + 4)
        #expect(queue.progress().music.downloaded == 130)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(queue.diagnosticState().inventoryPending == 0)
        #expect(queue.diagnosticState().inventoryCompletedAt == env.now)
        #expect(queue.diagnosticState().inventoryRequestID == nil)
        let requested = env.inventoryRequests.count
        env.now += 61
        queue.resume()
        #expect(env.inventoryRequests.count == requested)
    }

    @Test("watch reinstall defers its inventory until metadata is restored, then repairs all missing files")
    func watchDataLoss() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, queue, _) = try prepared(env)
        try FileManager.default.removeItem(at: env.watchFiles.rootURL)
        try FileManager.default.removeItem(at: env.root.appending(path: "receiver"))
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        var receiver = try env.receiver()
        try receiver.query(request)
        #expect(env.inventoryReports.isEmpty)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: nil)
        #expect(env.inventoryReports.isEmpty)
        #expect(receiver.diagnosticState().inventoryPending == 1)
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.progress().music.downloaded == 0)
        #expect(queue.progress().state != .ready)
        #expect(env.outstanding.count == PhoneWatchContentQueue.maximumTransfers)
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
        #expect(receiver.progress().state == .ready)
        #expect(queue.progress().artwork.downloaded == receiver.progress().artwork.downloaded)
    }

    @Test("newer delivery receipts and unacknowledged files are unaffected by an older inventory scan")
    func newerReceipts() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        receiver.staged(file)
        env.outstanding.removeAll { $0.id == file.id }
        try queue.receive(try #require(env.receipts.last))
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        try receiver.query(request)
        let reports = env.inventoryReports
        try deliver(env, queue: queue, receiver: receiver)
        let count = env.queued.count
        for report in reports { try queue.receive(report) }
        #expect(queue.progress().state == .ready)
        #expect(env.queued.count == count)

        env.now += WatchInventoryRequest.minimumInterval
        queue.requestInventory()
        let next = try #require(env.inventoryRequests.last)
        let unsolicited = WatchInventoryReport(request: next, entries: [.init(type: .music, filename: "unselected.mp3", bytes: 123)])
        try queue.receive(unsolicited)
        #expect(queue.jobs.count == 5)
        #expect(queue.diagnosticState().inventoryPending == 5)
    }

    @Test("forward metadata revisions preserve downloads but stale challenges cannot revoke them")
    func revisionFencing() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, queue, receiver) = try prepared(env)
        queue.requestInventory()
        let original = try #require(env.inventoryRequests.last)
        try env.watchFiles.delete(.music, "m0.mp3")
        try receiver.query(original)
        let stale = env.inventoryReports
        let next = try env.snapshot(count: 4, revision: 2)
        try queue.reconcile(head: next.head, snapshot: next)
        #expect(queue.progress().music.downloaded == 4)
        #expect(env.inventoryRequests.count == 1)
        for report in stale { try queue.receive(report) }
        #expect(queue.progress().music.downloaded == 4)
        env.now += WatchInventoryRequest.minimumInterval
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        #expect(request.head == next.head)
        var wrongHead = next.head
        wrongHead.failed = true
        let invalid = WatchInventoryReport(request: .init(id: request.id, head: wrongHead),
                                           entries: [.init(type: .music, filename: "m0.mp3", bytes: nil)])
        try queue.receive(invalid)
        #expect(queue.progress().music.downloaded == 4)
        try receiver.reconcile(head: next.head, snapshot: next)
        env.inventoryReports.removeAll()
        try receiver.query(request)
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.progress().music.downloaded == 3)
        let oldReceipt = try #require(env.receipts.first { $0.file.filename == "m0.mp3" })
        try queue.receive(oldReceipt)
        #expect(queue.progress().music.downloaded == 3)
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
        #expect(snapshot.head.publisher == next.head.publisher)
    }

    @Test("missing phone sources and storage pressure remain recoverable after an inventory repair")
    func repairWaits() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try prepared(env)
        try env.watchFiles.delete(.music, "m0.mp3")
        try env.files.delete(.music, "m0.mp3")
        queue.requestInventory()
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.progress().state == .needsPhoneSync)
        #expect(queue.progress().music.downloaded == 3)
        try env.files.write(.music, "m0.mp3", data: Data("music m0.mp3".utf8))
        env.now += 61
        queue.resume()
        let file = try #require(env.outstanding.first)
        env.outstanding.removeAll { $0.id == file.id }
        receiver.stagingFailed(file, error: CocoaError(.fileWriteOutOfSpace))
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.progress().state == .storageFull)
        #expect(queue.progress().music.downloaded == 3)
        env.now += 61
        queue.resume()
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
    }

    @Test("inventory messages are validated and cannot grant unverified delivery")
    func validation() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let request = WatchInventoryRequest(head: snapshot.head)
        #expect(WatchInventoryRequest(dictionary: try request.encode()) == request)
        let entry = WatchInventoryReport.Entry(type: .music, filename: "m0.mp3", bytes: 11)
        let valid = WatchInventoryReport(request: request, entries: [entry])
        #expect(WatchInventoryReport(dictionary: try valid.encode()) == valid)
        for entries in [[entry, entry], [], Array(repeating: entry, count: 65),
                        [.init(type: .music, filename: "../outside", bytes: 1)], [.init(type: .music, filename: "m0.mp3", bytes: -1)]] {
            #expect(WatchInventoryReport(dictionary: try WatchInventoryReport(request: request, entries: entries).encode()) == nil)
        }
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.receive(valid)
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("unavailable transport preserves both sides of the challenge across relaunch")
    func offlineRecovery() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, originalQueue, originalReceiver) = try prepared(env)
        var queue = originalQueue
        var receiver = originalReceiver
        env.transportAvailable = false
        queue.requestInventory()
        #expect(env.inventoryRequests.isEmpty)
        queue = try env.queue()
        env.transportAvailable = true
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        receiver.sendInventory = { _ in false }
        try receiver.query(request)
        #expect(env.inventoryReports.isEmpty)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.inventoryReports.count == 1)
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.diagnosticState().inventoryPending == 0)
        #expect(env.queued.count == 5)
    }

    @Test("inventory from another account or publisher cannot affect the replacement library", arguments: [false, true])
    func changedNamespace(_ publisherChanged: Bool) throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, queue, receiver) = try prepared(env)
        queue.requestInventory()
        try receiver.query(try #require(env.inventoryRequests.last))
        let head = WatchLibraryHead(publisher: publisherChanged ? UUID() : snapshot.head.publisher, revision: 2,
                                    libraryID: publisherChanged ? "account" : "other-account",
                                    playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let next = WatchLibrarySnapshot(head: head, libraryData: snapshot.libraryData)
        try queue.reconcile(head: head, snapshot: next)
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(queue.progress().music.downloaded == 0)
        #expect(queue.diagnosticState().inventoryPending == 0)
    }

    @Test("failed inventory persistence cannot report an empty watch or revoke downloaded progress")
    func persistenceFailure() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try prepared(env)
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        let path = env.root.appending(path: "receiver/inventory-requests.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(throws: CocoaError.self) { try receiver.query(request) }
        #expect(throws: CocoaError.self) { try receiver.query(request) }
        #expect(env.inventoryReports.isEmpty)
        #expect(queue.progress().music.downloaded == 4)
        #expect(env.watchDiagnostics.events.contains { $0.kind == .inventoryFailed })
        try FileManager.default.removeItem(at: path)
        try receiver.query(request)
        #expect(env.inventoryReports.count == 1)
    }

    @Test("phone session library requests and report decoding run reconciliation and expose redacted diagnostics")
    func sessionAndDiagnostics() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let phoneCapture = env.root.appending(path: "phone-capture.json")
        env.phoneDiagnostics = WatchDiagnostics(capacity: 4, logEvents: false, storeURL: phoneCapture)
        let (snapshot, queue, receiver) = try prepared(env)
        let session = PhoneWatchSession(onPlay: { _ in },
                                       diagnostics: env.phoneDiagnostics)
        session.content = queue
        var publications = 0
        session.publishLibrary = { publications += 1 }
        let acknowledgedBytes = env.phoneDiagnostics.report(deviceModel: "", systemVersion: "").totals?["phoneAcknowledged:music"]?.bytes
        try env.watchFiles.delete(.music, "m0.mp3")
        session.receive(userInfo: ["kind": "watchLibraryRequest"])
        try await PlayerStoreTests.waitFor { !env.inventoryRequests.isEmpty }
        #expect(publications == 1)
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { session.receive(userInfo: try report.encode()) }
        try await PlayerStoreTests.waitFor { queue.progress().music.downloaded == 3 }
        let restored = WatchDiagnostics(capacity: 4, logEvents: false, storeURL: phoneCapture)
        let report = restored.report(deviceModel: "phone", systemVersion: "26", delivery: queue.diagnosticState())
        #expect(report.totals?["inventoryRequested:metadata"]?.count == 1)
        #expect(report.totals?["inventoryConfirmed:music"]?.count == 3)
        #expect(report.totals?["inventoryMissing:music"]?.count == 1)
        #expect(report.totals?["inventoryMissing:music"]?.bytes == 0)
        #expect(report.totals?["inventoryCompleted:metadata"]?.count == 1)
        #expect(report.totals?["phoneAcknowledged:music"]?.bytes == acknowledgedBytes)
        #expect(report.delivery?.music.delivered.count == 3)
        #expect(report.delivery?.inventoryPending == 0)
        let data = try #require(report.encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("m0.mp3") && !text.contains("account") && !text.contains("p1"))
        #expect(report.delivery?.head == WatchDiagnosticIdentity(snapshot.head))
    }

    @Test("damaged inventory request state does not disable content delivery or its next reconciliation")
    func damagedRequests() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, queue, _) = try prepared(env)
        try Data("damaged".utf8).write(to: env.root.appending(path: "receiver/inventory-requests.json"))
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.progress().state == .ready)
        #expect(env.watchDiagnostics.events.contains { $0.kind == .inventoryFailed })
        try env.watchFiles.delete(.music, "m0.mp3")
        queue.requestInventory()
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        try deliver(env, queue: queue, receiver: receiver)
        #expect(queue.progress().state == .ready)
        #expect(receiver.progress().state == .ready)
    }
}

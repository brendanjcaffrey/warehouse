import Foundation
import Testing
import SwiftProtobuf
@testable import Warehouse

@Suite("WatchContentDelivery", .serialized)
@MainActor
struct WatchContentDeliveryTests {
    @MainActor
    final class Env {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let files: FileStore
        let watchFiles: FileStore
        var phoneDiagnostics: WatchDiagnostics
        var watchDiagnostics: WatchDiagnostics
        var outstanding = [WatchContentFile]()
        var queued = [(WatchContentFile, URL)]()
        var queries = [WatchContentFile]()
        var receipts = [WatchContentReceipt]()
        var reports = [WatchLibraryDeliveryReport]()
        var inventoryRequests = [WatchInventoryRequest]()
        var inventoryReports = [WatchInventoryReport]()
        var manualRequests = [WatchInventoryRequest]()
        var inventoryCompletions = [WatchInventoryCompletion]()
        var now = Date(timeIntervalSince1970: 1000)
        var available: Int64 = 1_000_000_000
        var beforeCommit: () throws -> Void = {}
        var enqueuesEnabled = true
        var transportAvailable = true

        init() throws {
            phoneDiagnostics = WatchDiagnostics(logEvents: false)
            watchDiagnostics = WatchDiagnostics(logEvents: false)
            files = FileStore(rootURL: root.appending(path: "phone-files"))
            watchFiles = FileStore(rootURL: root.appending(path: "watch-files"))
            try files.prepare()
            try watchFiles.prepare()
        }

        func queue(worker: WatchContentWorker = WatchContentWorker()) throws -> PhoneWatchContentQueue {
            try PhoneWatchContentQueue(fileStore: files, directory: root.appending(path: "queue"), transport: .init(
                available: { [self] in transportAvailable }, outstanding: { [self] in outstanding },
                enqueue: { [self] file, url in
                    if enqueuesEnabled { outstanding.append(file); queued.append((file, url)) }
                },
                cancel: { [self] id in outstanding.removeAll { $0.id == id } },
                query: { [self] in queries.append($0) }, report: { [self] in reports.append($0) },
                inventory: { [self] in inventoryRequests.append($0) },
                inventoryCompletion: { [self] in inventoryCompletions.append($0) }),
                now: { [self] in now }, schedulesRetries: false, diagnostics: phoneDiagnostics, worker: worker)
        }

        func receiver(worker: WatchContentWorker = WatchContentWorker()) throws -> WatchContentReceiver {
            let cache = FileCache(fileStore: watchFiles, budget: { _ in .init(music: 1_000_000, artwork: 1_000_000) },
                                  freeSpaceReserve: 0)
            let receiver = try WatchContentReceiver(fileCache: cache, directory: root.appending(path: "receiver"),
                                            availableBytes: { [self] in available },
                                            send: { [self] in receipts.append($0) }, beforeCommit: { [self] in try beforeCommit() },
                                            now: { [self] in now }, diagnostics: watchDiagnostics, worker: worker)
            receiver.sendInventoryRequest = { [self] in manualRequests.append($0); return transportAvailable }
            receiver.sendInventory = { [self] in inventoryReports.append($0); return true }
            return receiver
        }

        func snapshot(count: Int = 300, revision: Int64 = 1) throws -> WatchLibrarySnapshot {
            let library = try WatchLibrarySnapshot.selected(WatchLibraryDeliveryTests.library(count: count), ids: ["p1", "p2"])
            let head = WatchLibraryHead(publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, revision: revision,
                                       libraryID: "account", playlistIDs: ["p1", "p2"], metadataReady: true)
            return WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        }

        func cache(_ snapshot: WatchLibrarySnapshot) throws {
            for name in try snapshot.music { try files.write(.music, name, data: Data("music \(name)".utf8)) }
            for name in try snapshot.artwork { try files.write(.artwork, name, data: Data("artwork \(name)".utf8)) }
        }

        func stage(_ file: WatchContentFile, url: URL) throws {
            try WatchContentReceiver.stage(url, file: file, directory: root.appending(path: "receiver"), availableBytes: available)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("progress counts watch commits rather than phone files or system completion, and survives restart")
    func deliveredProgress() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        var queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(queue.progress().music.downloaded == 0)
        #expect(queue.progress().music.total == 4)
        #expect(queue.progress(playlistID: "p2").music.total == 2)
        let (file, url) = env.queued[0]
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledFinished(file, error: nil)
        #expect(queue.progress().music.downloaded == 0)
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress(playlistID: "p2").music.downloaded == 1)
        #expect(queue.progress().music.downloaded == 0)
        let receipt = try #require(env.receipts.last)
        try await queue.settledReceive(receipt)
        try await queue.settledReceive(receipt)
        queue = try env.queue()
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(queue.progress().music.downloaded == 1)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(queue.progress().state == .waiting)
        #expect(queue.progress(playlistID: "p2").music.downloaded == 1)
    }

    @Test("phone sync preserves acknowledged progress for unchanged selected files")
    func progressAfterPhoneSync() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        var library = WatchLibraryDeliveryTests.library(count: 4)
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        let publisher = try metadata.publisher()
        var queue = try env.queue()
        publisher.onSnapshot = { head, snapshot in queue.update(head: head, snapshot: snapshot) }
        publisher.publish(identity: "account", playlistIDs: ["p1", "p2"])
        await publisher.waitForPublication()
        await queue.waitForWork()
        let snapshot = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: metadata.deliveries[0].0))
        try env.cache(snapshot)
        env.now += 60
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.progress().music.downloaded == 1)
        let (artwork, artworkURL) = try #require(env.queued.first { $0.0.type == .artwork })
        try env.stage(artwork, url: artworkURL)
        await receiver.settledResume()
        env.outstanding.removeAll { $0.id == artwork.id }
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.progress().artwork.downloaded == 1)

        library.tracks[0].playCount += 1
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        publisher.publish(identity: "account", playlistIDs: ["p1", "p2"])
        await publisher.waitForPublication()
        await queue.waitForWork()
        #expect(publisher.head.revision > snapshot.head.revision)
        #expect(queue.errorMessage == nil)
        let next = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: try #require(metadata.deliveries.last).0))
        try await receiver.settledReconcile(head: next.head, snapshot: next)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(queue.progress().music.downloaded == 1)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(queue.progress(playlistID: "p2").music.downloaded == 1)
        #expect(queue.progress().state == .waiting)
        #expect(env.queued.filter { $0.0.type == file.type && $0.0.filename == file.filename }.count == 1)
        #expect(env.queued.filter { $0.0.type == artwork.type && $0.0.filename == artwork.filename }.count == 1)
        let obsolete = try #require(env.queued.first { $0.0.type == .music && $0.0.id != file.id }).0
        try await queue.settledReceive(.init(file: obsolete, status: .delivered))
        #expect(queue.progress().music.downloaded == 1)
        queue = try env.queue()
        #expect(queue.progress().music.downloaded == 1)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(queue.jobs.filter { $0.status != .delivered }.allSatisfy { $0.file?.head == next.head })
    }

    @Test("acknowledged files survive a pending refresh but leave progress when removed from the inventory")
    func progressDuringRefresh() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        var queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = env.queued[0].0
        try await queue.settledReceive(.init(file: file, status: .delivered))
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        try await queue.settledReconcile(head: head, snapshot: nil)
        queue = try env.queue()
        #expect(queue.progress().music.downloaded == 1)
        #expect(queue.progress().state == .preparing)

        var library = try snapshot.library
        let index = try #require(library.tracks.firstIndex { $0.musicFilename == file.filename })
        library.tracks[index].musicFilename = "replacement.mp3"
        let next = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        try await queue.settledReconcile(head: head, snapshot: next)
        #expect(queue.progress().music.downloaded == 0)
        #expect(queue.progress().music.total == 4)
        #expect(!queue.jobs.contains { $0.filename == file.filename })
        try await queue.settledReceive(.init(file: file, status: .delivered))
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("delivery evidence cannot cross account, publisher or backwards revision boundaries", arguments: ["account", "publisher", "revision"])
    func progressIdentityBoundary(_ change: String) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4, revision: 2)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = env.queued[0].0
        try await queue.settledReceive(.init(file: file, status: .delivered))
        #expect(queue.progress().music.downloaded == 1)
        let head = WatchLibraryHead(publisher: change == "publisher" ? UUID() : snapshot.head.publisher,
                                    revision: change == "revision" ? 1 : 3,
                                    libraryID: change == "account" ? "other-account" : "account",
                                    playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let next = WatchLibrarySnapshot(head: head, libraryData: snapshot.libraryData)
        try await queue.settledReconcile(head: head, snapshot: next)
        try await queue.settledReceive(.init(file: file, status: .delivered))
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("storage and permanent failures are visible without marking partial playlists ready")
    func progressFailures() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = env.queued[0].0
        // the receiver's receipt can arrive before the system completion callback.
        try await queue.settledReceive(.init(file: file, status: .storageFull))
        #expect(queue.progress().state == .storageFull)
        #expect(queue.progress().music.downloaded == 0)
        #expect(queue.progress(playlistID: "p2").state == .storageFull)
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledReceive(.init(file: file, status: .failed))
        #expect(queue.progress().state == .failed)
        #expect(queue.progress().music.failed == 1)
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("missing phone files request normal sync even when delivery is unavailable")
    func missingProgress() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let queue = try PhoneWatchContentQueue(fileStore: env.files, directory: env.root.appending(path: "queue"),
                                             transport: .init(available: { false }, outstanding: { [] },
                                                              enqueue: { _, _ in }, cancel: { _ in }, query: { _ in }),
                                             schedulesRetries: false)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(queue.progress().state == .needsPhoneSync)
        #expect(queue.progress().music.total == 4)
        #expect(queue.progress().music.downloaded == 0)
        try env.cache(snapshot)
        #expect(queue.progress().state == .waiting)
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("empty selection and artwork failures have independent music readiness")
    func emptyAndArtworkProgress() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for index in 0..<4 {
            let file = env.queued[index].0
            env.outstanding.removeAll { $0.id == file.id }
            try await queue.settledReceive(.init(file: file, status: .delivered))
        }
        for (file, _) in env.queued where file.type == .artwork {
            try await queue.settledReceive(.init(file: file, status: .failed))
        }
        #expect(queue.progress().state == .ready)
        #expect(queue.progress().music.downloaded == 4)
        #expect(queue.progress().artwork.failed > 0)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        try await queue.settledReconcile(head: head, snapshot: empty)
        #expect(queue.progress().state == .empty)
        #expect(queue.progress().music.total == 0)
        try await queue.settledReceive(.init(file: env.queued[0].0, status: .delivered))
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("phone preparation reports survive out-of-order delivery and restart without inventing watch downloads")
    func preparationReports() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let missing = try #require(env.reports.last)
        #expect(missing.overall.state == .needsPhoneSync)
        #expect(WatchLibraryDeliveryReport(dictionary: try missing.encode()) == missing)
        var receiver = try env.receiver()
        // user-info can arrive before its matching metadata snapshot.
        try receiver.receive(missing)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.progress().state == .needsPhoneSync)
        #expect(receiver.progress(playlistID: "p2").state == .needsPhoneSync)
        #expect(receiver.progress().music.downloaded == 0)
        try env.cache(snapshot)
        env.now += 60
        await queue.settledResume()
        let waiting = try #require(env.reports.last)
        try receiver.receive(waiting)
        try receiver.receive(missing)
        #expect(receiver.progress().state == .waiting)
        let file = env.queued[0].0
        try await queue.settledReceive(.init(file: file, status: .failed))
        try receiver.receive(try #require(env.reports.last))
        #expect(receiver.progress().state == .failed)
        #expect(receiver.progress(playlistID: "p2").state == .failed)
        #expect(receiver.progress().music.downloaded == 0)
        // even a phone report of delivered work cannot advance the local count.
        try await queue.settledReceive(.init(file: file, status: .delivered))
        try receiver.receive(try #require(env.reports.last))
        #expect(receiver.progress().music.downloaded == 0)
        try env.stage(file, url: env.files.fileURL(file.type, file.filename))
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        try await receiver.settledReconcile(head: head, snapshot: empty)
        try receiver.receive(missing)
        #expect(receiver.progress().state == .empty)
        #expect(receiver.progress().music.downloaded == 0)
    }

    @Test("saved library progress stays available during a pending or failed refresh")
    func refreshProgress() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("existing".utf8))
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        var pending = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                       playlistIDs: snapshot.head.playlistIDs)
        try await receiver.settledReconcile(head: pending, snapshot: snapshot)
        #expect(receiver.progress().state == .preparing)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress().music.total == 4)
        pending.failed = true
        try await receiver.settledReconcile(head: pending, snapshot: snapshot)
        #expect(receiver.progress().state == .refreshFailed)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
    }

    @Test("300 cached songs and artwork drain through bounded restartable production queues")
    func bulk() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let phoneCapture = env.root.appending(path: "phone-capture.json")
        let watchCapture = env.root.appending(path: "watch-capture.json")
        env.phoneDiagnostics = WatchDiagnostics(logEvents: false, storeURL: phoneCapture)
        env.watchDiagnostics = WatchDiagnostics(logEvents: false, storeURL: watchCapture)
        let snapshot = try env.snapshot()
        try env.cache(snapshot)
        var queue = try env.queue()
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let total = try snapshot.music.count + snapshot.artwork.count
        #expect(queue.jobs.count == total && env.outstanding.count == 4)
        var index = 0
        while index < total {
            #expect(env.outstanding.count <= 4)
            let (file, url) = env.queued[index]
            try env.stage(file, url: url)
            env.now += 120
            env.outstanding.removeAll { $0.id == file.id }
            // recreation before commit must recover the synchronously staged bytes.
            env.watchDiagnostics = WatchDiagnostics(logEvents: false, storeURL: watchCapture)
            env.phoneDiagnostics = WatchDiagnostics(logEvents: false, storeURL: phoneCapture)
            receiver = try env.receiver()
            await receiver.settledStaged(file)
            try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
            queue = try env.queue()
            try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
            #expect(queue.jobs.filter { $0.status == .delivered }.count == index)
            try await queue.settledReceive(try #require(env.receipts.last))
            index += 1
            await Task.yield()
        }
        #expect(queue.jobs.allSatisfy { $0.status == .delivered })
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        #expect(env.queued.count == total)
        let phone = env.phoneDiagnostics.report(deviceModel: "phone", systemVersion: "26", delivery: queue.diagnosticState())
        let watch = env.watchDiagnostics.report(deviceModel: "watch", systemVersion: "26", delivery: receiver.diagnosticState())
        #expect(phone.capture!.droppedEvents > 0 && watch.capture!.droppedEvents > 0)
        #expect(phone.totals?["contentEnqueued:music"]?.count == 300)
        #expect(phone.totals?["phoneAcknowledged:music"]?.count == 300)
        #expect(watch.totals?["contentCommitted:music"]?.count == 300)
        #expect(phone.delivery?.music.delivered.count == 300)
        #expect(watch.delivery?.music.delivered.count == 300)
        #expect(phone.delivery?.music.delivered.bytes == watch.delivery?.music.delivered.bytes)
        #expect(phone.delivery?.head == watch.delivery?.head)
        #expect(watch.delivery?.localMusic?.count == 300)
        #expect(phone.delivery?.receiptWait == 0)
        #expect(watch.delivery?.stagedFiles == 0)
        let exported = try #require(watch.encoded())
        #expect(WatchDiagnosticReport.decode(exported)?.totals?["contentCommitted:music"]?.count == 300)
        let inbox = WatchDiagnosticInbox(directory: env.root.appending(path: "reports"))
        #expect(inbox.receive(exported, phone: phone))
        #expect(inbox.reports.count == 2)
    }

    @Test("lost acknowledgments query verified storage without retransferring, and source copies survive phone cleanup")
    func lostReceiptAndCleanup() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        var queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        env.now += 120
        await queue.settledResume()
        #expect(env.outstanding.count == 4 && env.queued.count == 4)
        let original = try Data(contentsOf: url)
        env.files.deleteFiles(.music, keeping: [])
        env.files.deleteFiles(.artwork, keeping: [])
        #expect(try Data(contentsOf: url) == original)
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledFinished(file, error: nil)
        #expect(queue.jobs.first { $0.file == file }?.status == .awaitingReceipt)
        #expect(queue.diagnosticState().receiptWait == 1)
        #expect(env.phoneDiagnostics.report(deviceModel: "", systemVersion: "").totals?["contentCompleted:music"]?.count == 1)
        #expect(env.queries.contains(file))
        queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let queuedCount = env.queued.count
        try await receiver.settledQuery(file)
        try await queue.settledReceive(try #require(env.receipts.last))
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        #expect(env.queued.count <= queuedCount + 1)
        #expect(env.queued.filter { $0.0.id == file.id }.count == 1)
        let phone = env.phoneDiagnostics.report(deviceModel: "", systemVersion: "")
        let watch = env.watchDiagnostics.report(deviceModel: "", systemVersion: "")
        #expect(phone.totals?["phoneAcknowledged:music"]?.count == 1)
        #expect(watch.totals?["contentCommitted:music"]?.count == 1)
        #expect(watch.totals?["contentReused:music"] == nil)
        #expect(watch.totals?["receiptSent:music"]?.count == 2)
    }

    @Test("file before context and snapshot survives recreation; a deselection rejects delayed bytes and receipts")
    func orderingAndDeselection() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        await receiver.settledResume()
        #expect(env.watchFiles.list(.music).isEmpty && env.receipts.isEmpty)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: nil)
        #expect(env.receipts.isEmpty)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.watchFiles.exists(file.type, file.filename))
        let receipt = try #require(env.receipts.last)
        var emptyHead = snapshot.head
        emptyHead = .init(publisher: emptyHead.publisher, revision: 2, libraryID: "account", playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: emptyHead, libraryData: try Library().serializedData())
        let delayed = env.root.appending(path: "delayed")
        try Data(contentsOf: url).write(to: delayed)
        try await queue.settledReconcile(head: emptyHead, snapshot: empty)
        try await queue.settledReceive(receipt)
        #expect(queue.jobs.isEmpty)
        try env.watchFiles.delete(file.type, file.filename)
        try env.stage(file, url: delayed)
        try await receiver.settledReconcile(head: emptyHead, snapshot: empty)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(queue.jobs.isEmpty)
    }

    @Test("storage admission pauses without evicting selected downloads, then automatically retries")
    func storageRetry() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.watchFiles.write(.music, "m3.mp3", data: Data("retained".utf8))
        try env.stage(file, url: url)
        env.available = 0
        // the staged bytes themselves fit, but the device cannot keep its safety reserve.
        receiver = try WatchContentReceiver(
            fileCache: FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) }),
            directory: env.root.appending(path: "receiver"), availableBytes: { env.available },
            send: { env.receipts.append($0) }, diagnostics: env.watchDiagnostics)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .storageFull)
        #expect(receiver.diagnosticState().music.states["storageFull"] == 1)
        #expect(env.watchDiagnostics.events.contains { $0.kind == .contentStorageFull && $0.id == file.id })
        #expect(env.watchFiles.exists(.music, "m3.mp3"))
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledReceive(try #require(env.receipts.last))
        let count = env.queued.count
        await queue.settledResume()
        #expect(env.queued.count == count)
        for other in Array(env.outstanding) {
            env.outstanding.removeAll { $0.id == other.id }
            try await queue.settledReceive(.init(file: other, status: .delivered))
        }
        env.now += 60
        env.available = 1_000_000_000
        await queue.settledResume()
        #expect(env.queued.filter { $0.0.id == file.id }.count == 2)
        try env.stage(file, url: url)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }

    @Test("corrupt and unsolicited files fail safely; interrupted commits retry from the durable inbox")
    func integrityAndInterruption() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.stage(file, url: url)
        env.beforeCommit = { throw CocoaError(.fileWriteUnknown) }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .retrying && !env.watchFiles.exists(file.type, file.filename))
        env.beforeCommit = {}
        env.now += 60
        let restored = try env.receiver()
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .delivered)
        let (bad, badURL) = env.queued[1]
        try env.stage(bad, url: badURL)
        try Data("corrupt".utf8).write(to: env.root.appending(path: "receiver/\(bad.id.uuidString)/bytes"))
        await restored.settledResume()
        #expect(env.receipts.last?.status == .failed)
        #expect(!env.watchFiles.exists(bad.type, bad.filename))
        let unsolicited = WatchContentFile(head: snapshot.head, type: .music, filename: "removed.mp3", bytes: file.bytes, digest: file.digest)
        try env.stage(unsolicited, url: url)
        await restored.settledResume()
        #expect(!env.watchFiles.exists(.music, "removed.mp3"))
        let wrongType = WatchContentFile(head: snapshot.head, type: .artwork, filename: file.filename, bytes: file.bytes, digest: file.digest)
        try env.stage(wrongType, url: url)
        await restored.settledResume()
        #expect(!env.watchFiles.exists(.artwork, file.filename))
        let traversal = WatchContentFile(head: snapshot.head, type: .music, filename: "../escape", bytes: file.bytes, digest: file.digest)
        #expect(throws: FileStore.FilenameError.self) { try env.stage(traversal, url: url) }
        var invalid = file
        invalid.version = 99
        #expect(throws: WatchLibraryError.self) { try env.stage(invalid, url: url) }
    }

    @Test("transient errors back off, permanent failures free a slot, and cache misses stay pending")
    func errorIsolation() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 6)
        try env.cache(snapshot)
        try env.files.delete(.music, "m5.mp3")
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let transient = env.queued[0].0
        env.outstanding.removeAll { $0.id == transient.id }
        try await queue.settledFinished(transient, error: URLError(.networkConnectionLost))
        let count = env.queued.count
        await queue.settledResume()
        #expect(env.queued.count == count)
        let permanent = env.queued[1].0
        env.outstanding.removeAll { $0.id == permanent.id }
        try await queue.settledFinished(permanent, error: CocoaError(.fileReadNoPermission))
        #expect(queue.jobs.first { $0.file == permanent }?.status == .failed)
        #expect(env.queued.count > count)
        for file in Array(env.outstanding) {
            env.outstanding.removeAll { $0.id == file.id }
            try await queue.settledReceive(.init(file: file, status: .delivered))
        }
        env.now += 60
        await queue.settledResume()
        #expect(env.queued.filter { $0.0.id == transient.id }.count == 2)
        #expect(queue.jobs.first { $0.filename == "m5.mp3" }?.status == .missingOnPhone)
        #expect(env.outstanding.count <= 4)
    }

    @Test("same library names from a prior account cannot establish current delivery")
    func changedIdentity() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "other-account",
                                    playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let next = WatchLibrarySnapshot(head: head, libraryData: snapshot.libraryData)
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: head, snapshot: next)
        #expect(env.watchFiles.list(.music).isEmpty)
        try await queue.settledReconcile(head: head, snapshot: next)
        try await queue.settledReceive(.init(file: file, status: .delivered))
        #expect(!queue.jobs.contains { $0.status == .delivered })
        #expect(env.outstanding.allSatisfy { $0.head == head })
    }

    @Test("a commit followed by failed receipt persistence is recovered without moving the file again")
    func interruptedAcknowledgment() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let cache = FileCache(fileStore: env.watchFiles)
        var refreshed = 0
        cache.onMusicChanged = { refreshed += 1 }
        let receiver = try WatchContentReceiver(
            fileCache: cache, directory: env.root.appending(path: "receiver"),
            availableBytes: { env.available }, send: { env.receipts.append($0) },
            beforeReceipt: { throw CocoaError(.fileWriteUnknown) }, diagnostics: env.watchDiagnostics)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.errorMessage != nil)
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
        #expect(env.receipts.isEmpty)
        let restored = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                 availableBytes: { env.available }, send: { env.receipts.append($0) },
                                                 diagnostics: env.watchDiagnostics)
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .delivered)
        #expect(refreshed == 1)
        let capture = env.watchDiagnostics.report(deviceModel: "", systemVersion: "")
        #expect(capture.totals?["contentCommitted:music"]?.count == 1)
        #expect(capture.totals?["contentReused:music"] == nil)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }

    @Test("phone selection publishes inventory into file delivery and watch metadata authorizes its commit")
    func selectedPipeline() async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let env = try Env()
        defer { env.cleanUp() }
        try await metadata.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 300), sourceIdentity: "account")
        let queue = try env.queue()
        let publisher = try metadata.publisher()
        publisher.onSnapshot = { head, snapshot in queue.update(head: head, snapshot: snapshot) }
        for index in 0..<300 { try env.files.write(.music, "m\(index).mp3", data: Data("music".utf8)) }
        publisher.publish(identity: "account", playlistIDs: ["p1", "p2"])
        await publisher.waitForPublication()
        await queue.waitForWork()
        #expect(queue.jobs.filter { $0.type == .music }.count == 300)
        let incoming = metadata.receiver()
        incoming.expect(publisher.head)
        try metadata.stage(0)
        incoming.received()
        await incoming.waitForImport()
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: incoming.head, snapshot: incoming.snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        await receiver.settledResume()
        let session = PhoneWatchSession(onPlay: { _ in })
        session.content = queue
        session.receive(userInfo: try #require(env.receipts.last).encode())
        await Task.yield()
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        try await queue.settledInvalidate(identity: nil, playlistIDs: [])
        #expect(queue.jobs.isEmpty)
        #expect(env.outstanding.isEmpty)
    }

    @Test("selected music and artwork survive eviction, and already verified bytes need no staging space")
    func retainedFilesAndStagingPressure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for type in LibraryFileType.allCases {
            for name in env.files.list(type) {
                try env.watchFiles.write(type, name, data: Data(contentsOf: env.files.fileURL(type, name)))
            }
        }
        #expect(cache.evict().isEmpty)
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        let file = env.queued[0].0
        await receiver.settledStagingFailed(file, error: CocoaError(.fileWriteOutOfSpace))
        #expect(env.receipts.last?.status == .delivered)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }

    @Test("recreation between queue persistence and enqueue repairs intent through receipts before retrying")
    func interruptedEnqueue() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        env.enqueuesEnabled = false
        var queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(queue.jobs.first?.file)
        #expect(env.outstanding.isEmpty && env.queued.isEmpty)
        env.enqueuesEnabled = true
        queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(queue.jobs.first?.status == .awaitingReceipt)
        #expect(env.queries.contains(file))
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for query in env.queries {
            try await receiver.settledQuery(query)
            try await queue.settledReceive(try #require(env.receipts.last))
        }
        #expect(queue.jobs.first?.status == .retrying)
        env.now += 60
        await queue.settledResume()
        #expect(env.queued.contains { $0.0 == file })
        #expect(env.outstanding.count <= 4)
        #expect(!queue.jobs.contains { $0.status == .delivered })
    }

    @Test("watch commit backoff survives recreation and permanent commit failure does not halt other files")
    func watchCommitRetries() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for (file, url) in env.queued.prefix(2) { try env.stage(file, url: url) }
        var calls = 0
        env.beforeCommit = { calls += 1; throw CocoaError(.fileWriteUnknown) }
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(calls == 2 && env.receipts.allSatisfy { $0.status == .retrying })
        #expect(env.watchDiagnostics.events.contains { $0.kind == .contentRetry && $0.errorCode == NSFileWriteUnknownError })
        #expect(receiver.diagnosticState().music.states["retrying"] == 2)
        receiver = try env.receiver()
        env.beforeCommit = { calls += 1 }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        await receiver.settledResume()
        #expect(calls == 2 && env.watchFiles.list(.music).isEmpty)
        env.now += 60
        await receiver.settledResume()
        #expect(calls == 4 && env.watchFiles.list(.music).count == 2)
        env.receipts.removeAll()
        for (file, url) in env.queued.suffix(2) { try env.stage(file, url: url) }
        calls = 0
        env.beforeCommit = { calls += 1; if calls == 1 { throw CocoaError(.fileWriteNoPermission) } }
        await receiver.settledResume()
        #expect(calls == 2)
        #expect(env.receipts.contains { $0.status == .failed })
        #expect(env.receipts.contains { $0.status == .delivered })
    }

    @Test("connectivity background completion waits across delegate staging and the main-actor commit hop")
    func backgroundContentLifetime() {
        let activity = WatchContentActivity()
        let lifetime = WatchLibraryBackgroundLifetime()
        var finished = 0
        activity.begin()
        lifetime.update(activated: true, contentPending: false, importsPending: activity.count)
        lifetime.hold { finished += 1 }
        #expect(finished == 0)
        activity.end()
        lifetime.update(activated: true, contentPending: false, importsPending: activity.count)
        #expect(finished == 1)
    }

    @Test("an unreceived snapshot preserves selected files; authoritative empty selection removes them")
    func authoritativeCleanup() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        for name in try snapshot.music { try env.watchFiles.write(.music, name, data: Data("selected".utf8)) }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        try await receiver.settledReconcile(head: head, snapshot: nil)
        cache.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        try await receiver.settledReconcile(head: head, snapshot: snapshot)
        cache.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        try await receiver.settledReconcile(head: head, snapshot: empty)
        #expect(env.watchFiles.list(.music).isEmpty)
    }

    @Test("relaunch restores phone retention before eviction and legacy offline selection cannot replace it")
    func authoritativeRestart() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for name in try snapshot.music { try env.watchFiles.write(.music, name, data: Data("selected".utf8)) }
        for name in try snapshot.artwork { try env.watchFiles.write(.artwork, name, data: Data("selected".utf8)) }
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let legacy = OfflineLibrary(fileCache: restored)
        restored.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        #expect(legacy.selectedPlaylistIds.isEmpty)
    }

    @Test("membership edits, shared files, deleted playlists and changed names follow phone inventory")
    func mirroredMembership() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        for name in try original.music { try env.watchFiles.write(.music, name, data: Data("valid".utf8)) }
        for name in try original.artwork { try env.watchFiles.write(.artwork, name, data: Data("valid".utf8)) }
        try await receiver.settledReconcile(head: original.head, snapshot: original)
        let head = WatchLibraryHead(publisher: original.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: ["p2"], metadataReady: true)
        var library = try original.library
        library = try WatchLibrarySnapshot.selected(library, ids: ["p2"])
        let subset = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        try await receiver.settledReconcile(head: head, snapshot: subset)
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "m1.mp3"])
        #expect(env.watchFiles.list(.artwork) == (try subset.artwork))
        library.tracks[0].musicFilename = "replacement.mp3"
        library.tracks[0].artworkFilename = "replacement.jpg"
        library.tracks.removeAll { $0.id == "t1" }
        library.playlists[0].trackIds = ["t0"]
        let changedHead = WatchLibraryHead(publisher: head.publisher, revision: 3, libraryID: "account",
                                           playlistIDs: ["p2"], metadataReady: true)
        let changed = WatchLibrarySnapshot(head: changedHead, libraryData: try library.serializedData())
        try await receiver.settledReconcile(head: changedHead, snapshot: changed)
        #expect(env.watchFiles.list(.music).isEmpty)
        #expect(env.watchFiles.list(.artwork).isEmpty)
        // additions remain desired, and arriving bytes enter the new inventory.
        try env.cache(changed)
        let queue = try env.queue()
        try await queue.settledReconcile(head: changedHead, snapshot: changed)
        for (file, url) in env.queued { try env.stage(file, url: url) }
        await receiver.settledResume()
        #expect(env.watchFiles.list(.music) == ["replacement.mp3"])
        #expect(env.watchFiles.list(.artwork) == ["replacement.jpg"])
    }

    @Test("deselection and library replacement preserve active local playback until its files are released")
    func cleanupDuringPlayback() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let songs = PlayerStoreTests.songs(2)
        var library = Library()
        library.tracks = songs.map { song in Track.with { $0.id = song.id; $0.musicFilename = song.musicFilename } }
        library.playlists = [Playlist.with { $0.id = "p"; $0.trackIds = songs.map(\.id) }]
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: ["p"], metadataReady: true)
        let snapshot = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        for song in songs { try env.watchFiles.write(.music, song.musicFilename, data: PlayerStoreTests.musicBytes) }
        try await receiver.settledReconcile(head: head, snapshot: snapshot)
        let player = PlayerStore(fileStore: env.watchFiles, fileCache: cache, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { true })
        cache.onMusicChanged = { [weak player] in player?.downloadsChanged() }
        player.play(songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack }
        let emptyHead = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "replacement",
                                         playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: emptyHead, libraryData: try Library().serializedData())
        try await receiver.settledReconcile(head: emptyHead, snapshot: empty)
        #expect(player.song?.id == "1" && player.hasLoadedTrack)
        #expect(env.watchFiles.exists(.music, "1.wav"))
        player.playSelected([songs[1]], startingAt: 0, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.song?.id == "2" && player.hasLoadedTrack }
        #expect(!env.watchFiles.exists(.music, "1.wav"))
        #expect(env.watchFiles.exists(.music, "2.wav"))
        player.pause()
    }

    @Test("migration persistence failure preserves legacy state and retries without accepting premature content")
    func migrationFailure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        var fails = true
        let cache = FileCache(fileStore: env.watchFiles, beforeWatchSelectionSave: {
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
        })
        try OfflineLibraryTests.saveSelection(env.watchFiles)
        let offline = OfflineLibrary(fileCache: cache)
        try env.watchFiles.write(.music, "1.wav", data: PlayerStoreTests.musicBytes)
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        await receiver.settledResume()
        offline.retireForPhoneSelection()
        #expect(offline.selectedPlaylistIds == ["p"])
        #expect(env.watchFiles.exists(.music, "1.wav"))
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(FileManager.default.fileExists(atPath: env.watchFiles.rootURL.appending(path: "offline-playlists.json").path))
        fails = false
        await receiver.settledResume()
        offline.retireForPhoneSelection()
        #expect(offline.selectedPlaylistIds.isEmpty)
        #expect(env.watchFiles.exists(file.type, file.filename))
        #expect(!env.watchFiles.exists(.music, "1.wav"))
        #expect(!FileManager.default.fileExists(atPath: env.watchFiles.rootURL.appending(path: "offline-playlists.json").path))
    }

    @Test("selected files survive unknown capacity and concurrent reservations; restart drops stale reservations")
    func capacityAndReservations() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) }, freeSpaceReserve: 10)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.watchFiles.write(.music, "m0.mp3", data: Data(count: 40))
        #expect(!cache.reserve(.music, "m1.mp3", bytes: 30, availableBytes: nil, allowOversized: true))
        #expect(!cache.reserve(.music, "m1.mp3", bytes: 300, availableBytes: 100, allowOversized: true))
        #expect(cache.reserve(.music, "m1.mp3", bytes: 30, availableBytes: 60, allowOversized: true))
        #expect(!cache.reserve(.music, "m2.mp3", bytes: 30, availableBytes: 60, allowOversized: true))
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) }, freeSpaceReserve: 10)
        #expect(restored.reservedBytes(.music, "m1.mp3") == nil)
        restored.evict()
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
        #expect(restored.reserve(.music, "m2.mp3", bytes: 30, availableBytes: 60, allowOversized: true))
    }

    @Test("first migration waits for a valid snapshot before collecting existing downloads")
    func firstSnapshotPending() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        for name in ["old.mp3", "m0.mp3", "m1.mp3"] { try env.watchFiles.write(.music, name, data: Data("existing".utf8)) }
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: nil)
        cache.evict()
        #expect(env.watchFiles.list(.music) == ["old.mp3", "m0.mp3", "m1.mp3"])
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "m1.mp3"])
    }

    @Test("disk-full commit keeps selected downloads and pending intent, and verified migration reuses existing bytes")
    func commitFullAndReuse() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        env.beforeCommit = { throw CocoaError(.fileWriteOutOfSpace) }
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .storageFull)
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .storageFull)
        env.now += 60
        env.beforeCommit = {}
        await queue.settledResume()
        try env.stage(file, url: url)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        let destination = env.watchFiles.fileURL(file.type, file.filename)
        let oldDate = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: destination.path)
        try env.stage(file, url: env.files.fileURL(file.type, file.filename))
        env.beforeCommit = { Issue.record("valid existing downloads should not be rewritten") }
        await receiver.settledResume()
        #expect(file.matches(destination))
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date == oldDate)
    }

    @Test("unreadable retention preserves downloads and the legacy manifest until valid intent repairs it")
    func damagedRetention() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try env.watchFiles.write(.music, "m0.mp3", data: Data("valid".utf8))
        try env.watchFiles.write(.music, "old.mp3", data: Data("legacy".utf8))
        let manifest = env.watchFiles.rootURL.appending(path: "offline-playlists.json")
        try Data("legacy state".utf8).write(to: manifest)
        try Data("damaged".utf8).write(to: env.watchFiles.rootURL.appending(path: "watch-selection.json"))
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let offline = OfflineLibrary(fileCache: cache)
        cache.evict()
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "old.mp3"])
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        let snapshot = try env.snapshot(count: 4)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        offline.retireForPhoneSelection()
        #expect(env.watchFiles.list(.music) == ["m0.mp3"])
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        restored.evict()
        #expect(env.watchFiles.list(.music) == ["m0.mp3"])
    }

    @Test("failed replacement persistence preserves the durable selection across recreation")
    func failedReplacement() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        var fails = false
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) },
                              beforeWatchSelectionSave: { if fails { throw CocoaError(.fileWriteUnknown) } })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        let snapshot = try env.snapshot(count: 4)
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for name in try snapshot.music { try env.watchFiles.write(.music, name, data: Data("selected".utf8)) }
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        fails = true
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: head, snapshot: empty) }
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        restored.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        let reopened = try WatchContentReceiver(fileCache: restored, directory: env.root.appending(path: "receiver"), send: { _ in })
        try reopened.reconcile(head: head, snapshot: empty)
        #expect(env.watchFiles.list(.music).isEmpty)
    }

    @Test("changed bytes under an active filename wait for player release before committing")
    func replacingActiveFile() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        let cache = FileCache(fileStore: env.watchFiles)
        let oldBytes = Data("playing bytes".utf8)
        try env.watchFiles.write(file.type, file.filename, data: oldBytes)
        cache.setInUse(file.type, [file.filename])
        try env.stage(file, url: url)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(try Data(contentsOf: env.watchFiles.fileURL(file.type, file.filename)) == oldBytes)
        #expect(env.receipts.isEmpty)
        cache.setInUse(file.type, [])
        try await PlayerStoreTests.waitFor { env.receipts.last?.status == .delivered }
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
    }
}

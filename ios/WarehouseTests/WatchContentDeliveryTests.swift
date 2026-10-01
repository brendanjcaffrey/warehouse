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
        var outstanding = [WatchContentFile]()
        var queued = [(WatchContentFile, URL)]()
        var queries = [WatchContentFile]()
        var receipts = [WatchContentReceipt]()
        var now = Date(timeIntervalSince1970: 1000)
        var available: Int64 = 1_000_000_000
        var beforeCommit: () throws -> Void = {}
        var enqueuesEnabled = true

        init() throws {
            files = FileStore(rootURL: root.appending(path: "phone-files"))
            watchFiles = FileStore(rootURL: root.appending(path: "watch-files"))
            try files.prepare()
            try watchFiles.prepare()
        }

        func queue() throws -> PhoneWatchContentQueue {
            try PhoneWatchContentQueue(fileStore: files, directory: root.appending(path: "queue"), transport: .init(
                available: { true }, outstanding: { [self] in outstanding },
                enqueue: { [self] file, url in
                    if enqueuesEnabled { outstanding.append(file); queued.append((file, url)) }
                },
                cancel: { [self] id in outstanding.removeAll { $0.id == id } },
                query: { [self] in queries.append($0) }), now: { [self] in now }, schedulesRetries: false)
        }

        func receiver() throws -> WatchContentReceiver {
            let cache = FileCache(fileStore: watchFiles, budget: { _ in .init(music: 1_000_000, artwork: 1_000_000) },
                                  freeSpaceReserve: 0)
            return try WatchContentReceiver(fileCache: cache, directory: root.appending(path: "receiver"),
                                            availableBytes: { [self] in available },
                                            send: { [self] in receipts.append($0) }, beforeCommit: { [self] in try beforeCommit() },
                                            now: { [self] in now })
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

    @Test("300 cached songs and artwork drain through bounded restartable production queues")
    func bulk() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot()
        try env.cache(snapshot)
        var queue = try env.queue()
        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
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
            receiver = try env.receiver()
            try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
            queue = try env.queue()
            try queue.reconcile(head: snapshot.head, snapshot: snapshot)
            #expect(queue.jobs.filter { $0.status == .delivered }.count == index)
            try queue.receive(try #require(env.receipts.last))
            index += 1
            await Task.yield()
        }
        #expect(queue.jobs.allSatisfy { $0.status == .delivered })
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        #expect(env.queued.count == total)
    }

    @Test("lost acknowledgments query verified storage without retransferring, and source copies survive phone cleanup")
    func lostReceiptAndCleanup() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        var queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        env.now += 120
        queue.resume()
        #expect(env.outstanding.count == 4 && env.queued.count == 4)
        let original = try Data(contentsOf: url)
        env.files.deleteFiles(.music, keeping: [])
        env.files.deleteFiles(.artwork, keeping: [])
        #expect(try Data(contentsOf: url) == original)
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        env.outstanding.removeAll { $0.id == file.id }
        try queue.finished(file, error: nil)
        #expect(queue.jobs.first { $0.file == file }?.status == .awaitingReceipt)
        #expect(env.queries.contains(file))
        queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        let queuedCount = env.queued.count
        try receiver.query(file)
        try queue.receive(try #require(env.receipts.last))
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        #expect(env.queued.count <= queuedCount + 1)
        #expect(env.queued.filter { $0.0.id == file.id }.count == 1)
    }

    @Test("file before context and snapshot survives recreation; a deselection rejects delayed bytes and receipts")
    func orderingAndDeselection() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        receiver.resume()
        #expect(env.watchFiles.list(.music).isEmpty && env.receipts.isEmpty)
        try receiver.reconcile(head: snapshot.head, snapshot: nil)
        #expect(env.receipts.isEmpty)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.watchFiles.exists(file.type, file.filename))
        let receipt = try #require(env.receipts.last)
        var emptyHead = snapshot.head
        emptyHead = .init(publisher: emptyHead.publisher, revision: 2, libraryID: "account", playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: emptyHead, libraryData: try Library().serializedData())
        let delayed = env.root.appending(path: "delayed")
        try Data(contentsOf: url).write(to: delayed)
        try queue.reconcile(head: emptyHead, snapshot: empty)
        try queue.receive(receipt)
        #expect(queue.jobs.isEmpty)
        try env.watchFiles.delete(file.type, file.filename)
        try env.stage(file, url: delayed)
        try receiver.reconcile(head: emptyHead, snapshot: empty)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(queue.jobs.isEmpty)
    }

    @Test("storage admission pauses without evicting selected downloads, then automatically retries")
    func storageRetry() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try env.watchFiles.write(.music, "m3.mp3", data: Data("retained".utf8))
        try env.stage(file, url: url)
        env.available = 0
        // the staged bytes themselves fit, but the device cannot keep its safety reserve.
        receiver = try WatchContentReceiver(
            fileCache: FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) }),
            directory: env.root.appending(path: "receiver"), availableBytes: { env.available }, send: { env.receipts.append($0) })
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .storageFull)
        #expect(env.watchFiles.exists(.music, "m3.mp3"))
        env.outstanding.removeAll { $0.id == file.id }
        try queue.receive(try #require(env.receipts.last))
        let count = env.queued.count
        queue.resume()
        #expect(env.queued.count == count)
        for other in Array(env.outstanding) {
            env.outstanding.removeAll { $0.id == other.id }
            try queue.receive(.init(file: other, status: .delivered))
        }
        env.now += 60
        env.available = 1_000_000_000
        queue.resume()
        #expect(env.queued.filter { $0.0.id == file.id }.count == 2)
        try env.stage(file, url: url)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }

    @Test("corrupt and unsolicited files fail safely; interrupted commits retry from the durable inbox")
    func integrityAndInterruption() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try env.stage(file, url: url)
        env.beforeCommit = { throw CocoaError(.fileWriteUnknown) }
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .retrying && !env.watchFiles.exists(file.type, file.filename))
        env.beforeCommit = {}
        env.now += 60
        let restored = try env.receiver()
        try restored.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .delivered)
        let (bad, badURL) = env.queued[1]
        try env.stage(bad, url: badURL)
        try Data("corrupt".utf8).write(to: env.root.appending(path: "receiver/\(bad.id.uuidString)/bytes"))
        restored.resume()
        #expect(env.receipts.last?.status == .failed)
        #expect(!env.watchFiles.exists(bad.type, bad.filename))
        let unsolicited = WatchContentFile(head: snapshot.head, type: .music, filename: "removed.mp3", bytes: file.bytes, digest: file.digest)
        try env.stage(unsolicited, url: url)
        restored.resume()
        #expect(!env.watchFiles.exists(.music, "removed.mp3"))
        let wrongType = WatchContentFile(head: snapshot.head, type: .artwork, filename: file.filename, bytes: file.bytes, digest: file.digest)
        try env.stage(wrongType, url: url)
        restored.resume()
        #expect(!env.watchFiles.exists(.artwork, file.filename))
        let traversal = WatchContentFile(head: snapshot.head, type: .music, filename: "../escape", bytes: file.bytes, digest: file.digest)
        #expect(throws: FileStore.FilenameError.self) { try env.stage(traversal, url: url) }
        var invalid = file
        invalid.version = 99
        #expect(throws: WatchLibraryError.self) { try env.stage(invalid, url: url) }
    }

    @Test("transient errors back off, permanent failures free a slot, and cache misses stay pending")
    func errorIsolation() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 6)
        try env.cache(snapshot)
        try env.files.delete(.music, "m5.mp3")
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let transient = env.queued[0].0
        env.outstanding.removeAll { $0.id == transient.id }
        try queue.finished(transient, error: URLError(.networkConnectionLost))
        let count = env.queued.count
        queue.resume()
        #expect(env.queued.count == count)
        let permanent = env.queued[1].0
        env.outstanding.removeAll { $0.id == permanent.id }
        try queue.finished(permanent, error: CocoaError(.fileReadNoPermission))
        #expect(queue.jobs.first { $0.file == permanent }?.status == .failed)
        #expect(env.queued.count > count)
        for file in Array(env.outstanding) {
            env.outstanding.removeAll { $0.id == file.id }
            try queue.receive(.init(file: file, status: .delivered))
        }
        env.now += 60
        queue.resume()
        #expect(env.queued.filter { $0.0.id == transient.id }.count == 2)
        #expect(queue.jobs.first { $0.filename == "m5.mp3" }?.status == .missingOnPhone)
        #expect(env.outstanding.count <= 4)
    }

    @Test("same library names from a prior account cannot establish current delivery")
    func changedIdentity() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "other-account",
                                    playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let next = WatchLibrarySnapshot(head: head, libraryData: snapshot.libraryData)
        let receiver = try env.receiver()
        try receiver.reconcile(head: head, snapshot: next)
        #expect(env.watchFiles.list(.music).isEmpty)
        try queue.reconcile(head: head, snapshot: next)
        try queue.receive(.init(file: file, status: .delivered))
        #expect(!queue.jobs.contains { $0.status == .delivered })
        #expect(env.outstanding.allSatisfy { $0.head == head })
    }

    @Test("a commit followed by failed receipt persistence is recovered without moving the file again")
    func interruptedAcknowledgment() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let cache = FileCache(fileStore: env.watchFiles)
        var refreshed = 0
        cache.onMusicChanged = { refreshed += 1 }
        let receiver = try WatchContentReceiver(
            fileCache: cache, directory: env.root.appending(path: "receiver"),
            availableBytes: { env.available }, send: { env.receipts.append($0) },
            beforeReceipt: { throw CocoaError(.fileWriteUnknown) })
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
        #expect(env.receipts.isEmpty)
        let restored = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                 availableBytes: { env.available }, send: { env.receipts.append($0) })
        try restored.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .delivered)
        #expect(refreshed == 1)
        try queue.receive(try #require(env.receipts.last))
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
        #expect(queue.jobs.filter { $0.type == .music }.count == 300)
        let incoming = metadata.receiver()
        incoming.expect(publisher.head)
        try metadata.stage(0)
        incoming.received()
        await incoming.waitForImport()
        let receiver = try env.receiver()
        try receiver.reconcile(head: incoming.head, snapshot: incoming.snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        receiver.resume()
        let session = PhoneWatchSession(payload: { .init(serverURL: "", token: "", playlistIds: []) }, onPlay: { _ in })
        session.content = queue
        session.receive(userInfo: try #require(env.receipts.last).encode())
        await Task.yield()
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        try queue.invalidate(identity: nil, playlistIDs: [])
        #expect(queue.jobs.isEmpty)
        #expect(env.outstanding.isEmpty)
    }

    @Test("selected music and artwork survive eviction, and already verified bytes need no staging space")
    func retainedFilesAndStagingPressure() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        for type in LibraryFileType.allCases {
            for name in env.files.list(type) {
                try env.watchFiles.write(type, name, data: Data(contentsOf: env.files.fileURL(type, name)))
            }
        }
        #expect(cache.evict().isEmpty)
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        let file = env.queued[0].0
        receiver.stagingFailed(file, error: CocoaError(.fileWriteOutOfSpace))
        #expect(env.receipts.last?.status == .delivered)
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }

    @Test("recreation between queue persistence and enqueue repairs intent through receipts before retrying")
    func interruptedEnqueue() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        env.enqueuesEnabled = false
        var queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(queue.jobs.first?.file)
        #expect(env.outstanding.isEmpty && env.queued.isEmpty)
        env.enqueuesEnabled = true
        queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(queue.jobs.first?.status == .awaitingReceipt)
        #expect(env.queries.contains(file))
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        for query in env.queries {
            try receiver.query(query)
            try queue.receive(try #require(env.receipts.last))
        }
        #expect(queue.jobs.first?.status == .retrying)
        env.now += 60
        queue.resume()
        #expect(env.queued.contains { $0.0 == file })
        #expect(env.outstanding.count <= 4)
        #expect(!queue.jobs.contains { $0.status == .delivered })
    }

    @Test("watch commit backoff survives recreation and permanent commit failure does not halt other files")
    func watchCommitRetries() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        for (file, url) in env.queued.prefix(2) { try env.stage(file, url: url) }
        var calls = 0
        env.beforeCommit = { calls += 1; throw CocoaError(.fileWriteUnknown) }
        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(calls == 2 && env.receipts.allSatisfy { $0.status == .retrying })
        receiver = try env.receiver()
        env.beforeCommit = { calls += 1 }
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        receiver.resume()
        #expect(calls == 2 && env.watchFiles.list(.music).isEmpty)
        env.now += 60
        receiver.resume()
        #expect(calls == 4 && env.watchFiles.list(.music).count == 2)
        env.receipts.removeAll()
        for (file, url) in env.queued.suffix(2) { try env.stage(file, url: url) }
        calls = 0
        env.beforeCommit = { calls += 1; if calls == 1 { throw CocoaError(.fileWriteNoPermission) } }
        receiver.resume()
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
}

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

    @Test("an unreceived snapshot preserves selected files; authoritative empty selection removes them")
    func authoritativeCleanup() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        for name in try snapshot.music { try env.watchFiles.write(.music, name, data: Data("selected".utf8)) }
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        try receiver.reconcile(head: head, snapshot: nil)
        cache.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        try receiver.reconcile(head: head, snapshot: snapshot)
        cache.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        try receiver.reconcile(head: head, snapshot: empty)
        #expect(env.watchFiles.list(.music).isEmpty)
    }

    @Test("relaunch restores phone retention before eviction and legacy offline selection cannot replace it")
    func authoritativeRestart() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        for name in try snapshot.music { try env.watchFiles.write(.music, name, data: Data("selected".utf8)) }
        for name in try snapshot.artwork { try env.watchFiles.write(.artwork, name, data: Data("selected".utf8)) }
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let legacy = OfflineLibrary(fileCache: restored, downloader: OfflineLibraryTests.Downloader(env.watchFiles))
        legacy.prepare(OfflineLibraryTests.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        restored.evict()
        #expect(env.watchFiles.list(.music) == (try snapshot.music))
        #expect(env.watchFiles.list(.artwork) == (try snapshot.artwork))
        #expect(legacy.selectedPlaylistIds.isEmpty)
    }

    @Test("membership edits, shared files, deleted playlists and changed names follow phone inventory")
    func mirroredMembership() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        for name in try original.music { try env.watchFiles.write(.music, name, data: Data("valid".utf8)) }
        for name in try original.artwork { try env.watchFiles.write(.artwork, name, data: Data("valid".utf8)) }
        try receiver.reconcile(head: original.head, snapshot: original)
        let head = WatchLibraryHead(publisher: original.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: ["p2"], metadataReady: true)
        var library = try original.library
        library = try WatchLibrarySnapshot.selected(library, ids: ["p2"])
        let subset = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        try receiver.reconcile(head: head, snapshot: subset)
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "m1.mp3"])
        #expect(env.watchFiles.list(.artwork) == (try subset.artwork))
        library.tracks[0].musicFilename = "replacement.mp3"
        library.tracks[0].artworkFilename = "replacement.jpg"
        library.tracks.removeAll { $0.id == "t1" }
        library.playlists[0].trackIds = ["t0"]
        let changedHead = WatchLibraryHead(publisher: head.publisher, revision: 3, libraryID: "account",
                                           playlistIDs: ["p2"], metadataReady: true)
        let changed = WatchLibrarySnapshot(head: changedHead, libraryData: try library.serializedData())
        try receiver.reconcile(head: changedHead, snapshot: changed)
        #expect(env.watchFiles.list(.music).isEmpty)
        #expect(env.watchFiles.list(.artwork).isEmpty)
        // additions remain desired, and arriving bytes enter the new inventory.
        try env.cache(changed)
        let queue = try env.queue()
        try queue.reconcile(head: changedHead, snapshot: changed)
        for (file, url) in env.queued { try env.stage(file, url: url) }
        receiver.resume()
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
        try receiver.reconcile(head: head, snapshot: snapshot)
        let player = PlayerStore(fileStore: env.watchFiles, fileCache: cache, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { true })
        cache.onMusicChanged = { [weak player] in player?.downloadsChanged() }
        player.play(songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack }
        let emptyHead = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "replacement",
                                         playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: emptyHead, libraryData: try Library().serializedData())
        try receiver.reconcile(head: emptyHead, snapshot: empty)
        #expect(player.song?.id == "1" && player.hasLoadedTrack)
        #expect(env.watchFiles.exists(.music, "1.wav"))
        player.playSelected([songs[1]], startingAt: 0, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.song?.id == "2" && player.hasLoadedTrack }
        #expect(!env.watchFiles.exists(.music, "1.wav"))
        #expect(env.watchFiles.exists(.music, "2.wav"))
        player.pause()
    }

    @Test("migration persistence failure preserves legacy state and retries without accepting premature content")
    func migrationFailure() throws {
        let env = try Env()
        defer { env.cleanUp() }
        var fails = true
        let cache = FileCache(fileStore: env.watchFiles, beforeWatchSelectionSave: {
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let offline = OfflineLibrary(fileCache: cache, downloader: OfflineLibraryTests.Downloader(env.watchFiles))
        offline.prepare(OfflineLibraryTests.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try env.watchFiles.write(.music, "1.wav", data: PlayerStoreTests.musicBytes)
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        receiver.resume()
        offline.retireForPhoneSelection()
        #expect(offline.selectedPlaylistIds == ["p"])
        #expect(env.watchFiles.exists(.music, "1.wav"))
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(FileManager.default.fileExists(atPath: env.watchFiles.rootURL.appending(path: "offline-playlists.json").path))
        fails = false
        receiver.resume()
        offline.retireForPhoneSelection()
        #expect(offline.selectedPlaylistIds.isEmpty)
        #expect(env.watchFiles.exists(file.type, file.filename))
        #expect(!env.watchFiles.exists(.music, "1.wav"))
        #expect(!FileManager.default.fileExists(atPath: env.watchFiles.rootURL.appending(path: "offline-playlists.json").path))
    }

    @Test("selected files survive unknown capacity and concurrent reservations; restart drops stale reservations")
    func capacityAndReservations() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) }, freeSpaceReserve: 10)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
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
    func firstSnapshotPending() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        for name in ["old.mp3", "m0.mp3", "m1.mp3"] { try env.watchFiles.write(.music, name, data: Data("existing".utf8)) }
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try receiver.reconcile(head: snapshot.head, snapshot: nil)
        cache.evict()
        #expect(env.watchFiles.list(.music) == ["old.mp3", "m0.mp3", "m1.mp3"])
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "m1.mp3"])
    }

    @Test("disk-full commit keeps selected downloads and pending intent, and verified migration reuses existing bytes")
    func commitFullAndReuse() throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        env.beforeCommit = { throw CocoaError(.fileWriteOutOfSpace) }
        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.receipts.last?.status == .storageFull)
        env.outstanding.removeAll { $0.id == file.id }
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .storageFull)
        env.now += 60
        env.beforeCommit = {}
        queue.resume()
        try env.stage(file, url: url)
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        try queue.receive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        let destination = env.watchFiles.fileURL(file.type, file.filename)
        let oldDate = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: destination.path)
        try env.stage(file, url: env.files.fileURL(file.type, file.filename))
        env.beforeCommit = { Issue.record("valid existing downloads should not be rewritten") }
        receiver.resume()
        #expect(file.matches(destination))
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date == oldDate)
    }

    @Test("unreadable retention preserves downloads and the legacy manifest until valid intent repairs it")
    func damagedRetention() throws {
        let env = try Env()
        defer { env.cleanUp() }
        try env.watchFiles.write(.music, "m0.mp3", data: Data("valid".utf8))
        try env.watchFiles.write(.music, "old.mp3", data: Data("legacy".utf8))
        let manifest = env.watchFiles.rootURL.appending(path: "offline-playlists.json")
        try Data("legacy state".utf8).write(to: manifest)
        try Data("damaged".utf8).write(to: env.watchFiles.rootURL.appending(path: "watch-selection.json"))
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let offline = OfflineLibrary(fileCache: cache, downloader: OfflineLibraryTests.Downloader(env.watchFiles))
        cache.evict()
        #expect(env.watchFiles.list(.music) == ["m0.mp3", "old.mp3"])
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        let snapshot = try env.snapshot(count: 4)
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        offline.retireForPhoneSelection()
        #expect(env.watchFiles.list(.music) == ["m0.mp3"])
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        let restored = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        restored.evict()
        #expect(env.watchFiles.list(.music) == ["m0.mp3"])
    }

    @Test("failed replacement persistence preserves the durable selection across recreation")
    func failedReplacement() throws {
        let env = try Env()
        defer { env.cleanUp() }
        var fails = false
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) },
                              beforeWatchSelectionSave: { if fails { throw CocoaError(.fileWriteUnknown) } })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        let snapshot = try env.snapshot(count: 4)
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
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
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        let cache = FileCache(fileStore: env.watchFiles)
        let oldBytes = Data("playing bytes".utf8)
        try env.watchFiles.write(file.type, file.filename, data: oldBytes)
        cache.setInUse(file.type, [file.filename])
        try env.stage(file, url: url)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(try Data(contentsOf: env.watchFiles.fileURL(file.type, file.filename)) == oldBytes)
        #expect(env.receipts.isEmpty)
        cache.setInUse(file.type, [])
        try await PlayerStoreTests.waitFor { env.receipts.last?.status == .delivered }
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
    }
}

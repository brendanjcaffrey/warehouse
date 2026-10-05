import Foundation
import Observation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("watch progress cache", .serialized)
@MainActor
struct WatchProgressCacheTests {
    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    @Test("unchanged large-library presentation reads do no validation or filesystem work")
    func presentationReads() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 1000)
        let source = env.root.appending(path: "source")
        try Data("missing".utf8).write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let receipts = (0..<3000).map { index in
            WatchContentReceipt(file: WatchContentFile(head: snapshot.head, type: .music, filename: "m\(index % 1000).mp3",
                                                       bytes: fingerprint.bytes, digest: fingerprint.digest), status: .failed)
        }
        let directory = env.root.appending(path: "receiver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: directory.appending(path: "receipts.json"))
        let receiver = try env.receiver()
        let watchFiles = env.watchFiles
        var validations = 0
        let probes = Probes()
        receiver.progressSource.validate = { snapshot in
            validations += 1
            return try snapshot.validatedLibrary()
        }
        receiver.progressSource.exists = { type, name in
            probes.record()
            return watchFiles.exists(type, name)
        }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let database = LibraryDatabase(inMemory: true)
        let library = WatchLibraryStore(songs: SongsStore(database: database, fileStore: watchFiles),
                                        playlists: PlaylistsStore(database: database), content: receiver)
        let before = (validations, probes.count)
        #expect(validations == 1)
        #expect(probes.count == 1001)
        for _ in 0..<100 {
            #expect(library.progress().music.total == 1000)
            #expect(library.progress().music.downloaded == 0)
            #expect(library.progress().music.failed == 1000)
            #expect(library.progress(playlistID: "p2").music.failed == 2)
        }
        #expect(validations == before.0)
        #expect(probes.count == before.1)
    }

    @Test("local file notifications coalesce and publish observed music and artwork progress")
    func fileNotifications() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        let files = env.watchFiles
        let probes = Probes()
        receiver.progressSource.exists = { type, name in probes.record(); return files.exists(type, name) }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let before = probes.count
        let changes = Probes()
        withObservationTracking {
            _ = receiver.progress().music.downloaded
        } onChange: { changes.record() }

        for name in ["m0.mp3", "m1.mp3"] {
            try files.write(.music, name, data: Data("local".utf8))
            cache.noteMusicStored()
        }
        let artwork = try #require(snapshot.artwork.first)
        try files.write(.artwork, artwork, data: Data("artwork".utf8))
        cache.noteFileStored(.artwork)
        await receiver.waitForWork()
        #expect(probes.count - before == 5)
        #expect(changes.count == 1)
        #expect(receiver.progress().music.downloaded == 2)
        #expect(receiver.progress(playlistID: "p2").state == .ready)
        #expect(receiver.progress().artwork.downloaded == 1)

        // player failure deletes local music and uses this same cache notification.
        try files.delete(.music, "m0.mp3")
        cache.noteMusicStored()
        await receiver.waitForWork()
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress(playlistID: "p2").state == .waiting)

        var reported = receiver.progress()
        reported.state = .ready
        reported.music.downloaded = 4
        reported.artwork.downloaded = 1
        let reads = probes.count
        try receiver.receive(.init(head: snapshot.head, sequence: 1, overall: reported, playlists: ["p2": reported]))
        #expect(probes.count == reads)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress().state == .waiting)
        // an inventory challenge repairs local truth even if removal bypassed cache callbacks.
        try files.delete(.music, "m1.mp3")
        try await receiver.settledQuery(WatchInventoryRequest(head: snapshot.head))
        #expect(receiver.progress().music.downloaded == 0)
        #expect(receiver.progress().artwork.downloaded == 1)
    }

    @Test("eviction and selection cleanup refresh saved progress before selection is restored")
    func cacheCleanup() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("first".utf8))
        try env.watchFiles.write(.music, "m1.mp3", data: Data("second".utf8))
        let artwork = try #require(snapshot.artwork.first)
        try env.watchFiles.write(.artwork, artwork, data: Data("artwork".utf8))
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in .init(music: 0, artwork: 0) })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try await receiver.settledReconcile(head: nil, snapshot: snapshot)
        #expect(receiver.progress().music.downloaded == 2)
        #expect(receiver.progress().state == .setup)
        // no current phone selection has been adopted yet, so legacy eviction can run.
        #expect(cache.evict().count == 1)
        await receiver.waitForWork()
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress().artwork.downloaded == 1)
        try cache.adoptWatchSelection(music: [], artwork: [])
        await receiver.waitForWork()
        #expect(receiver.progress().music.total == 4)
        #expect(receiver.progress().music.downloaded == 0)
        #expect(receiver.progress().artwork.downloaded == 0)
    }

    @Test("invalid metadata and failed selection persistence preserve saved counts until a valid retry")
    func failedMetadata() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("saved".utf8))
        var failSave = false
        let cache = FileCache(fileStore: env.watchFiles, beforeWatchSelectionSave: {
            if failSave { throw CocoaError(.fileWriteUnknown) }
        })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"), send: { _ in })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: ["p2"], metadataReady: true)
        let invalid = WatchLibrarySnapshot(head: head, libraryData: Data([0xff]))
        #expect(throws: (any Error).self) { try receiver.reconcile(head: head, snapshot: invalid) }
        #expect(receiver.progress().music.total == 4)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress().state == .preparing)
        var failed = head
        failed.failed = true
        try await receiver.settledReconcile(head: failed, snapshot: invalid)
        #expect(receiver.progress().state == .refreshFailed)
        #expect(receiver.progress().music.total == 4)
        #expect(receiver.progress().music.downloaded == 1)
        let library = try WatchLibrarySnapshot.selected(snapshot.library, ids: ["p2"])
        let next = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        failSave = true
        #expect(throws: (any Error).self) { try receiver.reconcile(head: head, snapshot: next) }
        #expect(receiver.progress().music.total == 4)
        #expect(receiver.progress().music.downloaded == 1)
        failSave = false
        await receiver.settledResume()
        #expect(receiver.progress().music.total == 2)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(receiver.progress().state == .waiting)
        #expect(receiver.progress(playlistID: "p1").state == .preparing)
    }

    @Test("a progress inventory scan overtaken by metadata cannot publish stale counts")
    func staleScan() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("saved".utf8))
        let receiver = try env.receiver()
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let files = env.watchFiles
        receiver.progressSource.exists = { type, name in
            let exists = files.exists(type, name)
            try? gate.block()
            return exists
        }
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2, libraryID: "account",
                                    playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: head, libraryData: try Library().serializedData())
        try receiver.reconcile(head: head, snapshot: empty)
        gate.release()
        await receiver.waitForWork()
        #expect(receiver.progress().state == .empty)
        #expect(receiver.progress().music.total == 0)
        #expect(receiver.progress().music.downloaded == 0)
    }

    @Test("restored receipt status obeys namespace and revision fences without claiming absent downloads")
    func receiptAuthority() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4, revision: 2)
        let previous = try env.snapshot(count: 4).head
        let future = try env.snapshot(count: 4, revision: 3).head
        let otherPublisher = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account",
                                              playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let otherAccount = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 1, libraryID: "other",
                                            playlistIDs: snapshot.head.playlistIDs, metadataReady: true)
        let records: [(WatchLibraryHead, String, WatchContentStatus)] = [
            (previous, "m0.mp3", .delivered), (previous, "m1.mp3", .storageFull),
            (otherPublisher, "m2.mp3", .failed), (future, "m3.mp3", .failed), (otherAccount, "m1.mp3", .failed)
        ]
        let receipts = records.map { head, name, status in
            WatchContentReceipt(file: .init(head: head, type: .music, filename: name,
                                             bytes: 1, digest: String(repeating: "a", count: 64)), status: status)
        }
        let directory = env.root.appending(path: "receiver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: directory.appending(path: "receipts.json"))
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.progress().music.downloaded == 0)
        #expect(receiver.progress().music.failed == 0)
        #expect(receiver.progress().music.storageFull == 1)
        #expect(receiver.progress().state == .storageFull)
        #expect(receiver.progress(playlistID: "p2").music.storageFull == 1)
        #expect(receiver.progress(playlistID: "p1").music.total == 4)
    }
}

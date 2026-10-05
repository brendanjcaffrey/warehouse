import Foundation
import Testing
import SwiftProtobuf
@testable import Warehouse

extension WatchContentDeliveryTests {
    @Test("forward revisions preserve transfers, staged files and lost receipt recovery across restart")
    func inFlightRevision() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        try env.cache(original)
        var queue = try env.queue()
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let transfers = env.queued
        let (staged, stagedURL) = transfers[0]
        try env.stage(staged, url: stagedURL)
        let next = try env.snapshot(count: 4, revision: 2)
        try await queue.settledReconcile(head: next.head, snapshot: nil)
        #expect(env.outstanding == transfers.map(\.0))
        queue = try env.queue()
        try await queue.settledReconcile(head: next.head, snapshot: next)
        #expect(env.queued.count == transfers.count)
        #expect(env.outstanding == transfers.map(\.0))
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: next.head, snapshot: next)
        #expect(staged.matches(env.watchFiles.fileURL(staged.type, staged.filename)))
        env.outstanding.removeAll { $0.id == staged.id }
        try await queue.settledFinished(staged, error: nil)
        // recover a lost acknowledgment using the original descriptor under the new head.
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: next.head, snapshot: next)
        try await receiver.settledQuery(staged)
        let receipt = try #require(env.receipts.last)
        #expect(receipt.file == staged && receipt.status == .delivered)
        try await queue.settledReceive(receipt)
        #expect(queue.jobs.first { $0.file == staged }?.status == .delivered)
        let (late, lateURL) = transfers[1]
        try env.stage(late, url: lateURL)
        await receiver.settledResume()
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == late }?.status == .delivered)
        #expect(env.queued.filter { $0.0.id == staged.id || $0.0.id == late.id }.count == 2)
    }

    @Test("new inventory cancels removed transfers and rejects their late files and receipts")
    func removedTransferRevision() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        try env.cache(original)
        let queue = try env.queue()
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let (removed, url) = env.queued[0]
        var library = try original.library
        let index = try #require(library.tracks.firstIndex { $0.musicFilename == removed.filename })
        library.tracks[index].musicFilename = "replacement.mp3"
        let head = try env.snapshot(count: 4, revision: 2).head
        let next = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        // stage before cancellation can collect the phone's private copy.
        try env.stage(removed, url: url)
        try await queue.settledReconcile(head: head, snapshot: next)
        #expect(!env.outstanding.contains(removed))
        try await queue.settledReceive(.init(file: removed, status: .delivered))
        #expect(!queue.jobs.contains { $0.file == removed })
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: head, snapshot: next)
        #expect(!env.watchFiles.exists(removed.type, removed.filename))
        #expect(receiver.receipts.isEmpty)
    }

    @Test("content cannot cross publishers, accounts or future revision authority", arguments: ["publisher", "account", "future"])
    func contentRevisionBoundary(_ boundary: String) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4, revision: 2)
        try env.cache(original)
        let queue = try env.queue()
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let head = WatchLibraryHead(publisher: boundary == "publisher" ? UUID() : original.head.publisher,
                                    revision: boundary == "future" ? 1 : 3,
                                    libraryID: boundary == "account" ? "other-account" : "account",
                                    playlistIDs: original.head.playlistIDs, metadataReady: true)
        let snapshot = WatchLibrarySnapshot(head: head, libraryData: original.libraryData)
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: head, snapshot: snapshot)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(receiver.receipts.isEmpty)
        if boundary == "future" {
            try await receiver.settledReconcile(head: original.head, snapshot: original)
            #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
            #expect(env.receipts.last?.file == file && env.receipts.last?.status == .delivered)
        }
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
        let outstanding = try #require(env.queued.first { $0.0.type == .music && $0.0.id != file.id }).0
        try await queue.settledReceive(.init(file: outstanding, status: .delivered))
        #expect(queue.progress().music.downloaded == 2)
        queue = try env.queue()
        #expect(queue.progress().music.downloaded == 2)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(queue.jobs.compactMap(\.file).allSatisfy { next.head.retainsContent(from: $0.head) })
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
        // a permanent file failure does not establish that the watch has space for the remaining selection.
        #expect(queue.progress().state == .storageFull)
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
}

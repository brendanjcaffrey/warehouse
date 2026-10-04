import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("WatchJournalRetention", .serialized)
@MainActor
struct WatchJournalRetentionTests {
    @Test("receipt history is bounded by selected files and staged retries, with verified query recovery")
    func receiptChurn() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for _ in 0..<50 {
            let duplicate = WatchContentFile(head: file.head, type: file.type, filename: file.filename,
                                             bytes: file.bytes, digest: file.digest)
            try env.stage(duplicate, url: url)
            await receiver.settledResume()
        }
        #expect(receiver.receipts.count == 1)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.receipts.count == 1)
        let count = env.queued.count
        try await receiver.settledQuery(file)
        #expect(env.receipts.last?.file == file && env.receipts.last?.status == .delivered)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
        #expect(env.queued.filter { $0.0.id == file.id }.count == 1)
        #expect(env.queued.count <= count + 1)
        #expect(receiver.receipts.count == 1)

        let next = try env.snapshot(count: 4, revision: 2)
        try await receiver.settledReconcile(head: next.head, snapshot: nil)
        #expect(receiver.receipts.count == 1)
        try await receiver.settledReconcile(head: next.head, snapshot: next)
        #expect(receiver.receipts.isEmpty)
        try await receiver.settledQuery(file)
        #expect(env.receipts.last?.status == .failed)
        #expect(receiver.receipts.isEmpty)

        for revision in 3...30 {
            let selected = revision.isMultiple(of: 3) ? [] : snapshot.head.playlistIDs
            let head = WatchLibraryHead(publisher: UUID(), revision: Int64(revision), libraryID: "account-\(revision)",
                                        playlistIDs: selected, metadataReady: true)
            let replacement = WatchLibrarySnapshot(head: head, libraryData: selected.isEmpty
                                                   ? try Library().serializedData() : snapshot.libraryData)
            try await receiver.settledReconcile(head: head, snapshot: replacement)
            if !selected.isEmpty {
                let current = WatchContentFile(head: head, type: file.type, filename: file.filename, bytes: file.bytes, digest: file.digest)
                try env.stage(current, url: url)
                await receiver.settledResume()
                #expect(env.receipts.last?.file == current && env.receipts.last?.status == .delivered)
            }
            #expect(receiver.receipts.count == (selected.isEmpty ? 0 : 1))
            let count = env.receipts.count
            try await receiver.settledQuery(file)
            #expect(env.receipts.count == count)
            receiver = try env.receiver()
            try await receiver.settledReconcile(head: head, snapshot: replacement)
            #expect(receiver.receipts.count == (selected.isEmpty ? 0 : 1))
        }
    }

    @Test("pruned receipt queries cannot promote missing or same-size corrupt bytes", arguments: [false, true])
    func unverifiedQuery(_ corrupt: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.stage(file, url: url)
        await receiver.settledResume()
        let duplicate = WatchContentFile(head: file.head, type: file.type, filename: file.filename, bytes: file.bytes, digest: file.digest)
        try env.stage(duplicate, url: url)
        await receiver.settledResume()
        #expect(!receiver.receipts.contains { $0.file == file })
        if corrupt {
            try env.watchFiles.write(file.type, file.filename, data: Data(repeating: 0, count: Int(file.bytes)))
        } else {
            try env.watchFiles.delete(file.type, file.filename)
        }
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await receiver.settledQuery(file)
        #expect(env.receipts.last?.file == file && env.receipts.last?.status == .retrying)
        #expect(receiver.receipts.count == 1)
    }

    @Test("large legacy history compacts durably without losing staged backoff or recovery evidence")
    func largeHistory() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4, revision: 2)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        let directory = env.root.appending(path: "receiver")
        let ledger = directory.appending(path: "receipts.json")
        let old = try env.snapshot(count: 4).head
        var history = (0..<10_000).map { _ in
            WatchContentReceipt(file: WatchContentFile(head: old, type: file.type, filename: file.filename,
                                                       bytes: file.bytes, digest: file.digest), status: .delivered)
        }
        var retry = WatchContentReceipt(file: file, status: .retrying)
        retry.retryAt = env.now + 60
        retry.attempts = 3
        history.append(retry)
        let duplicate = WatchContentFile(head: file.head, type: file.type, filename: file.filename,
                                         bytes: file.bytes, digest: file.digest)
        history.append(.init(file: duplicate, status: .retrying))
        let original = try JSONEncoder().encode(history)
        try original.write(to: ledger, options: .atomic)
        let started = Date()
        var receiver = try env.receiver()
        let startup = Date().timeIntervalSince(started)
        let compactStarted = Date()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let compact = Date().timeIntervalSince(compactStarted)
        #expect(receiver.receipts.count == 2)
        #expect(receiver.receipts.contains(retry))
        #expect(!env.watchFiles.exists(file.type, file.filename))
        let bytes = try Data(contentsOf: ledger)
        #expect(bytes.count < 2_000)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.receipts.contains(retry))
        env.now += 61
        await receiver.settledResume()
        #expect(env.watchFiles.exists(file.type, file.filename))
        await receiver.settledResume()
        #expect(receiver.receipts.count == 1)
        let writeStarted = Date()
        try await receiver.settledQuery(duplicate)
        let write = Date().timeIntervalSince(writeStarted)
        #expect(env.receipts.last?.file == duplicate && env.receipts.last?.status == .delivered)
        #expect(receiver.receipts.count == 1)
        print("receipt history: \(original.count) -> \(bytes.count) bytes; startup \(startup)s; compaction \(compact)s; query/write \(write)s")
    }

    @Test("failed compaction preserves the old ledger and staged bytes until restart repairs the commit")
    func interruptedCompaction() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        try env.stage(file, url: url)
        var oldHead = file.head
        oldHead = .init(publisher: UUID(), revision: 1, libraryID: "retired", playlistIDs: oldHead.playlistIDs, metadataReady: true)
        let old = WatchContentReceipt(file: WatchContentFile(head: oldHead, type: file.type, filename: file.filename,
                                                             bytes: file.bytes, digest: file.digest), status: .delivered)
        let directory = env.root.appending(path: "receiver")
        let ledger = directory.appending(path: "receipts.json")
        let original = try JSONEncoder().encode([old])
        try original.write(to: ledger, options: .atomic)
        let receiver = try WatchContentReceiver(fileCache: FileCache(fileStore: env.watchFiles), directory: directory,
                                               availableBytes: { env.available }, send: { env.receipts.append($0) },
                                               beforeReceipt: { throw CocoaError(.fileWriteUnknown) })
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        #expect(try Data(contentsOf: ledger) == original)
        #expect(receiver.receipts == [old])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: file.id.uuidString).path))
        let restored = try env.receiver()
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(restored.receipts.count == 1 && restored.receipts.first?.file == file)
        #expect(env.receipts.last?.status == .delivered)
    }

    @Test("retired publishers cannot accumulate late inbox files; future contexts survive replacement and relaunch")
    func metadataChurn() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        var receiver = env.receiver()
        await receiver.waitForImport()
        var retired = [WatchLibrarySnapshot]()
        let data = try Library().serializedData()
        func stage(_ snapshot: WatchLibrarySnapshot) throws {
            let source = env.root.appending(path: "source.json")
            try JSONEncoder().encode(snapshot).write(to: source, options: .atomic)
            _ = try WatchLibraryReceiver.stage(source, directory: env.inbox)
        }
        let futureHead = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "future", playlistIDs: [], metadataReady: true)
        let future = WatchLibrarySnapshot(head: futureHead, libraryData: data)
        try stage(future)
        for _ in 0..<20 {
            let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: [], metadataReady: true)
            let snapshot = WatchLibrarySnapshot(head: head, libraryData: data)
            receiver.expect(head)
            try stage(snapshot)
            for previous in retired {
                let lateHead = WatchLibraryHead(publisher: previous.head.publisher, revision: 99, libraryID: "account",
                                                playlistIDs: [], metadataReady: true)
                try stage(WatchLibrarySnapshot(head: lateHead, libraryData: data))
            }
            receiver.received()
            await receiver.waitForImport()
            #expect(receiver.snapshot?.head == head)
            #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).count == 1)
            retired.append(snapshot)
        }
        // an unretired publisher can legitimately precede its application context.
        receiver = env.receiver()
        await receiver.waitForImport()
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).count == 1)
        receiver.expect(futureHead)
        await receiver.waitForImport()
        #expect(receiver.snapshot == future)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).isEmpty)

        let nextHead = WatchLibraryHead(publisher: futureHead.publisher, revision: 2, libraryID: "future",
                                        playlistIDs: [], metadataReady: true)
        let next = WatchLibrarySnapshot(head: nextHead, libraryData: data)
        try stage(next)
        receiver.received()
        await receiver.waitForImport()
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).count == 1)
        env.watch.beforeLibrarySave = { throw CocoaError(.fileWriteUnknown) }
        receiver.expect(nextHead)
        await receiver.waitForImport()
        #expect(receiver.head == futureHead)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).count == 1)
        env.watch.beforeLibrarySave = {}
        receiver.expect(nextHead)
        await receiver.waitForImport()
        #expect(receiver.snapshot == next)
        try stage(future)
        receiver.received()
        await receiver.waitForImport()
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).isEmpty)
        receiver.expect(retired[0].head)
        try stage(retired[0])
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.head == nextHead && receiver.snapshot == next)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.inbox.path).isEmpty)
    }
}

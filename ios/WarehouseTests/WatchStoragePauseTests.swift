import Foundation
import Testing
@testable import Warehouse

@Suite("watch storage pause", .serialized)
@MainActor
struct WatchStoragePauseTests {
    typealias Env = WatchContentDeliveryTests.Env

    private func copies(_ env: Env) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: env.root.appending(path: "queue"), includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    @Test("storage full pauses the whole queue, releases copies and retries only one file across relaunch")
    func boundedProbes() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        var queue = try env.queue()
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let initial = env.queued
        let (blocked, blockedURL) = initial[0]
        try await queue.settledReceive(.init(file: blocked, status: .storageFull))
        #expect(env.queued.count == 4)
        // the system still owns this copy until its completion callback.
        #expect(FileManager.default.fileExists(atPath: blockedURL.path))
        env.outstanding.removeAll { $0.id == blocked.id }
        try await queue.settledFinished(blocked, error: nil)
        #expect(!FileManager.default.fileExists(atPath: blockedURL.path))
        for (file, url) in initial.dropFirst() {
            try env.stage(file, url: url)
            await receiver.settledStaged(file)
            env.outstanding.removeAll { $0.id == file.id }
            try await queue.settledFinished(file, error: nil)
            try await queue.settledReceive(try #require(env.receipts.last))
            #expect(env.queued.count == 4)
        }
        #expect(try copies(env).isEmpty)
        #expect(queue.progress().music.downloaded == 3)
        #expect(queue.progress().state == .storageFull)
        queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.queued.count == 4)
        for attempt in 1...3 {
            env.now += 3601
            await queue.settledResume()
            #expect(env.queued.count == 4 + attempt)
            #expect(env.outstanding.count == 1)
            #expect(try copies(env).count == 1)
            #expect(queue.progress().state == .storageFull)
            queue = try env.queue()
            try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
            #expect(env.queued.count == 4 + attempt)
            let probe = try #require(env.outstanding.first)
            try await queue.settledReceive(.init(file: probe, status: .storageFull))
            env.outstanding.removeAll { $0.id == probe.id }
            try await queue.settledFinished(probe, error: nil)
            #expect(try copies(env).isEmpty)
            #expect(env.queued.count == 4 + attempt)
        }
        env.now += 3601
        await queue.settledResume()
        let (probe, url) = try #require(env.queued.last)
        #expect(env.outstanding.count == 1)
        try env.stage(probe, url: url)
        await receiver.settledStaged(probe)
        env.outstanding.removeAll { $0.id == probe.id }
        try await queue.settledFinished(probe, error: nil)
        #expect(env.outstanding.isEmpty)
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.progress().music.downloaded == 4)
        #expect(env.outstanding.count == 4)
        #expect(queue.progress().state == .waiting)
        #expect(env.watchFiles.exists(blocked.type, blocked.filename))
    }

    @Test("a storage receipt fences preparation already running on the worker")
    func cancelPreparation() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        let original = try env.queue()
        try await original.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let initial = env.queued
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let queue = try env.queue(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let completed = initial[1].0
        env.outstanding.removeAll { $0.id == completed.id }
        try queue.receive(.init(file: completed, status: .delivered))
        #expect(await gate.waitForEntry())
        try queue.receive(.init(file: initial[0].0, status: .storageFull))
        gate.release()
        await queue.waitForWork()
        #expect(env.queued.count == 4)
        #expect(try copies(env).count == env.outstanding.count)
        #expect(queue.progress().music.downloaded == 1)
        #expect(queue.progress().state == .storageFull)
    }

    @Test("lost probe receipts query storage without sending another probe, and late success resumes the queue")
    func lostProbeReceipt() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        var queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let blocked = env.queued[0].0
        for file in env.outstanding {
            try await queue.settledReceive(.init(file: file, status: .storageFull))
        }
        env.outstanding.removeAll()
        await queue.settledResume()
        #expect(try copies(env).isEmpty)
        env.now += 3601
        await queue.settledResume()
        let probe = try #require(env.outstanding.first)
        #expect(env.queued.count == 5)
        env.outstanding.removeAll()
        try await queue.settledFinished(probe, error: nil)
        env.now += 3601
        queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.queries.contains(probe))
        #expect(env.queued.count == 5)
        #expect(queue.progress().state == .storageFull)
        // another previously rejected file does not authorize a refill while the probe is unanswered.
        let other = try #require(queue.jobs.compactMap(\.file).first { $0.id != probe.id && $0.id != blocked.id })
        try await queue.settledReceive(.init(file: other, status: .delivered))
        #expect(env.queued.count == 5)
        try await queue.settledReceive(.init(file: probe, status: .delivered))
        #expect(env.outstanding.count == 4)
        #expect(queue.progress().music.downloaded == 2)
    }

    @Test("storage pause survives forward metadata revisions and resets for a different library")
    func metadataChanges() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReceive(.init(file: env.queued[0].0, status: .storageFull))
        let next = try env.snapshot(count: 12, revision: 2)
        try await queue.settledReconcile(head: next.head, snapshot: next)
        #expect(env.outstanding.isEmpty)
        #expect(env.queued.count == 4)
        #expect(try copies(env).isEmpty)
        #expect(queue.progress().state == .storageFull)
        env.now += 3601
        await queue.settledResume()
        #expect(env.outstanding.count == 1)
        #expect(env.outstanding.first?.head == next.head)
        let newHead = WatchLibraryHead(publisher: next.head.publisher, revision: next.head.revision,
                                       libraryID: "another account", playlistIDs: next.head.playlistIDs, metadataReady: true)
        let replacement = WatchLibrarySnapshot(head: newHead, libraryData: next.libraryData)
        try await queue.settledReconcile(head: newHead, snapshot: replacement)
        #expect(env.outstanding.count == 4)
        #expect(queue.progress().state == .waiting)
    }

    @Test("probe transfer errors retain the pause and released sources wait for normal phone sync")
    func probeFailureAndMissingSource() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let initial = env.outstanding
        for file in initial { try await queue.settledReceive(.init(file: file, status: .storageFull)) }
        env.outstanding.removeAll()
        env.transportAvailable = false
        await queue.settledResume()
        #expect(try copies(env).isEmpty)
        env.files.deleteFiles(.music, keeping: [])
        env.files.deleteFiles(.artwork, keeping: [])
        env.transportAvailable = true
        env.now += 3601
        await queue.settledResume()
        #expect(env.queued.count == 4)
        #expect(env.outstanding.isEmpty)
        try env.cache(snapshot)
        env.now += 3601
        await queue.settledResume()
        let probe = try #require(env.outstanding.first)
        env.outstanding.removeAll()
        try await queue.settledFinished(probe, error: URLError(.networkConnectionLost))
        #expect(env.queued.count == 5)
        #expect(try copies(env).isEmpty)
        #expect(queue.progress().state == .storageFull)
        env.now += 3601
        await queue.settledResume()
        #expect(env.queued.count == 6)
        #expect(env.outstanding.count == 1)
    }

    @Test("a late delivered receipt during probe preparation survives worker completion and failure", arguments: [false, true])
    func receiptDuringPreparation(workerFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 12)
        try env.cache(snapshot)
        let original = try env.queue()
        try await original.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for file in env.outstanding { try await original.settledReceive(.init(file: file, status: .storageFull)) }
        env.outstanding.removeAll()
        await original.settledResume()
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let queue = try env.queue(worker: WatchContentWorker(beforeWork: {
            try gate.block()
            if workerFails { throw CocoaError(.fileReadNoPermission) }
        }))
        env.now += 3601
        queue.resume()
        #expect(await gate.waitForEntry())
        let probe = try #require(queue.jobs.first { $0.status == .storageFull }?.file)
        if workerFails { env.transportAvailable = false }
        try queue.receive(.init(file: probe, status: .delivered))
        gate.release()
        await queue.waitForWork()
        #expect(env.queued.filter { $0.0.id == probe.id }.count == 1)
        #expect(queue.jobs.first { $0.file == probe }?.status == .delivered)
        #expect(queue.progress().music.downloaded == 1)
        #expect(env.outstanding.count == (workerFails ? 0 : 4))
    }
}

import Foundation
import Testing
@testable import Warehouse

@Suite("watch delivery wake recovery", .serialized)
@MainActor
struct WatchDeliveryWakeTests {
    private final class Execution {
        var began = 0
        var active = Set<Int>()
        var ended = Set<Int>()
        var expirations: [Int: @MainActor () -> Void] = [:]
        var allowed = true

        var background: PhoneWatchContentQueue.BackgroundExecution {
            .init { [self] expired in
                guard allowed else { return nil }
                began += 1
                let id = began
                active.insert(id)
                let end = { [self] in
                    active.remove(id)
                    ended.insert(id)
                }
                expirations[id] = { expired(); end() }
                return end
            }
        }
    }

    @Test("background preparation holds execution through durable enqueue and releases on success or error", arguments: [false, true])
    func preparation(writeFails: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 3)
        try env.cache(snapshot)
        let execution = Execution()
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let worker = WatchContentWorker(beforeWork: {
            try await gate.block()
            if writeFails { throw CocoaError(.fileWriteUnknown) }
        })
        var protectedEnqueues = 0
        let queue = try PhoneWatchContentQueue(fileStore: env.files, directory: env.root.appending(path: "queue"), transport: .init(
            available: { true }, outstanding: { env.outstanding }, enqueue: { file, url in
                #expect(!execution.active.isEmpty)
                let journal = try? Data(contentsOf: env.root.appending(path: "queue/state.json"))
                #expect(journal?.range(of: Data(file.id.uuidString.utf8)) != nil)
                env.outstanding.append(file)
                env.queued.append((file, url))
                protectedEnqueues += 1
            }, cancel: { _ in }, query: { _ in }), schedulesRetries: false, worker: worker, backgroundExecution: execution.background)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        #expect(execution.active.count == 4 && execution.ended.isEmpty)
        gate.release()
        await queue.waitForWork()
        #expect(execution.active.isEmpty && execution.ended.count == execution.began)
        #expect(protectedEnqueues == (writeFails ? 0 : 4))
        if writeFails { #expect(queue.jobs.filter { $0.status == .retrying }.count == 4) }
    }

    @Test("expired background work cancels copies, persists retry deadlines and resumes on a later wake")
    func expiration() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 3)
        try env.cache(snapshot)
        let execution = Execution()
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        var queue = try env.queue(worker: WatchContentWorker(beforeWork: { try await gate.block() }), backgroundExecution: execution.background)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        for expire in execution.expirations.values { expire() }
        #expect(execution.active.isEmpty)
        gate.release()
        await queue.waitForWork()
        #expect(env.queued.isEmpty && execution.began == 4)
        #expect(queue.jobs.filter { $0.status == .retrying && $0.nextAttempt > env.now }.count == 4)
        queue = try env.queue(backgroundExecution: execution.background)
        env.now.addTimeInterval(61)
        await queue.settledResume()
        #expect(env.queued.count == 4 && execution.active.isEmpty)
    }

    @Test("denied background execution defers preparation without taking transfer ownership")
    func unavailableExecution() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 3)
        try env.cache(snapshot)
        let execution = Execution()
        execution.allowed = false
        let queue = try env.queue(backgroundExecution: execution.background)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.queued.isEmpty && queue.jobs.allSatisfy { $0.file == nil })
        #expect(queue.jobs.allSatisfy { $0.status == .retrying && $0.nextAttempt > env.now })
        execution.allowed = true
        env.now.addTimeInterval(61)
        await queue.settledResume()
        #expect(env.queued.count == 4 && execution.active.isEmpty)
    }

    @Test("early receipts reject impostors, retain delivery over reordered errors and obey replacement metadata", arguments: [false, true])
    func deferredAuthority(replaced: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        try env.cache(original)
        var queue = try env.queue()
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let file = try #require(env.queued.first?.0)
        let next = try env.snapshot(count: 4, revision: 2)
        try queue.reconcile(head: next.head, snapshot: nil)
        let impostor = WatchContentFile(id: file.id, head: file.head, type: file.type,
                                        filename: file.filename, bytes: file.bytes + 1, digest: file.digest)
        try queue.receive(.init(file: impostor, status: .delivered))
        try queue.receive(.init(file: file, status: .delivered))
        try queue.receive(.init(file: file, status: .retrying))
        queue = try env.queue()
        if replaced {
            let head = WatchLibraryHead(publisher: UUID(), revision: 3, libraryID: "other", playlistIDs: [], metadataReady: true)
            let empty = WatchLibrarySnapshot(head: head, libraryData: Data())
            try await queue.settledReconcile(head: head, snapshot: empty)
            #expect(queue.jobs.isEmpty)
            #expect(env.phoneDiagnostics.events.allSatisfy { $0.kind != .phoneAcknowledged })
        } else {
            try await queue.settledReconcile(head: next.head, snapshot: next)
            #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
            #expect(env.phoneDiagnostics.events.filter { $0.kind == .phoneAcknowledged }.count == 1)
        }
    }

    @Test("a failed deferred receipt save preserves the prior journal and later retries the same receipt")
    func deferredPersistence() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        var fails = false
        let state = WatchDeliveryState(write: { data, url in
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        let original = try env.snapshot(count: 4)
        try env.cache(original)
        let queue = try env.queue(state: state)
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let file = try #require(env.queued.first?.0)
        let next = try env.snapshot(count: 4, revision: 2)
        try queue.reconcile(head: next.head, snapshot: nil)
        fails = true
        #expect(throws: CocoaError.self) { try queue.receive(.init(file: file, status: .delivered)) }
        fails = false
        try await queue.settledReconcile(head: next.head, snapshot: next)
        #expect(queue.jobs.first { $0.file == file }?.status != .delivered)
        try await queue.settledReceive(.init(file: file, status: .delivered))
        #expect(queue.jobs.first { $0.file == file }?.status == .delivered)
    }
}

import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch content workers", .serialized)
@MainActor
struct WatchContentWorkerTests {
    @Test("large-file preparation leaves playback commands responsive")
    func responsiveness() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 300)
        try env.cache(snapshot)
        let large = Data(repeating: 42, count: 64 * 1_048_576)
        for name in try snapshot.music.sorted().prefix(4) { try env.files.write(.music, name, data: large) }
        let queue = try env.queue()
        let rig = try WatchPlaybackHandoffTests.Rig()
        defer { rig.cleanUp() }
        rig.player.play(rig.songs, startingAt: 1, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack }
        let start = ContinuousClock.now
        let command = Task { @MainActor in
            rig.player.pause()
            rig.remote.command(.playPause)
            return start.duration(to: .now)
        }
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let delay = await command.value
        var delays = [delay]
        let commands = Task { @MainActor in
            while queue.jobs.filter({ $0.file != nil }).count < 4 {
                let requested = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(10))
                rig.player.pause()
                rig.remote.command(.playPause)
                delays.append(requested.duration(to: .now) - .milliseconds(10))
            }
        }
        await queue.waitForWork()
        await commands.value
        #expect(env.outstanding.count == 4)
        #expect(queue.jobs.count == 301)
        print("content preparation maximum playback command delay: \(delays.max() ?? .zero), samples: \(delays.count)")
        #expect(delays.allSatisfy { $0 < .milliseconds(100) })

        var receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        await receiver.waitForWork()
        for (file, url) in env.queued { try env.stage(file, url: url) }
        var completed = false
        let watchCommands = Task { @MainActor in
            while !completed {
                let requested = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(10))
                rig.player.pause()
                rig.remote.command(.playPause)
                delays.append(requested.duration(to: .now) - .milliseconds(10))
            }
        }
        receiver.resume()
        await receiver.waitForWork()
        completed = true
        await watchCommands.value
        #expect(receiver.receipts.filter { $0.status == .delivered }.count == 4)
        print("content verification maximum playback command delay: \(delays.max() ?? .zero), samples: \(delays.count)")
        #expect(delays.allSatisfy { $0 < .milliseconds(100) })
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        await receiver.waitForWork()
        completed = false
        let bulkCommands = Task { @MainActor in
            while !completed {
                let requested = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(10))
                rig.player.togglePlayPause()
                rig.remote.command(.playPause)
                delays.append(requested.duration(to: .now) - .milliseconds(10))
            }
        }
        let bulkStart = ContinuousClock.now
        while let file = env.outstanding.first {
            if !env.watchFiles.exists(file.type, file.filename) {
                let url = try #require(env.queued.last { $0.0.id == file.id }?.1)
                try env.stage(file, url: url)
                receiver.staged(file)
                await receiver.waitForWork()
            }
            try receiver.query(file)
            await receiver.waitForWork()
            env.outstanding.removeAll { $0.id == file.id }
            try queue.receive(try #require(env.receipts.last { $0.file == file }))
            await queue.waitForWork()
        }
        completed = true
        await bulkCommands.value
        #expect(queue.progress().music.downloaded == 300)
        #expect(queue.progress().artwork.downloaded == 1)
        print("bulk delivery duration: \(bulkStart.duration(to: .now)), maximum command delay: \(delays.max() ?? .zero)")
        #expect(delays.allSatisfy { $0 < .milliseconds(100) })
        print("content preparation first playback command delay: \(delay)")
        #expect(delay < .milliseconds(100))
    }

    final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false

        func block() throws {
            condition.lock()
            defer { condition.unlock() }
            entered = true
            condition.broadcast()
            while !released {
                guard condition.wait(until: Date().addingTimeInterval(10)) else { throw CocoaError(.userCancelled) }
            }
        }

        func waitForEntry() async -> Bool {
            await Task.detached { [self] in
                condition.lock()
                defer { condition.unlock() }
                while !entered {
                    if !condition.wait(until: Date().addingTimeInterval(5)) { return false }
                }
                return true
            }.value
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    @Test("selection cancellation fences preparing copies and limits slots while the worker is suspended")
    func phoneCancellation() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 8)
        try env.cache(snapshot)
        let gate = Gate()
        defer { gate.release() }
        let queue = try env.queue(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        queue.resume()
        #expect(env.queued.isEmpty)
        try queue.invalidate(identity: nil, playlistIDs: [])
        let next = try env.snapshot(count: 8, revision: 2)
        try queue.reconcile(head: next.head, snapshot: next)
        #expect(env.queued.isEmpty)
        gate.release()
        await queue.waitForWork()
        #expect(env.queued.count == 4)
        #expect(env.queued.allSatisfy { $0.0.head == next.head })
        #expect(env.outstanding.count == 4)
        for (file, url) in env.queued {
            try env.files.delete(file.type, file.filename)
            #expect(file.matches(url))
        }
        queue.resume()
        await queue.waitForWork()
        #expect(env.outstanding.count == 4)
    }

    @Test("unavailable transport does not enqueue a completed worker result")
    func unavailablePhone() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let gate = Gate()
        defer { gate.release() }
        let queue = try env.queue(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        env.transportAvailable = false
        gate.release()
        await queue.waitForWork()
        #expect(env.queued.isEmpty)
        env.transportAvailable = true
        queue.resume()
        await queue.waitForWork()
        #expect(env.queued.count == 4)
    }

    @Test("background completion waits for verification and durable receipt after delegate dispatch")
    func backgroundVerification() async throws {
        let env = try WatchPhoneSessionTests.Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        try env.content.cache(snapshot)
        let queue = try env.content.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = try #require(env.content.queued.first)
        try env.content.stage(file, url: url)
        // staging is already durable; system-owned temporary bytes can disappear immediately.
        try FileManager.default.removeItem(at: url)
        let gate = Gate()
        defer { gate.release() }
        let receiver = try env.content.receiver(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        env.session.content = receiver
        env.hold()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        env.systemPending = false
        env.session.updateBackgroundLifetime()
        #expect(await gate.waitForEntry())
        #expect(receiver.pendingOperations == 1)
        #expect(env.finished == 0)
        #expect(env.content.receipts.isEmpty)
        gate.release()
        await receiver.waitForWork()
        #expect(receiver.pendingOperations == 0)
        #expect(env.finished == 1)
        #expect(env.content.receipts.last?.status == .delivered)
        #expect(file.matches(env.content.watchFiles.fileURL(file.type, file.filename)))
    }

    @Test("head changes during verification cannot commit or acknowledge obsolete content", arguments: [false, true])
    func obsoleteWatch(query: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = try #require(env.queued.first)
        if query {
            try env.watchFiles.write(file.type, file.filename, data: Data(contentsOf: url))
        } else {
            try env.stage(file, url: url)
        }
        let gate = Gate()
        defer { gate.release() }
        let receiver = try env.receiver(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        if query { try receiver.query(file) }
        #expect(await gate.waitForEntry())
        receiver.pause()
        let next = try env.snapshot(count: 4, revision: 2)
        try receiver.reconcile(head: next.head, snapshot: next)
        gate.release()
        await receiver.waitForWork()
        #expect(env.receipts.isEmpty)
        #expect(receiver.receipts.isEmpty)
        #expect(env.watchFiles.exists(file.type, file.filename) == query)
    }

    @Test("damaged queue recovery verifies private bytes before adopting exact-head receipt queries", arguments: [false, true])
    func verifyRecovery(corrupt: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, copy) = try #require(env.queued.first)
        if corrupt {
            try Data(repeating: 0, count: Int(file.bytes)).write(to: copy, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: copy)
        }
        try env.files.delete(file.type, file.filename)
        env.outstanding.removeAll()
        let directory = env.root.appending(path: "queue")
        try Data("broken".utf8).write(to: directory.appending(path: "state.json"))
        let restored = try PhoneWatchContentQueue(fileStore: env.files, directory: directory, transport: .init(
            available: { true }, outstanding: { env.outstanding },
            enqueue: { env.outstanding.append($0); env.queued.append(($0, $1)) },
            cancel: { _ in }, query: { env.queries.append($0) }),
            schedulesRetries: false, state: .init(repairsDamage: true))
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(!env.queries.contains(file))
        let job = try #require(restored.jobs.first { $0.filename == file.filename && $0.type == file.type })
        #expect(job.file == nil && job.status == .missingOnPhone)
        #expect(env.queries.count == 3)
    }

}

import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch delivery scheduling", .serialized)
@MainActor
struct WatchDeliverySchedulingTests {
    final class Delay {
        var seconds = [TimeInterval]()
        var pending = [CheckedContinuation<Void, Never>]()
        var resumed = 0

        func wait(_ seconds: TimeInterval) async {
            self.seconds.append(seconds)
            await withCheckedContinuation { pending.append($0) }
            resumed += 1
        }

        func release() {
            let pending = pending
            self.pending.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    @Test("blocked queue wakes keep retrying without a foreground event", arguments: [false, true])
    func blockedQueue(metadataPending: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        let delay = Delay()
        defer { delay.release(); env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        let queue = try PhoneWatchContentQueue(fileStore: env.files, directory: env.root.appending(path: "queue"), transport: .init(
            available: { env.transportAvailable }, outstanding: { env.outstanding },
            enqueue: { env.outstanding.append($0); env.queued.append(($0, $1)) }, cancel: { _ in }, query: { env.queries.append($0) }),
            now: { env.now }, diagnostics: env.phoneDiagnostics, backgroundExecution: .init(begin: { _ in {} }),
            retryDelay: { await delay.wait($0) })
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 1 }
        var pendingHead = WatchLibraryHead(publisher: snapshot.head.publisher, revision: snapshot.head.revision + 1,
                                          libraryID: snapshot.head.libraryID, playlistIDs: snapshot.head.playlistIDs)
        if metadataPending {
            try queue.reconcile(head: pendingHead, snapshot: nil)
        } else {
            env.transportAvailable = false
            queue.resume()
        }
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 2 }
        #expect(delay.seconds == [60, 60])
        env.now += 60
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 3 }
        #expect(env.queued.isEmpty && env.queries.isEmpty)
        try env.cache(snapshot)
        env.transportAvailable = true
        if metadataPending {
            pendingHead.metadataReady = true
            let next = WatchLibrarySnapshot(head: pendingHead, libraryData: snapshot.libraryData)
            try queue.reconcile(head: next.head, snapshot: next)
        } else {
            env.now += 60
            delay.release()
        }
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { !env.queued.isEmpty }
        await queue.waitForWork()
        #expect(env.queued.count == PhoneWatchContentQueue.maximumTransfers)
    }

    @Test("initial pending jobs keep a wakeup while delivery is blocked", arguments: [false, true])
    func pendingJobs(metadataPending: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        let delay = Delay()
        defer { delay.release(); env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        env.transportAvailable = false
        let queue = try PhoneWatchContentQueue(fileStore: env.files, directory: env.root.appending(path: "queue"), transport: .init(
            available: { env.transportAvailable }, outstanding: { env.outstanding },
            enqueue: { env.outstanding.append($0); env.queued.append(($0, $1)) }, cancel: { _ in }, query: { env.queries.append($0) }),
            now: { env.now }, backgroundExecution: .init(begin: { _ in {} }), retryDelay: { await delay.wait($0) })
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        if metadataPending {
            let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: snapshot.head.revision + 1,
                                        libraryID: snapshot.head.libraryID, playlistIDs: snapshot.head.playlistIDs)
            try queue.reconcile(head: head, snapshot: nil)
        }
        #expect(queue.jobs.allSatisfy { $0.status == .pending })
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { !delay.seconds.isEmpty }
        #expect(delay.seconds.last == 60)
        env.now += 60
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { !delay.pending.isEmpty }
        #expect(env.queued.isEmpty && env.queries.isEmpty)
        if !metadataPending {
            env.transportAvailable = true
            env.now += 60
            delay.release()
            try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { !env.queued.isEmpty }
            await queue.waitForWork()
            #expect(env.queued.count == PhoneWatchContentQueue.maximumTransfers)
        }
    }

    @Test("transient publication failures retry automatically with backoff")
    func publicationRetry() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        let delay = Delay()
        defer { delay.release(); env.cleanUp() }
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "account")
        var failing = true
        env.phone.beforeWatchLibraryRead = { if failing { throw CocoaError(.fileReadUnknown) } }
        let publisher = try PhoneWatchLibraryPublisher(database: env.phone, directory: env.root.appending(path: "publisher"), transport: .init(
            context: { env.heads.append($0) }, outstanding: { env.outstanding },
            enqueue: { env.deliveries.append(($0, $1)); env.outstanding.insert($1) }), retryDelay: { await delay.wait($0) })
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && publisher.errorMessage != nil)
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 1 }
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 2 }
        #expect(delay.seconds == [5, 10])
        failing = false
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { env.deliveries.count == 1 }
        await publisher.waitForPublication()
        #expect(publisher.head.metadataReady && publisher.head.failed != true && publisher.errorMessage == nil)
        #expect(publisher.head.playlistIDs == ["p1"])
    }

    @Test("context failures still reconcile the content snapshot and retry metadata delivery")
    func contextFailure() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        let content = try WatchContentDeliveryTests.Env()
        let delay = Delay()
        defer { delay.release(); content.cleanUp(); env.cleanUp() }
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "account")
        content.transportAvailable = false
        let queue = try content.queue()
        env.unavailable = true
        let publisher = try PhoneWatchLibraryPublisher(database: env.phone, directory: env.root.appending(path: "publisher"), transport: .init(
            context: { if env.unavailable { throw WatchLibraryError.notLoaded }; env.heads.append($0) }, outstanding: { env.outstanding },
            enqueue: { env.deliveries.append(($0, $1)); env.outstanding.insert($1) }), retryDelay: { await delay.wait($0) })
        publisher.onSnapshot = { queue.update(head: $0, snapshot: $1) }
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(queue.progress().music.total == 4)
        #expect(publisher.head.metadataReady && publisher.errorMessage != nil && env.deliveries.isEmpty)
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 1 }
        let head = publisher.head
        env.unavailable = false
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { env.deliveries.count == 1 }
        await publisher.waitForPublication()
        #expect(publisher.head == head && publisher.errorMessage == nil)
    }

    @Test("new publication intent cancels a delayed retry for the old selection")
    func supersededRetry() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        let delay = Delay()
        defer { delay.release(); env.cleanUp() }
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "account")
        env.phone.beforeWatchLibraryRead = { throw CocoaError(.fileReadUnknown) }
        let publisher = try PhoneWatchLibraryPublisher(database: env.phone, directory: env.root.appending(path: "publisher"), transport: .init(
            context: { env.heads.append($0) }, outstanding: { env.outstanding },
            enqueue: { env.deliveries.append(($0, $1)); env.outstanding.insert($1) }), retryDelay: { await delay.wait($0) })
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.seconds.count == 1 }
        env.phone.beforeWatchLibraryRead = {}
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let head = publisher.head
        delay.release()
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { delay.resumed == 1 }
        await publisher.waitForPublication()
        #expect(publisher.head == head && publisher.head.playlistIDs == ["p2"])
        #expect(env.deliveries.count == 1 && publisher.errorMessage == nil)
    }

    @Test("watch installation and pairing state changes republish without live reachability")
    func watchStateChanged() async throws {
        let session = PhoneWatchSession(onPlay: { _ in })
        var pushes = 0
        session.publishLibrary = { pushes += 1 }
        let delegate: any WCSessionDelegate = session
        delegate.sessionWatchStateDidChange?(WCSession.default)
        try await PlayerStoreTests.waitFor(timeout: .seconds(2)) { pushes == 1 }
    }
}

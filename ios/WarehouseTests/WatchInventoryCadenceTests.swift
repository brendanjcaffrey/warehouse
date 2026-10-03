import Foundation
import Testing
@testable import Warehouse

@Suite("WatchInventoryCadence", .serialized)
@MainActor
struct WatchInventoryCadenceTests {
    @Test("ordinary sync and foreground requests reuse persisted receipts without rescanning for 24 hours")
    func dailyCadence() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (snapshot, original, receiver) = try WatchInventoryTests().prepared(env)
        var queue = original
        let files = env.queued.count
        let started = env.now
        queue.requestInventory()
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        #expect(env.inventoryRequests.count == 1)
        #expect(queue.diagnosticState().inventoryStartedAt == started)
        #expect(queue.diagnosticState().inventoryEligibleAt == started.addingTimeInterval(86_400))
        queue = try env.queue()
        for _ in 0..<3 {
            queue.requestInventory()
            try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        }
        let next = try env.snapshot(count: 4, revision: 2)
        try queue.reconcile(head: next.head, snapshot: next)
        #expect(queue.progress().music.downloaded == 4)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(env.queued.count == files)
        #expect(env.inventoryRequests.count == 1)
        env.now += 86_399
        queue.requestInventory()
        #expect(env.inventoryRequests.count == 1)
        env.now += 1
        queue.requestInventory()
        #expect(env.inventoryRequests.count == 2)
        #expect(env.inventoryRequests.last?.head == next.head)
    }

    @Test("retrying an inventory request replays the durable capture instead of rescanning changed storage")
    func replaysCapture() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (snapshot, queue, initialReceiver) = try WatchInventoryTests().prepared(env)
        var receiver = initialReceiver
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        try receiver.query(request)
        let original = env.inventoryReports
        try env.watchFiles.delete(.music, "m0.mp3")
        receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        env.inventoryReports.removeAll()
        env.now += 61
        queue.resume()
        try receiver.query(request)
        #expect(env.inventoryReports == original)
        #expect(env.watchDiagnostics.events.count { $0.kind == .inventoryScanned } == 1)
    }

    @Test("the daily limit starts when an offline challenge is first sent, not when it is created")
    func offlineStart() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (snapshot, original, receiver) = try WatchInventoryTests().prepared(env)
        var queue = original
        env.transportAvailable = false
        queue.requestInventory()
        queue = try env.queue()
        #expect(queue.diagnosticState().inventoryStartedAt == nil)
        env.now += 2 * 86_400
        env.transportAvailable = true
        queue.requestInventory()
        let started = env.now
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.inventoryRequests.count == 1)
        #expect(queue.diagnosticState().inventoryStartedAt == started)
        env.now += 86_399
        queue.requestInventory()
        #expect(env.inventoryRequests.count == 1)
        env.now += 1
        queue.requestInventory()
        #expect(env.inventoryRequests.count == 2)
    }

    @Test("configuration invalidation cannot reset the daily scan budget")
    func configurationChanges() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (snapshot, queue, receiver) = try WatchInventoryTests().prepared(env)
        queue.requestInventory()
        let started = env.now
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        try queue.invalidate(identity: nil, playlistIDs: [])
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        try WatchInventoryTests().deliver(env, queue: queue, receiver: receiver)
        queue.requestInventory()
        #expect(env.inventoryRequests.count == 1)
        #expect(queue.diagnosticState().inventoryStartedAt == started)
        #expect(queue.progress().state == .ready)
    }

    @Test("new metadata sends only newly selected content while the daily scan is cooling down")
    func newFilesDuringCooldown() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try WatchInventoryTests().prepared(env)
        queue.requestInventory()
        try receiver.query(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try queue.receive(report) }
        let previous = env.queued.count
        let next = try env.snapshot(count: 5, revision: 2)
        try env.cache(next)
        try queue.reconcile(head: next.head, snapshot: next)
        #expect(env.queued.count == previous + 1)
        #expect(env.queued.last?.0.filename == "m4.mp3")
        #expect(queue.progress().music.downloaded == 4)
        #expect(queue.progress().music.total == 5)
        #expect(env.inventoryRequests.count == 1)
    }

    @Test("delayed delivery cannot cause two fresh watch scans within a day")
    func delayedWatchScan() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let (snapshot, queue, receiver) = try WatchInventoryTests().prepared(env)
        queue.requestInventory()
        let request = try #require(env.inventoryRequests.last)
        env.now += 2 * 86_400
        try receiver.query(request)
        let scanned = env.now
        for report in env.inventoryReports { try queue.receive(report) }
        env.inventoryReports.removeAll()
        queue.requestInventory()
        let next = try #require(env.inventoryRequests.last)
        #expect(next != request)
        try receiver.query(next)
        #expect(env.inventoryReports.isEmpty)
        #expect(receiver.diagnosticState().inventoryEligibleAt == scanned.addingTimeInterval(86_400))
        env.now += 86_400
        let restored = try env.receiver()
        try restored.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(env.inventoryReports.first?.request == next)
        #expect(env.watchDiagnostics.events.count { $0.kind == .inventoryScanned } == 2)
    }
}

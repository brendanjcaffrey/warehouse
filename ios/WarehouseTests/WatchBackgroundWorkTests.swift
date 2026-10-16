import Foundation
import Testing
@testable import Warehouse

@Suite("watch background maintenance", .serialized)
@MainActor
struct WatchBackgroundWorkTests {
    @Test("manual inventory cancels at background transition and retries its durable challenge")
    func interruptedManualInventory() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("saved".utf8))
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let receiver = try env.receiver(worker: WatchContentWorker(beforeWork: { try await gate.block() }))
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        receiver.syncDownloadedStatus()
        let request = try #require(env.manualRequests.last)
        try receiver.query(request)
        #expect(await gate.waitForEntry())
        receiver.allowsMaintenance = false
        gate.release()
        await receiver.waitForWork()
        #expect(env.inventoryReports.isEmpty)
        #expect(receiver.inventoryPending)
        #expect(receiver.inventoryFeedback?.hasPrefix("Sync failed:") != true)
        receiver.allowsMaintenance = true
        await receiver.waitForWork()
        #expect(env.inventoryReports.flatMap(\.entries).count == 5)
        #expect(env.inventoryReports.allSatisfy { $0.request == request && $0.isValid })
    }

    @Test("inventory challenges survive background restarts and report only when foregrounded")
    func deferredInventory() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 1000)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("saved".utf8))
        var receiver = try env.receiver()
        receiver.allowsMaintenance = false
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let request = WatchInventoryRequest(head: snapshot.head)
        try await receiver.settledQuery(request)
        #expect(env.inventoryReports.isEmpty)
        receiver = try env.receiver()
        receiver.allowsMaintenance = false
        let probes = WatchProgressCacheTests.Probes()
        let files = env.watchFiles
        receiver.progressSource.exists = { type, name in probes.record(); return files.exists(type, name) }
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let backgroundReads = probes.count
        #expect(backgroundReads == 0)
        #expect(env.inventoryReports.isEmpty)
        receiver.allowsMaintenance = true
        await receiver.waitForWork()
        #expect(env.inventoryReports.allSatisfy { $0.request == request })
        #expect(env.inventoryReports.flatMap(\.entries).count == 1001)
        #expect(env.inventoryReports.flatMap(\.entries).filter { $0.bytes != nil }.count == 1)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(probes.count == 1001)
    }

    @Test("a progress scan stops at background transition and resumes with complete foreground truth")
    func interruptedProgress() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 1000)
        let receiver = try env.receiver()
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let probes = WatchProgressCacheTests.Probes()
        receiver.progressSource.exists = { _, _ in
            probes.record()
            try? await gate.block()
            return true
        }
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(await gate.waitForEntry())
        receiver.allowsMaintenance = false
        gate.release()
        await receiver.waitForWork()
        #expect(probes.count == 1)
        #expect(receiver.progress().music.downloaded == 0)
        receiver.allowsMaintenance = true
        await receiver.waitForWork()
        #expect(probes.count == 1002)
        #expect(receiver.progress().music.downloaded == 1000)
    }

    @Test("selected content admission with sufficient space avoids calculating the entire cache budget")
    func selectedAdmission() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        var budgetReads = 0
        let cache = FileCache(fileStore: env.watchFiles, budget: { _ in
            budgetReads += 1
            return .init(music: 0, artwork: 0)
        }, freeSpaceReserve: 10)
        try cache.adoptWatchSelection(music: ["m0.mp3", "m1.mp3"], artwork: [])
        #expect(cache.reserve(.music, "m0.mp3", bytes: 40, availableBytes: 100, allowOversized: true))
        #expect(cache.reserve(.music, "m1.mp3", bytes: 40, availableBytes: 100, allowOversized: true))
        #expect(budgetReads == 0)
        #expect(cache.reservedBytes(.music, "m0.mp3") == 40)
        // outstanding reservations still count against the shared free-space floor.
        cache.release(.music, "m1.mp3")
        #expect(!cache.reserve(.music, "m1.mp3", bytes: 60, availableBytes: 100, allowOversized: true))
        #expect(cache.reservedBytes(.music, "m1.mp3") == nil)
    }

    @Test("background selection changes retain old files until foreground cleanup")
    func deferredCleanup() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let cache = FileCache(fileStore: env.watchFiles)
        cache.allowsMaintenance = false
        try env.watchFiles.write(.music, "old.mp3", data: Data("old".utf8))
        try cache.adoptWatchSelection(music: ["new.mp3"], artwork: [])
        #expect(cache.hasDurableWatchSelection)
        #expect(env.watchFiles.exists(.music, "old.mp3"))
        cache.allowsMaintenance = true
        #expect(!env.watchFiles.exists(.music, "old.mp3"))
    }
}

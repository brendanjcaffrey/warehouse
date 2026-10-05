import Foundation
import Testing
import SwiftProtobuf
import WatchConnectivity
@testable import Warehouse

@Suite("WatchManualInventory", .serialized)
@MainActor
struct WatchManualInventoryTests {
    typealias Env = WatchContentDeliveryTests.Env

    func request(_ env: Env, queue: PhoneWatchContentQueue, receiver: WatchContentReceiver) async throws -> WatchInventoryRequest {
        receiver.syncDownloadedStatus()
        let request = try #require(env.manualRequests.last)
        try queue.receive(request)
        try await receiver.settledQuery(request)
        return request
    }

    @Test("current-date manual requests use a watch-safe sequence through session activity, transport and restoration")
    func currentDateSequence() async throws {
        let env = try Env()
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp(); metadata.cleanUp() }
        env.now = Date(timeIntervalSince1970: 1_791_133_200)
        let (snapshot, queue, receiver) = try await WatchInventoryTests().prepared(env)
        let session = WatchPhoneSession(library: metadata.receiver(), sessionState: { (true, false) })
        session.content = receiver
        let first = try await request(env, queue: queue, receiver: receiver)
        let sequence = try #require(first.manualSequence)
        #expect(type(of: sequence) == Int64.self)
        #expect(sequence > Int32.max)
        #expect(WatchInventoryRequest(dictionary: try first.encode()) == first)
        #expect(receiver.inventoryPending)
        #expect(receiver.pendingOperations == 0)
        for report in env.inventoryReports {
            #expect(WatchInventoryReport(dictionary: try report.encode()) == report)
            try await queue.settledReceive(report)
        }
        let completion = try #require(env.inventoryCompletions.last)
        #expect(WatchInventoryCompletion(dictionary: try completion.encode()) == completion)
        try receiver.receive(completion)
        #expect(!receiver.inventoryPending)
        #expect(receiver.inventoryFeedback == "Downloaded status synced to iPhone.")

        env.now -= 60
        let restored = try env.receiver()
        session.content = restored
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let second = try await request(env, queue: queue, receiver: restored)
        #expect(second.manualSequence == sequence + 1)
        #expect(WatchInventoryRequest(dictionary: try second.encode()) == second)
        #expect(restored.inventoryPending)
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
    }

    @Test("manual sync discovers 167 local songs when only 65 have phone receipts, without sending valid files")
    func discrepancy() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 276)
        try env.cache(snapshot)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        for _ in 0..<65 {
            let file = try #require(env.outstanding.first)
            let url = try #require(env.queued.last { $0.0 == file }?.1)
            try env.stage(file, url: url)
            await receiver.settledStaged(file)
            env.outstanding.removeAll { $0.id == file.id }
            try await queue.settledReceive(try #require(env.receipts.last))
        }
        #expect(queue.progress().music.downloaded == 65)
        let selected = try snapshot.music.sorted()
        for name in selected.prefix(167) {
            try env.watchFiles.write(.music, name, data: Data(contentsOf: env.files.fileURL(.music, name)))
        }
        let artwork = try #require(try snapshot.artwork.first)
        try env.watchFiles.write(.artwork, artwork, data: Data(contentsOf: env.files.fileURL(.artwork, artwork)))
        let before = env.queued.count
        let request = try await request(env, queue: queue, receiver: receiver)
        for report in env.inventoryReports.reversed() { try await queue.settledReceive(report) }
        #expect(queue.progress().music.downloaded == 167)
        #expect(queue.progress().artwork.downloaded == 1)
        #expect(env.queued.dropFirst(before).allSatisfy { !selected.prefix(167).contains($0.0.filename) })
        #expect(env.inventoryCompletions.last?.request == request)
        try receiver.receive(try #require(env.inventoryCompletions.last))
        #expect(receiver.inventoryFeedback == "Downloaded status synced to iPhone.")
        #expect(!receiver.inventoryPending)
        let restored = try env.queue()
        #expect(restored.progress().music.downloaded == 167)
        #expect(env.phoneDiagnostics.events.contains { $0.kind == .inventoryVerified })
        #expect(env.watchDiagnostics.events.contains { $0.kind == .inventoryManualScanned })
    }

    @Test("manual sync bypasses cooldown and catches missing and same-size corrupt music and artwork")
    func cooldownAndCorruption() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try await WatchInventoryTests().prepared(env)
        await queue.settledRequestInventory()
        try await receiver.settledQuery(try #require(env.inventoryRequests.last))
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        let started = queue.diagnosticState().inventoryStartedAt
        env.inventoryReports.removeAll()
        try env.watchFiles.delete(.music, "m0.mp3")
        let size = try Data(contentsOf: env.watchFiles.fileURL(.music, "m1.mp3")).count
        try env.watchFiles.write(.music, "m1.mp3", data: Data(repeating: 0, count: size))
        let artwork = try #require(env.watchFiles.entries(.artwork).first?.filename)
        let artworkSize = try Data(contentsOf: env.watchFiles.fileURL(.artwork, artwork)).count
        try env.watchFiles.write(.artwork, artwork, data: Data(repeating: 0, count: artworkSize))
        let request = try await request(env, queue: queue, receiver: receiver)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        #expect(queue.progress().music.downloaded == 2)
        #expect(queue.progress().artwork.downloaded == 0)
        #expect(env.inventoryCompletions.last?.request == request)
        #expect(queue.diagnosticState().inventoryStartedAt == started)
        let count = env.inventoryRequests.count
        await queue.settledRequestInventory()
        #expect(env.inventoryRequests.count == count)
        #expect(env.watchFiles.exists(.music, "m1.mp3"))
    }

    @Test("partial replies and completion loss recover across restarts without another manual scan")
    func interrupted() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, original, initialReceiver) = try await WatchInventoryTests().prepared(env, count: 130)
        var queue = original
        var receiver = initialReceiver
        env.transportAvailable = false
        receiver.syncDownloadedStatus()
        #expect(receiver.inventoryPending)
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.inventoryPending)
        env.transportAvailable = true
        receiver.resume()
        let request = try #require(env.manualRequests.last)
        try queue.receive(request)
        try await receiver.settledQuery(request)
        let reports = env.inventoryReports
        #expect(reports.count == 3)
        try await queue.settledReceive(reports[2])
        queue = try env.queue()
        receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.watchFiles.delete(.music, "m0.mp3")
        env.inventoryReports.removeAll()
        env.now += 61
        try queue.receive(request)
        try await receiver.settledQuery(request)
        #expect(env.inventoryReports == reports)
        for report in reports.reversed() { try await queue.settledReceive(report) }
        for report in reports { try await queue.settledReceive(report) }
        queue = try env.queue()
        env.inventoryCompletions.removeAll()
        try queue.receive(request)
        #expect(env.inventoryCompletions.last?.request == request)
        try receiver.receive(try #require(env.inventoryCompletions.last))
        #expect(!receiver.inventoryPending)
        #expect(env.watchDiagnostics.events.count { $0.kind == .inventoryManualScanned } == 1)
    }

    @Test("pending manual sync survives startup resumes and echoed requests during unchanged context import",
          arguments: [false, true])
    func pendingDuringMetadataRestore(reconcileBeforeContext: Bool) async throws {
        let env = try Env()
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp(); metadata.cleanUp() }
        let (snapshot, queue, initialReceiver) = try await WatchInventoryTests().prepared(env)
        env.transportAvailable = false
        initialReceiver.syncDownloadedStatus()
        let request = try #require(env.manualRequests.last)
        let restored = try env.receiver()
        let library = metadata.receiver()
        await library.waitForImport()
        _ = try await metadata.watch.expectWatchLibrary(snapshot.head)
        _ = try await metadata.watch.importWatchLibrary(snapshot)
        let session = WatchPhoneSession(library: library, sessionState: { (true, false) })
        session.content = restored

        if !reconcileBeforeContext { restored.resume() }
        #expect(restored.inventoryPending)
        #expect(restored.inventoryFeedback == "Sync pending. Waiting for iPhone confirmation.")
        if reconcileBeforeContext { try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot) }

        var importGate: CheckedContinuation<Void, Never>?
        defer { importGate?.resume() }
        library.onChanged = {
            await withCheckedContinuation { importGate = $0 }
            try? restored.reconcile(head: library.head, snapshot: library.snapshot)
        }
        session.applyContext(try snapshot.head.encode())
        try await PlayerStoreTests.waitFor { importGate != nil }
        env.transportAvailable = true
        try queue.receive(request)
        session.session(WCSession.default, didReceiveUserInfo: try request.encode())
        try await PlayerStoreTests.waitFor { session.contentActivity.count < 1 }
        restored.resume()
        #expect(restored.inventoryPending)
        #expect(restored.inventoryFeedback == "Sync pending. Waiting for iPhone confirmation.")
        #expect(env.inventoryReports.isEmpty)
        // the echoed request must survive another restart while metadata is still unavailable.
        #expect(try env.receiver().inventoryPending)
        let savedRequests = try JSONDecoder().decode([WatchInventoryRequest].self,
            from: Data(contentsOf: env.root.appending(path: "receiver/inventory-requests.json")))
        #expect(savedRequests.contains(request))

        importGate?.resume()
        importGate = nil
        await library.waitForImport()
        await restored.waitForWork()
        #expect(restored.inventoryPending)
        #expect(!env.inventoryReports.isEmpty)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        let completion = try #require(env.inventoryCompletions.last)
        session.session(WCSession.default, didReceiveUserInfo: try completion.encode())
        try await PlayerStoreTests.waitFor { session.contentActivity.count < 1 }
        #expect(!restored.inventoryPending)
        #expect(restored.inventoryFeedback == "Downloaded status synced to iPhone.")
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
    }

    @Test("new receipts, completed transfers and stale requests cannot undo current delivery")
    func deliveryRaces() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let request = try await request(env, queue: queue, receiver: receiver)
        let reports = env.inventoryReports
        let (file, url) = try #require(env.queued.first)
        try env.stage(file, url: url)
        await receiver.settledStaged(file)
        try await queue.settledReceive(try #require(env.receipts.last))
        for report in reports { try await queue.settledReceive(report) }
        #expect(queue.progress().music.downloaded == 1)
        try await queue.settledFinished(file, error: CocoaError(.fileReadUnknown))
        #expect(queue.progress().music.downloaded == 1)
        let next = try env.snapshot(count: 4, revision: 2)
        try await queue.settledReconcile(head: next.head, snapshot: next)
        try queue.receive(request)
        for report in reports { try await queue.settledReceive(report) }
        #expect(queue.progress().music.downloaded == 1)
        try await receiver.settledReconcile(head: next.head, snapshot: next)
        #expect(receiver.inventoryFeedback?.contains("Library changed") == true)
        #expect(snapshot.head != next.head)
        try queue.reconcile(head: nil, snapshot: nil)
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let confirmations = env.inventoryCompletions.count
        try queue.receive(request)
        #expect(env.inventoryCompletions.count == confirmations)
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("a newer manual action fences reordered old requests and completion messages")
    func reorderedRequests() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try await WatchInventoryTests().prepared(env)
        let first = try await request(env, queue: queue, receiver: receiver)
        let firstReports = env.inventoryReports
        for report in firstReports { try await queue.settledReceive(report) }
        try receiver.receive(.init(request: first))
        env.inventoryReports.removeAll()
        let second = try await request(env, queue: queue, receiver: receiver)
        try queue.receive(first)
        try receiver.receive(.init(request: first))
        #expect(receiver.inventoryPending)
        #expect(queue.diagnosticState().inventoryRequestID == second.id)
        for report in firstReports { try await queue.settledReceive(report) }
        #expect(queue.diagnosticState().inventoryRequestID == second.id)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        try receiver.receive(.init(request: second))
        #expect(!receiver.inventoryPending)
        let bytes = env.phoneDiagnostics.report(deviceModel: "", systemVersion: "").totals?["inventoryVerified:music"]?.bytes
        #expect(bytes == 0)
    }

    @Test("manual scan failures expose retry feedback and preserve local playback files")
    func scanFailure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (snapshot, queue, _) = try await WatchInventoryTests().prepared(env)
        let receiver = try env.receiver(worker: WatchContentWorker(beforeWork: { throw CocoaError(.fileReadNoPermission) }))
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        _ = try await request(env, queue: queue, receiver: receiver)
        #expect(receiver.inventoryFeedback?.hasPrefix("Sync failed:") == true)
        #expect(!receiver.inventoryPending)
        #expect(env.inventoryReports.isEmpty)
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
        #expect(queue.progress().state == .ready)
        let restored = try env.receiver()
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await restored.settledQuery(try #require(env.manualRequests.last))
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        try restored.receive(try #require(env.inventoryCompletions.last))
        #expect(!restored.inventoryPending)
    }

    @Test("a failed phone save withholds completion and remains retryable")
    func phoneSaveFailure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try await WatchInventoryTests().prepared(env)
        _ = try await request(env, queue: queue, receiver: receiver)
        let stateURL = env.root.appending(path: "queue/state.json")
        let original = try Data(contentsOf: stateURL)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        #expect(env.inventoryCompletions.isEmpty)
        #expect(receiver.inventoryPending)
        #expect(queue.errorMessage != nil)
        try FileManager.default.removeItem(at: stateURL)
        try original.write(to: stateURL)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        #expect(env.inventoryCompletions.count == 1)
    }

    @Test("empty or nonregular selected files revoke old claims without deleting playback files", arguments: [false, true])
    func invalidFiles(_ directory: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let (_, queue, receiver) = try await WatchInventoryTests().prepared(env)
        let url = env.watchFiles.fileURL(.music, "m0.mp3")
        try FileManager.default.removeItem(at: url)
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } else { try Data().write(to: url) }
        _ = try await request(env, queue: queue, receiver: receiver)
        for report in env.inventoryReports { try await queue.settledReceive(report) }
        #expect(queue.progress().music.downloaded == 3)
        #expect(env.watchFiles.exists(.music, "m1.mp3"))
        #expect(env.inventoryCompletions.count == 1)
    }

    @Test("bounded processing advances through replay when more than eight batches arrive together")
    func boundedReplay() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 513)
        let queue = try env.queue()
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        _ = try await request(env, queue: queue, receiver: receiver)
        let reports = env.inventoryReports
        #expect(reports.count == 9)
        for report in reports { try queue.receive(report) }
        await queue.waitForWork()
        #expect(env.inventoryCompletions.isEmpty)
        for report in reports { try queue.receive(report) }
        await queue.waitForWork()
        #expect(env.inventoryCompletions.count == 1)
        #expect(queue.diagnosticState().inventoryPending == 0)
        #expect(queue.progress().music.downloaded == 0)
    }

    @Test("account or selection changes while phone hashing is suspended cannot promote stale content", arguments: [false, true])
    func suspendedAuthorityChange(_ accountChanged: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        env.transportAvailable = false
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("music m0.mp3".utf8))
        let gate = WatchContentWorkerTests.Gate()
        defer { gate.release() }
        let queue = try env.queue(worker: WatchContentWorker(beforeWork: { try gate.block() }))
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        _ = try await request(env, queue: queue, receiver: receiver)
        try queue.receive(try #require(env.inventoryReports.first))
        #expect(await gate.waitForEntry())
        let ids = accountChanged ? snapshot.head.playlistIDs : ["p1"]
        let head = WatchLibraryHead(publisher: snapshot.head.publisher, revision: 2,
                                    libraryID: accountChanged ? "other-account" : "account", playlistIDs: ids, metadataReady: true)
        let selected = try WatchLibrarySnapshot.selected(snapshot.validatedLibrary(), ids: ids)
        let next = WatchLibrarySnapshot(head: head, libraryData: try selected.serializedData())
        try queue.reconcile(head: head, snapshot: next)
        gate.release()
        await queue.waitForWork()
        #expect(queue.progress().music.downloaded == 0)
        #expect(env.inventoryCompletions.isEmpty)
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
    }

}

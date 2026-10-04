import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch connectivity background dispatch", .serialized)
@MainActor
struct WatchPhoneSessionTests {
    @MainActor
    final class Env {
        let metadata: WatchLibraryDeliveryTests.Env
        let content: WatchContentDeliveryTests.Env
        let library: WatchLibraryReceiver
        let receiver: WatchContentReceiver
        var session: WatchPhoneSession!
        var systemPending = true
        var finished = 0

        init() throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            content = try WatchContentDeliveryTests.Env()
            library = metadata.receiver()
            receiver = try content.receiver()
            session = WatchPhoneSession(library: library, sessionState: { [unowned self] in (true, systemPending) })
            session.content = receiver
        }

        func hold(_ completed: @escaping () -> Void = {}) {
            session.updateBackgroundLifetime()
            session.lifetime.hold { [self] in finished += 1; completed() }
        }

        func delivered() {
            // no actor task can run until this test yields; the system has delivered its final callback.
            systemPending = false
            session.updateBackgroundLifetime()
            #expect(finished == 0)
        }

        func waitForCompletion() async throws {
            await Task.yield()
            await library.waitForImport()
            try await PlayerStoreTests.waitFor { self.finished == 1 }
            #expect(session.contentActivity.count < 1)
            #expect(library.pendingOperations == 0)
            session.updateBackgroundLifetime()
            #expect(finished == 1)
        }

        func cleanUp() { metadata.cleanUp(); content.cleanUp() }
    }

    @Test("play receipts and transfer completions hold background execution through queue persistence", arguments: [false, true])
    func playCallbacks(transferFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let fileURL = PlayReportQueueTests.tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let transport = PlayReportQueueTests.Transport()
        let queue = PlayReportQueueTests.makeQueue(fileURL: fileURL, transport: transport)
        queue.add(trackId: "t1")
        let play = try #require(queue.pending.first)
        var transferCompleted = false
        env.session.onPlayTransferFinished = { queue.finished($0); transferCompleted = true }
        env.session.onPlayReceipt = { queue.acknowledge($0) }
        var persistedAtCompletion = [PlayPayload]()
        var transferredAtCompletion = false
        env.hold {
            persistedAtCompletion = PlayReportQueueTests.plays(onDiskAt: fileURL)
            transferredAtCompletion = transferCompleted
        }
        env.session.receivePlayCompletion(play.encode(), error: transferFails ? CocoaError(.fileWriteUnknown) : nil)
        env.session.session(WCSession.default, didReceiveUserInfo: PlayReceipt(play).encode())
        env.delivered()
        try await env.waitForCompletion()
        #expect(transferredAtCompletion)
        #expect(persistedAtCompletion.isEmpty)
        #expect(queue.pending.isEmpty)
        #expect(PlayPayload(dictionary: PlayReceipt(play).encode()) == nil)
    }

    @Test("context dispatch holds completion through its asynchronous save and failure", arguments: [false, true])
    func context(saveFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        if saveFails { env.metadata.watch.beforeLibrarySave = { throw CocoaError(.fileWriteOutOfSpace) } }
        var storedHead: WatchLibraryHead?
        env.hold { storedHead = env.library.head }
        env.session.session(WCSession.default, didReceiveApplicationContext: try snapshot.head.encode())
        env.delivered()
        try await env.waitForCompletion()
        #expect(storedHead == (saveFails ? nil : snapshot.head))
        #expect(env.library.refreshFailed == saveFails)
        #expect(try await env.metadata.watch.watchHead() == storedHead)
    }

    @Test("unsupported context releases completion after recording its failure")
    func unsupportedContext() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        var failedAtCompletion = false
        env.hold { failedAtCompletion = env.library.refreshFailed }
        env.session.session(WCSession.default, didReceiveApplicationContext: ["watchLibraryHead": Data("bad".utf8)])
        env.delivered()
        try await env.waitForCompletion()
        #expect(failedAtCompletion)
    }

    @Test("metadata file staging survives delegate source removal and holds background import",
          arguments: ["valid", "corrupt", "missing", "saveFailure"])
    func metadataFile(outcome: String) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let snapshot = try env.content.snapshot(count: 4)
        env.library.expect(snapshot.head)
        await env.library.waitForImport()
        let source = env.metadata.root.appending(path: "incoming.json")
        if outcome != "missing" {
            let data = outcome == "corrupt" ? Data("bad".utf8) : try JSONEncoder().encode(snapshot)
            try data.write(to: source)
        }
        if outcome == "saveFailure" { env.metadata.watch.beforeLibrarySave = { throw CocoaError(.fileWriteOutOfSpace) } }
        var savedAtCompletion: WatchLibrarySnapshot?
        var failedAtCompletion = false
        env.hold {
            savedAtCompletion = env.library.snapshot
            failedAtCompletion = env.library.refreshFailed
        }
        env.session.receiveFile(source, metadata: ["kind": "watchLibrarySnapshot"])
        if outcome != "missing" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: env.metadata.inbox.path).count == 1)
            try FileManager.default.removeItem(at: source)
        }
        env.delivered()
        try await env.waitForCompletion()
        #expect(savedAtCompletion == (outcome == "valid" ? snapshot : nil))
        #expect(failedAtCompletion == (outcome != "valid"))
        #expect(try await env.metadata.watch.watchSnapshot() == savedAtCompletion)
        if outcome == "saveFailure" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: env.metadata.inbox.path).count == 1)
        }
    }

    @Test("delivery reports hold background completion until durable save or write failure", arguments: [false, true])
    func deliveryReport(writeFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        let report = WatchLibraryDeliveryReport(head: snapshot.head, sequence: 1, overall: .init(), playlists: [:])
        let inbox = env.content.root.appending(path: "receiver")
        if writeFails { try Data("blocks directory creation".utf8).write(to: inbox) }
        var persisted: [WatchLibraryDeliveryReport]?
        env.hold {
            persisted = try? JSONDecoder().decode([WatchLibraryDeliveryReport].self,
                                                 from: Data(contentsOf: inbox.appending(path: "phone-progress.json")))
        }
        env.session.session(WCSession.default, didReceiveUserInfo: try report.encode())
        env.delivered()
        try await env.waitForCompletion()
        #expect(persisted == (writeFails ? nil : [report]))
    }

    @Test("receipt query holds completion until persistence and response, including failed persistence", arguments: [false, true])
    func receiptQuery(writeFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        try env.content.cache(snapshot)
        let queue = try env.content.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(env.content.queued.first?.0)
        try env.receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        let inbox = env.content.root.appending(path: "receiver")
        if writeFails { try Data("blocks directory creation".utf8).write(to: inbox) }
        var responsesAtCompletion = 0
        var persisted: [WatchContentReceipt]?
        env.hold {
            responsesAtCompletion = env.content.receipts.count
            persisted = try? JSONDecoder().decode([WatchContentReceipt].self,
                                                 from: Data(contentsOf: inbox.appending(path: "receipts.json")))
        }
        env.session.session(WCSession.default, didReceiveUserInfo: try file.encode(kind: "watchContentQuery"))
        env.delivered()
        try await env.waitForCompletion()
        #expect(responsesAtCompletion == (writeFails ? 0 : 1))
        #expect(persisted == (writeFails ? nil : [.init(file: file, status: .retrying)]))
    }

    @Test("overlapping callbacks and suspended asynchronous import keep all held tasks alive")
    func overlappingCallbacks() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        var release: CheckedContinuation<Void, Never>?
        env.library.onChanged = { await withCheckedContinuation { release = $0 } }
        env.hold()
        var secondFinished = 0
        env.session.lifetime.hold { secondFinished += 1 }
        env.session.session(WCSession.default, didReceiveApplicationContext: try snapshot.head.encode())
        let report = WatchLibraryDeliveryReport(head: snapshot.head, sequence: 1, overall: .init(), playlists: [:])
        env.session.session(WCSession.default, didReceiveUserInfo: try report.encode())
        env.delivered()
        try await PlayerStoreTests.waitFor { release != nil }
        #expect(env.finished == 0 && secondFinished == 0)
        #expect(env.library.pendingOperations == 1)
        release?.resume()
        try await env.waitForCompletion()
        #expect(secondFinished == 1)
    }

    @Test("activation callbacks hold background completion on success and failure", arguments: [false, true])
    func activation(fails: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        var activated = false
        var activatedAtCompletion = false
        env.session.onActivated = { activated = true }
        env.hold { activatedAtCompletion = activated }
        env.session.session(WCSession.default, activationDidCompleteWith: fails ? .notActivated : .activated,
                            error: fails ? CocoaError(.fileReadUnknown) : nil)
        env.delivered()
        try await env.waitForCompletion()
        #expect(activatedAtCompletion == !fails)
    }

    @Test("live messages and reachability callbacks hold completion through remote state handling")
    func remoteCallbacks() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let remote = WatchRemoteStore(send: { _ in })
        env.session.remote = remote
        let payload = RemotePlaybackPayload(trackId: "t0", name: "track", artistName: "artist", artworkFilename: nil, isPlaying: true)
        var stateAtCompletion: RemotePlaybackPayload?
        env.hold { stateAtCompletion = remote.nowPlaying }
        env.session.session(WCSession.default, didReceiveMessage: WatchRemoteMessage.nowPlaying(payload).encode())
        env.session.sessionReachabilityDidChange(WCSession.default)
        env.delivered()
        try await env.waitForCompletion()
        #expect(stateAtCompletion == payload)
    }

    @Test("failed synchronous content staging retains its hold until the failure receipt is persisted")
    func failedContentStaging() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        try env.content.cache(snapshot)
        let queue = try env.content.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(env.content.queued.first?.0)
        try env.receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        var receiptAtCompletion: WatchContentReceipt?
        env.hold { receiptAtCompletion = env.receiver.receipts.last }
        env.session.receiveFile(env.content.root.appending(path: "missing"), metadata: try file.encode())
        env.delivered()
        try await env.waitForCompletion()
        #expect(receiptAtCompletion?.file == file)
        #expect(receiptAtCompletion?.status == .retrying)
        #expect(env.content.receipts.last == receiptAtCompletion)
    }
}

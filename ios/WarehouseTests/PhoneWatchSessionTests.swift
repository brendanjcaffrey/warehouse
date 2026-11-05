import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("PhoneWatchSession")
@MainActor
struct PhoneWatchSessionTests {
    @Test("repeated receipt callbacks keep distinct attempt ids without claiming queue acceptance",
           arguments: [WatchContentStatus.delivered, .retrying, .storageFull, .failed])
    func receiptProbeAttempts(status: WatchContentStatus) async throws {
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "private-library", playlistIDs: [], metadataReady: true)
        let file = WatchContentFile(head: head, type: .artwork, filename: "private-artwork.jpg", bytes: 42,
                                   digest: String(repeating: "a", count: 64))
        let receipt = WatchContentReceipt(file: file, status: status)
        let capture = WatchDiagnostics(logEvents: false)
        var plays = 0
        let phone = PhoneWatchSession(onPlay: { _ in plays += 1 }, diagnostics: capture)
        for _ in 0..<2 { phone.session(WCSession.default, didReceiveUserInfo: try receipt.encode()) }
        phone.session(WCSession.default, didReceiveUserInfo: ["kind": "watchContentReceipt"])
        phone.session(WCSession.default, didReceiveUserInfo: try WatchContentReceipt(file: file, status: .transferring).encode())
        let received = capture.events
        try #require(received.map(\.kind) == [.receiptCallbackReceived, .receiptCallbackReceived])
        let attempts = try received.map { try #require($0.operationID) }
        #expect(Set(attempts).count == 2)
        try await PlayerStoreTests.waitFor { capture.events.filter { $0.kind == .receiptCallbackHandled }.count == 2 }
        let handled = capture.events.filter { $0.kind == .receiptCallbackHandled }
        #expect(Set(handled.compactMap(\.operationID)) == Set(attempts))
        #expect(capture.events.count == 4)
        #expect(capture.events.allSatisfy { $0.id == file.id && $0.status == status && $0.source == .system })
        for event in handled {
            let raw = try #require(received.first { $0.operationID == event.operationID })
            #expect(event.date >= raw.date && (event.elapsed ?? -1) >= 0)
        }
        #expect(plays == 0)
        let report = phone.diagnosticReport(deviceModel: "phone", systemVersion: "27")
        #expect(report.totals?["receiptCallbackReceived:artwork"]?.count == 2)
        #expect(report.totals?["receiptCallbackHandled:artwork"]?.count == 2)
        #expect(report.totals?.values.allSatisfy { $0.bytes == 0 } == true)
        let exported = try #require(report.encoded())
        let text = try #require(String(data: exported, encoding: .utf8))
        #expect(!text.contains(file.filename) && !text.contains(file.digest) && !text.contains("private-library"))
    }

    @Test("receipt probes persist before actor handling and acknowledgment still requires a durable save", arguments: [false, true])
    func receiptCallbackBoundaries(writeFails: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let captureURL = env.root.appending(path: "phone-capture.json")
        env.phoneDiagnostics = WatchDiagnostics(logEvents: false, storeURL: captureURL)
        var failSave = false
        var saves = 0
        let state = WatchDeliveryState(write: { data, url in
            saves += 1
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            try WatchDeliveryState().write(data, url)
        })
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue(state: state)
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(env.queued.first?.0)
        env.outstanding.removeAll { $0.id == file.id }
        try await queue.settledFinished(file, error: nil)
        env.phoneDiagnostics.clear()
        failSave = writeFails
        let previousSaves = saves
        let receipt = WatchContentReceipt(file: file, status: .delivered)
        let phone = PhoneWatchSession(onPlay: { _ in }, diagnostics: env.phoneDiagnostics)
        phone.content = queue
        let before = Date()
        phone.session(WCSession.default, didReceiveUserInfo: try receipt.encode())

        // no actor work can run before this synchronous journal read.
        let early = WatchDiagnostics(logEvents: false, storeURL: captureURL).events
        #expect(early.map(\.kind) == [.receiptCallbackReceived])
        #expect(queue.jobs.first { $0.file == file }?.status == .awaitingReceipt)
        try await PlayerStoreTests.waitFor { saves > previousSaves }
        await queue.waitForWork()
        let report = phone.diagnosticReport(deviceModel: "phone", systemVersion: "27")
        let received = try #require(report.events.first { $0.kind == .receiptCallbackReceived })
        let handled = try #require(report.events.first { $0.kind == .receiptCallbackHandled })
        let operationID = try #require(received.operationID)
        #expect(handled.operationID == operationID)
        #expect(received.id == file.id && handled.id == file.id)
        #expect(received.identity == WatchDiagnosticIdentity(snapshot.head) && handled.identity == received.identity)
        #expect(received.status == .delivered && handled.status == .delivered)
        #expect(received.date >= before && received.date <= handled.date)
        #expect(try #require(handled.elapsed) >= 0)
        #expect(report.events.filter { $0.kind == .phoneAcknowledged }.count == (writeFails ? 0 : 1))
        if let acknowledged = report.events.first(where: { $0.kind == .phoneAcknowledged }) {
            #expect(acknowledged.date >= handled.date && acknowledged.id == file.id)
        }
        #expect(report.totals?["receiptCallbackReceived:music"]?.bytes == 0)
        #expect(report.totals?["receiptCallbackHandled:music"]?.bytes == 0)
        let restored = try env.queue()
        #expect(restored.jobs.first { $0.file == file }?.status == (writeFails ? .awaitingReceipt : .delivered))
        let exported = try #require(report.encoded())
        let decoded = try #require(WatchDiagnosticReport.decode(exported))
        #expect(decoded.events.map(\.kind) == report.events.map(\.kind))
        let text = try #require(String(data: exported, encoding: .utf8))
        #expect(!text.contains(file.filename) && !text.contains(file.digest))
    }

    @Test("content receipts arriving before matching phone metadata survive relaunch", arguments: [false, true])
    func pendingMetadataReceipt(storageFull: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let original = try env.snapshot(count: 4)
        try env.cache(original)
        var queue = try env.queue()
        try await queue.settledReconcile(head: original.head, snapshot: original)
        let file = try #require(env.queued.first?.0)
        let next = try env.snapshot(count: 4, revision: 2)
        try queue.reconcile(head: next.head, snapshot: nil)
        let phone = PhoneWatchSession(onPlay: { _ in })
        phone.content = queue
        let status: WatchContentStatus = storageFull ? .storageFull : .delivered
        phone.receive(userInfo: try WatchContentReceipt(file: file, status: status).encode())
        var received = false
        phone.publishLibrary = { received = true }
        phone.receive(userInfo: ["kind": "watchLibraryRequest"])
        try await PlayerStoreTests.waitFor { received }
        #expect(queue.jobs.first { $0.file == file }?.status != status)
        queue = try env.queue()
        phone.content = queue
        try await queue.settledReconcile(head: next.head, snapshot: next)
        #expect(queue.jobs.first { $0.file == file }?.status == status)
        #expect(env.phoneDiagnostics.events.contains { $0.kind == (storageFull ? .contentStorageFull : .phoneAcknowledged) })
    }

    @Test("diagnostic messages are acknowledged only after the report is saved")
    func receivesDiagnosticReport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let session = PhoneWatchSession(
            onPlay: { _ in }, diagnosticInbox: inbox)
        let capture = WatchDiagnostics(logEvents: false)
        capture.record(.init(kind: .playbackStalled, id: UUID(), source: .http))
        let data = try #require(capture.report(deviceModel: "Apple Watch", systemVersion: "11").encoded())
        let reply = await withCheckedContinuation { continuation in
            session.receive(data: data) { continuation.resume(returning: $0) }
        }
        #expect(reply == Data("saved".utf8))
        #expect(inbox.reports.count == 2)
        let saved = try inbox.reports.map { try #require(WatchDiagnosticReport.decode(Data(contentsOf: $0))) }
        #expect(saved[0].pairID != nil && saved[0].pairID == saved[1].pairID)
        #expect(saved.allSatisfy { $0.build?.number.isEmpty == false })
        let badReply = await withCheckedContinuation { continuation in
            session.receive(data: Data("bad".utf8)) { continuation.resume(returning: $0) }
        }
        #expect(badReply.isEmpty)
        #expect(inbox.reports.count == 2)
    }

    @Test("session completion and durable receipt callbacks reach the phone export with the same opaque identity")
    func exportsContentCallbacks() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 5)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = env.queued[0]
        let session = PhoneWatchSession(onPlay: { _ in }, diagnostics: env.phoneDiagnostics)
        session.content = queue
        env.outstanding.removeAll { $0.id == file.id }
        #expect(session.receiveFileCompletion(metadata: try file.encode(), error: nil))
        while queue.jobs.first?.status != .awaitingReceipt { await Task.yield() }
        var report = session.diagnosticReport(deviceModel: "phone", systemVersion: "26")
        #expect(report.delivery?.music.delivered.count == .zero)
        #expect(report.delivery?.receiptWait == 1)
        #expect(report.count(.contentCompleted) == 1)
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.stage(file, url: url)
        await receiver.settledStaged(file)
        session.receive(userInfo: try #require(env.receipts.last).encode())
        while queue.jobs.first?.status != .delivered { await Task.yield() }
        report = session.diagnosticReport(deviceModel: "phone", systemVersion: "26")
        #expect(report.delivery?.music.delivered.count == 1)
        #expect(report.totals?["phoneAcknowledged:music"]?.bytes == file.bytes)
        #expect(report.events.first { $0.kind == .phoneAcknowledged }?.identity == WatchDiagnosticIdentity(snapshot.head))
        let watch = env.watchDiagnostics.report(deviceModel: "watch", systemVersion: "26", delivery: receiver.diagnosticState())
        #expect(watch.count(.contentStaged) == 1 && watch.count(.contentCommitted) == 1)
        #expect(watch.delivery?.music.delivered.bytes == report.delivery?.music.delivered.bytes)
        #expect(session.receiveFileCompletion(metadata: ["kind": "watchLibrarySnapshot",
                   "watchLibraryKey": PhoneWatchLibraryPublisher.key(snapshot.head)], error: nil))
        while env.phoneDiagnostics.events.last?.kind != .metadataCompleted { await Task.yield() }
        #expect(env.phoneDiagnostics.events.last?.identity?.revision == snapshot.head.revision)
        #expect(!session.receiveFileCompletion(metadata: [:], error: nil))
        let next = try #require(queue.jobs.first { $0.status == .transferring }?.file)
        env.outstanding.removeAll { $0.id == next.id }
        #expect(session.receiveFileCompletion(metadata: try next.encode(), error: CocoaError(.fileWriteUnknown)))
        while queue.jobs.first(where: { $0.file == next })?.status != .retrying { await Task.yield() }
        report = session.diagnosticReport(deviceModel: "phone", systemVersion: "26")
        #expect(report.count(.contentTransferFailed) == 1)
        #expect(report.events.contains { $0.kind == .contentRetry && $0.errorCode == NSFileWriteUnknownError })
        #expect(report.delivery?.music.states["retrying"] == 1)
    }

    @Test("cold background plays are acknowledged only after atomic persistence")
    func durableBackgroundPlays() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "phone-watch-background.test")
        let watchURL = PlayReportQueueTests.tempFileURL()
        defer { try? FileManager.default.removeItem(at: watchURL.deletingLastPathComponent()) }
        let transport = PlayReportQueueTests.Transport()
        let watch = PlayReportQueueTests.makeQueue(fileURL: watchURL, transport: transport)
        watch.add(PlayPayload(trackId: "t1"))
        let play = try #require(transport.sent.first)
        var receipts = [PlayPayload]()
        var fails = true
        let phone = PhoneWatchSession(onPlay: { payload in
            if fails { throw CocoaError(.fileWriteUnknown) }
            try env.store.recordWatchPlay(payload)
        }, acknowledgePlay: { receipts.append($0) })
        phone.receive(userInfo: play.encode())
        // the following marker uses the same actor hop to wait for the failed receipt.
        var marker = false
        phone.publishLibrary = { marker = true }
        phone.receive(userInfo: ["kind": "watchLibraryRequest"])
        try await PlayerStoreTests.waitFor { marker }
        #expect(receipts.isEmpty && env.store.pending.isEmpty)
        fails = false
        phone.receive(userInfo: play.encode())
        try await PlayerStoreTests.waitFor { receipts.count == 1 }
        #expect(UpdatesStoreTests.persisted(at: env.fileURL).count == 1)
        // terminate before the acknowledgment arrives; recreate both peers.
        let relaunchedWatch = PlayReportQueueTests.makeQueue(fileURL: watchURL, transport: transport)
        let relaunchedStore = UpdatesStoreTests.relaunch(env)
        let relaunchedPhone = PhoneWatchSession(onPlay: { try relaunchedStore.recordWatchPlay($0) },
                                               acknowledgePlay: { receipts.append($0) })
        relaunchedPhone.receive(userInfo: play.encode())
        try await PlayerStoreTests.waitFor { receipts.count == 2 }
        #expect(relaunchedStore.pending.count == 1)
        relaunchedWatch.acknowledge(receipts[1])
        #expect(PlayReportQueueTests.makeQueue(fileURL: watchURL, transport: transport).pending.isEmpty)
        relaunchedPhone.receive(userInfo: play.encode())
        try await PlayerStoreTests.waitFor { receipts.count == 3 }
        #expect(relaunchedStore.pending.count == 1)
    }

    @MainActor
    final class PlayedTracks {
        var ids = [String]()
    }

    @MainActor
    final class ReceivedCommands {
        var commands = [RemoteCommand]()
    }

    static func makeSession(
        played: PlayedTracks,
        commands: ReceivedCommands
    ) -> PhoneWatchSession {
        PhoneWatchSession(
            onPlay: { played.ids.append($0.trackId) },
            onCommand: { commands.commands.append($0) })
    }

    @Test("received plays are forwarded to the callback")
    func forwardsReceivedPlaysToTheCallback() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played, commands: ReceivedCommands())

        session.receive(userInfo: PlayPayload(trackId: "t1").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t1"])
    }

    @Test("user info that isn't a play is ignored")
    func ignoresUserInfoThatIsNotAPlay() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played, commands: ReceivedCommands())

        session.receive(userInfo: [:])
        session.receive(userInfo: ["id": 7, "trackId": "t1"])
        // a valid play after the junk proves the junk never reached the
        // callback, without racing the ignored calls
        session.receive(userInfo: PlayPayload(trackId: "t2").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t2"])
    }

    @Test("commands from the watch are forwarded to the callback")
    func forwardsCommandsToTheCallback() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: WatchRemoteMessage.command(.next).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.next])
    }

    @Test("a state request isn't handed to the player")
    func ignoresStateRequests() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: WatchRemoteMessage.command(.requestState).encode())
        // a real command after it proves the request never reached the
        // callback, without racing the ignored call
        session.receive(message: WatchRemoteMessage.command(.playPause).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.playPause])
    }

    @Test("messages that aren't commands are ignored")
    func ignoresMessagesThatAreNotCommands() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: [:])
        session.receive(message: WatchRemoteMessage.nowPlaying(nil).encode())
        session.receive(message: WatchRemoteMessage.command(.pause).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.pause])
    }
    @Test("obsolete file requests fail safely without invoking playback or delivery")
    func obsoleteRequests() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)
        for kind in ["cachedFile", "cachedFileSize", "reconcileCachedFiles", "cancelCachedFile"] {
            let result: String? = await withCheckedContinuation { continuation in
                session.receive(message: ["kind": kind, "token": "legacy-secret"]) { reply in
                    continuation.resume(returning: reply["result"] as? String)
                }
            }
            #expect(result == "unavailable")
        }
        #expect(commands.commands.isEmpty)
    }

    @Test("activation pushes and durable library requests invoke the phone publisher")
    func publishesLibrary() async throws {
        let session = PhoneWatchSession( onPlay: { _ in })
        var published = 0
        session.publishLibrary = { published += 1 }
        session.push()
        #expect(published == 1)
        session.receive(userInfo: ["kind": "watchLibraryRequest"])
        try await PlayerStoreTests.waitFor { published == 2 }
    }

}

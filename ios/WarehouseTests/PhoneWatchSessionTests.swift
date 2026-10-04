import Foundation
import Testing
@testable import Warehouse

@Suite("PhoneWatchSession")
@MainActor
struct PhoneWatchSessionTests {
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

import Foundation
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch connectivity background dispatch", .serialized)
@MainActor
struct WatchPhoneSessionTests {
    @Test("empty and full delivery captures reach the phone within the live message budget", arguments: [0, 512])
    func sendsFullDiagnosticCapture(eventCount: Int) async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let library = env.receiver()
        await library.waitForImport()
        let inbox = WatchDiagnosticInbox(directory: env.root.appending(path: "reports"))
        let phone = PhoneWatchSession(onPlay: { _ in }, diagnosticInbox: inbox)
        let capture = WatchDiagnostics(logEvents: false)
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "account", playlistIDs: [])
        for index in 0..<eventCount {
            let file = WatchContentFile(head: head, type: .music, filename: "m\(index).mp3", bytes: 42, digest: "digest")
            capture.delivery(.contentCommitted, file: file, source: .cache)
        }
        let report = capture.report(deviceModel: "watch", systemVersion: "26")
        let session = WatchPhoneSession(library: library, sendDiagnosticData: { data, completion in
            #expect(data.count <= 65_536, "live diagnostic message has \(data.count) bytes")
            guard data.count <= 65_536 else {
                completion(.failure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadTooLarge.rawValue)))
                return
            }
            phone.receive(data: data) { reply in
                Task { @MainActor in completion(.success(reply)) }
            }
        })
        let result = await withCheckedContinuation { continuation in
            session.sendDiagnostics(report) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result { Issue.record("send failed: \(error)") }
        #expect(inbox.reports.count == 2)
        if let watch = inbox.reports.first(where: { $0.lastPathComponent.hasPrefix("watch-") }) {
            let restored = try #require(WatchDiagnosticReport.decode(Data(contentsOf: watch)))
            #expect(restored.events.map(\.id) == report.events.map(\.id))
            #expect(restored.totals?.mapValues(\.count) == report.totals?.mapValues(\.count))
            #expect(restored.totals?.mapValues(\.bytes) == report.totals?.mapValues(\.bytes))
            #expect(restored.capture?.id == report.capture?.id)
        }
    }

    @Test("failed diagnostic messages stop the send and retain the full capture", arguments: [true, false])
    func diagnosticSendFailure(connectionFails: Bool) async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let library = env.receiver()
        await library.waitForImport()
        let capture = WatchDiagnostics(logEvents: false)
        for _ in 0..<512 { capture.record(.init(kind: .playbackStalled, id: UUID(), source: .system)) }
        let report = capture.report(deviceModel: "watch", systemVersion: "26")
        var sent = 0
        let session = WatchPhoneSession(library: library, sendDiagnosticData: { _, completion in
            sent += 1
            if sent == 1 { completion(.success(WatchDiagnosticMessage.more)) } else if connectionFails {
                completion(.failure(NSError(domain: WCErrorDomain, code: WCError.Code.notReachable.rawValue)))
            } else { completion(.success(Data())) }
        })
        var failure: WatchDiagnosticSendError?
        session.sendDiagnostics(report) {
            if case .failure(let error) = $0 { failure = error }
        }
        #expect(sent == 2)
        #expect(failure == (connectionFails ? .connectivity(code: WCError.Code.notReachable.rawValue) : .phoneRejected))
        #expect(capture.events.count == 512)
        #expect(capture.report(deviceModel: "", systemVersion: "").capture?.id == report.capture?.id)
    }

    @MainActor
    final class RemoteEnv {
        struct Request {
            let command: RemoteCommand
            let reply: ([String: Any]) -> Void
            let fail: () -> Void
        }

        let metadata: WatchLibraryDeliveryTests.Env
        var session: WatchPhoneSession!
        var remote: WatchRemoteStore!
        var requests = [Request]()
        var reachable = true
        var delayed: CheckedContinuation<Void, Never>?
        var delays = [Int]()
        var resumedDelays = 0

        init() throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            session = WatchPhoneSession(library: metadata.receiver(), sessionState: { (true, false) },
                                        remoteReachable: { [unowned self] in reachable },
                                        sendRemoteMessage: { [unowned self] message, reply, fail in
                guard case .command(let command) = WatchRemoteMessage(dictionary: message) else { return }
                requests.append(.init(command: command, reply: reply, fail: fail))
            })
            remote = WatchRemoteStore(send: { [unowned self] in session.send($0, completion: $1) }, retryDelay: { [weak self] attempt in
                guard let self else { return }
                delays.append(attempt)
                await withCheckedContinuation { self.delayed = $0 }
                resumedDelays += 1
            })
            session.remote = remote
        }

        func start() async throws {
            await session.library.waitForImport()
            remote.setReachable(true)
            reply(0, WatchRemoteStoreTests.song)
            try await PlayerStoreTests.waitFor { !self.remote.isReconciling }
        }

        func reply(_ index: Int, _ payload: RemotePlaybackPayload?) {
            requests[index].reply(WatchRemoteMessage.nowPlaying(payload).encode())
        }

        func releaseDelay() {
            delayed?.resume()
            delayed = nil
        }

        func cleanUp() {
            remote.setReachable(false)
            releaseDelay()
            metadata.cleanUp()
        }
    }

    @Test("a failed remote command reconciles while the phone remains reachable")
    func failedRemoteCommand() async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let library = metadata.receiver()
        await library.waitForImport()
        var commands = [RemoteCommand]()
        var fail: (() -> Void)?
        let session = WatchPhoneSession(library: library, remoteReachable: { true }, sendRemoteMessage: { message, _, failure in
            if case .command(let command) = WatchRemoteMessage(dictionary: message) {
                commands.append(command)
                fail = failure
            }
        })
        let remote = WatchRemoteStore(send: { session.send($0, completion: $1) })
        session.remote = remote
        remote.setReachable(true)
        remote.apply(.nowPlaying(WatchRemoteStoreTests.song))
        remote.command(.playPause)
        let failure = try #require(fail)
        failure()
        try await PlayerStoreTests.waitFor { session.contentActivity.count < 1 }
        #expect(remote.isReachable)
        #expect(commands == [.requestState, .playPause, .requestState])
    }

    @Test("delivery failures, lost replies and malformed replies reconcile controls without resending toggles",
          arguments: [RemoteCommand.playPause, .pause, .toggleShuffle, .cycleRepeat], ["delivery", "lostReply", "malformed"])
    func reconcileRemoteCommand(command: RemoteCommand, outcome: String) async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        env.remote.command(command)
        let optimistic = env.remote.nowPlaying
        let actual = outcome == "delivery" ? WatchRemoteStoreTests.song : optimistic
        #expect(optimistic != WatchRemoteStoreTests.song)
        if outcome == "malformed" {
            env.requests[1].reply(["invalid": true])
        } else {
            env.requests[1].fail()
        }
        #expect(env.session.contentActivity.count == 1)
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        #expect(env.remote.isReachable)
        #expect(env.remote.isReconciling)
        #expect(env.requests.map(\.command) == [.requestState, command, .requestState])
        env.reply(2, actual)
        try await PlayerStoreTests.waitFor { !env.remote.isReconciling }
        #expect(env.remote.nowPlaying == actual)
        #expect(!env.remote.reconciliationFailed)
        #expect(env.delays.isEmpty)
        #expect(env.session.contentActivity.count < 1)
    }

    @Test("persistent query errors stop after three attempts and an explicit retry recovers")
    func boundedRemoteReconciliation() async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        env.remote.command(.toggleShuffle)
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        for index in 2...3 {
            env.requests[index].fail()
            try await PlayerStoreTests.waitFor { env.delayed != nil }
            #expect(env.requests.count == index + 1)
            #expect(env.remote.isReconciling)
            env.releaseDelay()
            try await PlayerStoreTests.waitFor { env.requests.count == index + 2 }
        }
        env.requests[4].fail()
        try await PlayerStoreTests.waitFor { env.remote.reconciliationFailed }
        #expect(!env.remote.isReconciling)
        #expect(env.requests.map(\.command) == [.requestState, .toggleShuffle, .requestState, .requestState, .requestState])
        #expect(env.delays == [1, 2])
        #expect(env.delayed == nil)
        env.remote.setReachable(true)
        try await PlayerStoreTests.waitFor { env.session.contentActivity.count < 1 }
        #expect(env.requests.count == 5)
        env.remote.requestState()
        #expect(env.remote.isReconciling && !env.remote.reconciliationFailed)
        env.reply(5, nil)
        try await PlayerStoreTests.waitFor { !env.remote.isReconciling }
        #expect(env.remote.nowPlaying == nil)
        #expect(!env.remote.reconciliationFailed)
    }

    @Test("a lost reply after the phone applies a toggle does not apply it twice",
          arguments: [RemoteCommand.toggleShuffle, .cycleRepeat])
    func appliedPhoneCommandReplyLost(command: RemoteCommand) async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        let phone = PlayerStoreTests.makePlayer()
        phone.play(PlayerStoreTests.songs(3), token: nil, baseURL: nil)
        env.remote.apply(.nowPlaying(RemotePlaybackPayload(player: phone)))
        env.remote.command(command)
        phone.apply(env.requests[1].command)
        let applied = try #require(RemotePlaybackPayload(player: phone))
        #expect(applied.isShuffled == (command == .toggleShuffle))
        #expect(applied.repeatMode == (command == .cycleRepeat ? .all : .off))
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        phone.apply(env.requests[2].command)
        env.reply(2, RemotePlaybackPayload(player: phone))
        try await PlayerStoreTests.waitFor { !env.remote.isReconciling }
        #expect(env.remote.nowPlaying == applied)
        #expect(RemotePlaybackPayload(player: phone) == applied)
        #expect(env.requests.map(\.command) == [.requestState, command, .requestState])
    }

    @Test("an older reconciliation cannot replace a newer pending command", arguments: [false, true])
    func newerRemoteCommand(oldQueryFails: Bool) async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        env.remote.command(.playPause)
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        env.remote.command(.toggleShuffle)
        let newer = env.remote.nowPlaying
        if oldQueryFails { env.requests[2].fail() } else { env.reply(2, WatchRemoteStoreTests.song) }
        try await PlayerStoreTests.waitFor { env.session.contentActivity.count < 1 }
        #expect(env.remote.nowPlaying == newer)
        #expect(env.requests.count == 4)
        #expect(env.delays.isEmpty)
        env.reply(3, WatchRemoteStoreTests.song.with(isShuffled: true))
        try await PlayerStoreTests.waitFor { env.remote.nowPlaying == WatchRemoteStoreTests.song.with(isShuffled: true) }
        #expect(!env.remote.isReconciling && !env.remote.reconciliationFailed)
        // a duplicated old callback has no authority to trigger another query.
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { env.session.contentActivity.count < 1 }
        #expect(env.requests.count == 4)
    }

    @Test("new commands, phone pushes and disconnection cancel a delayed query", arguments: ["command", "push", "disconnect"])
    func cancelDelayedRemoteQuery(event: String) async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        env.remote.command(.cycleRepeat)
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        env.requests[2].fail()
        try await PlayerStoreTests.waitFor { env.delayed != nil }
        switch event {
        case "command": env.remote.command(.playPause)
        case "push":
            env.session.session(WCSession.default, didReceiveMessage: WatchRemoteMessage.nowPlaying(WatchRemoteStoreTests.song).encode())
            try await PlayerStoreTests.waitFor { !env.remote.isReconciling }
        default:
            env.reachable = false
            env.session.sessionReachabilityDidChange(WCSession.default)
            try await PlayerStoreTests.waitFor { !env.remote.isReachable }
        }
        env.releaseDelay()
        try await PlayerStoreTests.waitFor { env.resumedDelays == 1 }
        #expect(env.requests.count == (event == "command" ? 4 : 3))
        #expect(!env.remote.isReconciling && !env.remote.reconciliationFailed)
    }

    @Test("a phone disappearing during a command does not spin and reconnection refreshes state")
    func remoteCommandDisconnect() async throws {
        let env = try RemoteEnv()
        defer { env.cleanUp() }
        try await env.start()
        env.remote.command(.next)
        env.reachable = false
        env.requests[1].fail()
        try await PlayerStoreTests.waitFor { !env.remote.isReachable }
        #expect(env.requests.count == 2)
        #expect(!env.remote.isReconciling)
        env.reachable = true
        env.session.sessionReachabilityDidChange(WCSession.default)
        try await PlayerStoreTests.waitFor { env.requests.count == 3 }
        env.reply(2, nil)
        try await PlayerStoreTests.waitFor { !env.remote.isReconciling }
        #expect(env.remote.nowPlaying == nil)
    }

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
        queue.add(PlayPayload(trackId: "t1"))
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
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(env.content.queued.first?.0)
        try await env.receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
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
        let remote = WatchRemoteStore(send: { _, _ in })
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
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let file = try #require(env.content.queued.first?.0)
        try await env.receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
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

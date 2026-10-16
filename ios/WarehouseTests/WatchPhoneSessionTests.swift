import Foundation
import SwiftProtobuf
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch connectivity background dispatch", .serialized)
@MainActor
struct WatchPhoneSessionTests {
    private final class ActivationAvailability {
        var value = false
    }

    @Test("background activation requests metadata only when the accepted snapshot is missing", arguments: [false, true])
    func backgroundLibraryRequest(accepted: Bool) async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: [], metadataReady: true)
        _ = try await env.watch.expectWatchLibrary(head)
        if accepted { _ = try await env.watch.importWatchLibrary(.init(head: head, libraryData: Library().serializedData())) }
        let library = env.receiver()
        await library.waitForImport()
        var reads = 0
        var queued = [[String: Any]]()
        let session = WatchPhoneSession(library: library, libraryTransport: .init(
            available: { true }, outstanding: { reads += 1; return queued }, enqueue: { queued.append($0) }),
            sessionState: { (true, false) })
        session.allowsMaintenance = { false }
        for _ in 0..<4 { session.session(WCSession.default, activationDidCompleteWith: .activated, error: nil) }
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        await session.waitForLibraryRequest()
        #expect(accepted ? reads == 0 : (1...4).contains(reads))
        #expect(queued.count == (accepted ? 0 : 1))
        #expect(accepted || queued.first.flatMap(WatchLibraryRequest.init(dictionary:)) != nil)
    }

    @Test("persisted content receipts wait for specific phone queries after activation", arguments: [false, true])
    func activationReceipts(fails: Bool) async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        let env = try WatchContentDeliveryTests.Env()
        defer { metadata.cleanUp(); env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = try #require(env.queued.first)
        var receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        try env.stage(file, url: url)
        await receiver.settledStaged(file)
        receiver = try env.receiver()
        #expect(receiver.receipts == [.init(file: file, status: .delivered)])
        let available = ActivationAvailability()
        var queued = [[String: Any]]()
        let session = WatchPhoneSession(library: metadata.receiver(), libraryTransport: .init(
            available: { available.value }, outstanding: { queued }, enqueue: { queued.append($0) }), sessionState: { (available.value, false) })
        session.content = receiver
        #expect(queued.isEmpty)
        available.value = !fails
        session.session(WCSession.default, activationDidCompleteWith: fails ? .notActivated : .activated, error: nil)
        try await PlayerStoreTests.waitFor {
            let pending = session.contentActivity.count
            return pending == 0
        }
        await session.waitForLibraryRequest()
        let receipts = queued.compactMap(WatchContentReceipt.init(dictionary:))
        #expect(receipts.isEmpty)
        #expect(receiver.receipts == [.init(file: file, status: .delivered)])
        session.session(WCSession.default, activationDidCompleteWith: fails ? .notActivated : .activated, error: nil)
        try await PlayerStoreTests.waitFor {
            let pending = session.contentActivity.count
            return pending == 0
        }
        #expect(queued.compactMap(WatchContentReceipt.init(dictionary:)) == receipts)
    }

    @Test("library requests wait for restoration, report accepted metadata and deduplicate outstanding user info")
    func libraryRequests() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "account", playlistIDs: [], metadataReady: true)
        #expect(try await env.watch.expectWatchLibrary(head))
        #expect(try await env.watch.importWatchLibrary(.init(head: head, libraryData: Library().serializedData())))
        let receiver = env.receiver()
        var queued = [[String: Any]]()
        var available = true
        let transport = WatchPhoneSession.LibraryTransport(available: { available }, outstanding: { queued }, enqueue: { queued.append($0) })
        let session = WatchPhoneSession(library: receiver, libraryTransport: transport, sessionState: { (true, false) })
        var completed = 0
        session.requestLibrary()
        session.lifetime.hold { completed += 1 }
        #expect(completed == 0)
        session.requestLibrary()
        await session.waitForLibraryRequest()
        let pendingActivity = session.contentActivity.count
        #expect(completed == 1 && pendingActivity == 0)
        #expect(queued.count == 1 && WatchLibraryRequest(dictionary: queued[0])?.acceptedHead == head)
        session.requestLibrary()
        await session.waitForLibraryRequest()
        #expect(queued.count == 1)
        let next = WatchLibraryHead(publisher: head.publisher, revision: 8, libraryID: "account", playlistIDs: [], metadataReady: true)
        receiver.expect(next)
        await receiver.waitForImport()
        queued.removeAll()
        session.requestLibrary()
        await session.waitForLibraryRequest()
        // the pending context is not evidence of an imported snapshot.
        #expect(WatchLibraryRequest(dictionary: queued[0])?.acceptedHead == head)
        #expect(try await env.watch.importWatchLibrary(.init(head: next, libraryData: Library().serializedData())))
        receiver.resume()
        session.requestLibrary()
        await session.waitForLibraryRequest()
        #expect(queued.count == 2 && WatchLibraryRequest(dictionary: queued[1])?.acceptedHead == next)
        available = false
        queued.removeAll()
        session.requestLibrary()
        await session.waitForLibraryRequest()
        #expect(queued.isEmpty)
        let empty = WatchPhoneSession(library: WatchLibraryReceiver(database: LibraryDatabase(inMemory: true),
                                                                   directory: env.root.appending(path: "empty")), libraryTransport: transport)
        available = true
        empty.requestLibrary()
        await empty.waitForLibraryRequest()
        #expect(queued.count == 1 && WatchLibraryRequest(dictionary: queued[0])?.acceptedHead == nil)
        empty.requestLibrary()
        await empty.waitForLibraryRequest()
        #expect(queued.count == 1)
    }

    @Test("empty and full delivery captures reach the phone within the live message budget", arguments: [0, 4096])
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

        init(persistDiagnostics: Bool = false) throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            content = try WatchContentDeliveryTests.Env()
            if persistDiagnostics {
                content.watchDiagnostics = WatchDiagnostics(logEvents: false, storeURL: content.root.appending(path: "capture.json"))
            }
            library = metadata.receiver()
            receiver = try content.receiver()
            session = WatchPhoneSession(library: library, sessionState: { [unowned self] in (true, systemPending) },
                                        diagnostics: content.watchDiagnostics, contentDirectory: content.root.appending(path: "receiver"))
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

    @Test("file delegate entry and staging persist before actor handling and retain the background hold", arguments: [false, true])
    func fileCallbackBoundaries(missing: Bool) async throws {
        let env = try Env(persistDiagnostics: true)
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        try env.content.cache(snapshot)
        let queue = try env.content.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, source) = try #require(env.content.queued.first)
        try await env.receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let capture = env.content.watchDiagnostics
        capture.startProcess()
        capture.applicationChanged(.background)
        capture.sceneChanged(.background)
        env.hold()
        env.session.receivedBackgroundTask()
        let before = Date()
        env.session.receiveFile(missing ? env.content.root.appending(path: "missing") : source, metadata: try file.encode())
        let restored = WatchDiagnostics(logEvents: false, storeURL: env.content.root.appending(path: "capture.json"))
        let early = restored.events.filter { $0.id == file.id }
        let staging: WatchDiagnostic.Kind = missing ? .contentStagingFailed : .contentStagingCompleted
        #expect(early.filter { $0.kind != .contentStagingProgress }.map(\.kind) == [.contentCallbackReceived, staging])
        let phases: [WatchDiagnosticStagingPhase] = missing ? [.validating, .checkingSource] : [
            .validating, .checkingSource, .checkingCapacity, .preparingDirectory, .writingManifest, .copying, .publishing, .cleaningUp
        ]
        #expect(early.compactMap(\.stagingPhase) == phases)
        let operationID = try #require(early.first?.operationID)
        #expect(early.allSatisfy { $0.operationID == operationID })
        let elapsed = early.dropFirst().compactMap(\.elapsed)
        #expect(elapsed.count == early.count - 1 && elapsed == elapsed.sorted())
        #expect(early.allSatisfy { $0.date >= before && $0.date <= Date() })
        #expect(early.allSatisfy { $0.lifecycle?.scene == .background && $0.lifecycle?.application == .background })
        #expect(early.allSatisfy { $0.lifecycle?.processID == capture.report(deviceModel: "", systemVersion: "").lifecycle?.processID })
        #expect(early.last?.elapsed != nil)
        #expect(restored.report(deviceModel: "", systemVersion: "").totals?["\(staging.rawValue):music"]?.bytes == 0)
        #expect(restored.report(deviceModel: "", systemVersion: "").totals?["contentStagingProgress:music"]?.bytes == 0)
        #expect(env.session.contentActivity.count == 1)
        #expect(env.content.receipts.isEmpty)
        if !missing {
            #expect(env.receiver.diagnosticState().stagedFiles == 1)
            try FileManager.default.removeItem(at: source)
        }
        env.delivered()
        try await env.waitForCompletion()
        let handled = try #require(capture.events.first { $0.id == file.id && $0.kind == .contentCallbackHandled })
        let stagingEvent = try #require(early.last)
        #expect(handled.date >= stagingEvent.date)
        #expect(handled.operationID == operationID)
        #expect(try #require(handled.elapsed) >= 0)
        #expect(env.content.receipts.last?.status == (missing ? .retrying : .delivered))
        let completed = try #require(capture.events.last { $0.kind == .backgroundCompleted })
        #expect(completed.date >= handled.date)
        #expect(completed.background?.callbackOperations == 0)
        #expect(completed.background?.contentOperations == 0)
        let data = try #require(env.session.diagnosticReport(deviceModel: "watch", systemVersion: "26").encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(file.filename) && !text.contains(file.digest) && !text.contains("account"))
    }

    @Test("repeated callbacks retain separate attempt ids while committing the transfer once")
    func repeatedFileAttempts() async throws {
        let env = try Env(persistDiagnostics: true)
        defer { env.cleanUp() }
        await env.library.waitForImport()
        let snapshot = try env.content.snapshot(count: 4)
        try env.content.cache(snapshot)
        let queue = try env.content.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, source) = try #require(env.content.queued.first)
        try await env.receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        env.hold()
        for _ in 0..<2 { env.session.receiveFile(source, metadata: try file.encode()) }
        let restored = WatchDiagnostics(logEvents: false, storeURL: env.content.root.appending(path: "capture.json"))
        let events = restored.events.filter { $0.id == file.id }
        let attempts = Set(events.filter { $0.kind == .contentCallbackReceived }.compactMap(\.operationID))
        #expect(attempts.count == 2)
        for attempt in attempts {
            let progress = events.filter { $0.operationID == attempt }
            #expect(progress.first?.kind == .contentCallbackReceived && progress.last?.kind == .contentStagingCompleted)
            #expect(progress.compactMap(\.stagingPhase).contains(.copying))
        }
        env.delivered()
        try await env.waitForCompletion()
        let handled = env.content.watchDiagnostics.events.filter { $0.kind == .contentCallbackHandled && $0.id == file.id }
        #expect(Set(handled.compactMap(\.operationID)) == attempts)
        #expect(env.receiver.receipts == [.init(file: file, status: .delivered)])
        #expect(try env.content.receiver().receipts == env.receiver.receipts)
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
        #expect(env.content.watchDiagnostics.events.last?.kind == .contextCallbackReceived)
        env.delivered()
        try await env.waitForCompletion()
        #expect(storedHead == (saveFails ? nil : snapshot.head))
        #expect(env.library.refreshFailed == saveFails)
        #expect(try await env.metadata.watch.watchHead() == storedHead)
        #expect(env.content.watchDiagnostics.events.contains { $0.kind == .contextCallbackHandled && $0.id == snapshot.head.publisher })
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
        let early = env.content.watchDiagnostics.events.filter {
            [.metadataCallbackReceived, .metadataStagingCompleted, .metadataStagingFailed, .metadataCallbackHandled].contains($0.kind)
        }
        #expect(early.map(\.kind) == [.metadataCallbackReceived, outcome == "missing" ? .metadataStagingFailed : .metadataStagingCompleted])
        #expect(early.first?.id == early.last?.id)
        if outcome != "missing" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: env.metadata.inbox.path).count == 1)
            try FileManager.default.removeItem(at: source)
        }
        env.delivered()
        try await env.waitForCompletion()
        #expect(savedAtCompletion == (outcome == "valid" ? snapshot : nil))
        #expect(failedAtCompletion == (outcome != "valid"))
        #expect(try await env.metadata.watch.watchSnapshot() == savedAtCompletion)
        #expect(env.content.watchDiagnostics.events.contains { $0.kind == .metadataCallbackHandled && $0.id == early.first?.id })
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
        #expect(env.content.watchDiagnostics.events.last?.kind == .contentQueryReceived)
        #expect(!env.content.watchDiagnostics.events.contains { $0.kind == .contentQueryHandled })
        env.delivered()
        try await env.waitForCompletion()
        #expect(responsesAtCompletion == (writeFails ? 0 : 1))
        #expect(persisted == (writeFails ? nil : [.init(file: file, status: .retrying)]))
        let handled = try #require(env.content.watchDiagnostics.events.first { $0.kind == .contentQueryHandled })
        #expect(handled.id == file.id)
        #expect(try #require(handled.elapsed) >= 0)
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

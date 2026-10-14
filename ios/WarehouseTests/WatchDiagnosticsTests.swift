import Foundation
import Testing
@testable import Warehouse

@Suite("watch diagnostics")
@MainActor
struct WatchDiagnosticsTests {
    @Test("concurrent delegate probes persist without actor execution or journal sequence loss")
    func concurrentDelegateJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(capacity: 32, logEvents: false, storeURL: url)
        capture.startProcess()
        capture.applicationChanged(.background)
        capture.sceneChanged(.background)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<40 {
                        capture.record(.init(kind: .contentCallbackReceived, id: UUID(), source: .phone))
                        _ = capture.report(deviceModel: "watch", systemVersion: "26")
                    }
                }
            }
        }
        let expected = capture.report(deviceModel: "watch", systemVersion: "26")
        let encoded = try #require(expected.encoded())
        let decoded = try #require(WatchDiagnosticReport.decode(encoded))
        let restored = WatchDiagnostics(capacity: 32, logEvents: false, storeURL: url).report(deviceModel: "watch", systemVersion: "26")
        #expect(restored.capture?.totalEvents == 323)
        #expect(restored.capture?.droppedEvents == 291)
        #expect(restored.capture?.persistenceFailed == false)
        #expect(restored.events.map(\.id) == expected.events.map(\.id))
        #expect(restored.totals == decoded.totals)
        #expect(restored.totals?["contentCallbackReceived:metadata"]?.count == 320)
        #expect(Set(restored.events.map(\.id)).count == 32)
        #expect(restored.events.allSatisfy { $0.lifecycle?.application == .background && $0.lifecycle?.scene == .background })
        #expect(restored.events.allSatisfy { $0.lifecycle?.processID == expected.lifecycle?.processID })
    }

    @Test("capture clear preserves observed lifecycle while relaunch uses a new process identity")
    func processLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(logEvents: false, storeURL: url)
        capture.startProcess()
        let original = try #require(capture.report(deviceModel: "watch", systemVersion: "26").lifecycle)
        #expect(original.scene == .unknown && original.application == .unknown)
        capture.applicationChanged(.background)
        capture.sceneChanged(.background)
        capture.sceneChanged(.background)
        #expect(capture.events.count == 3)
        capture.clear()
        let cleared = capture.report(deviceModel: "watch", systemVersion: "26")
        #expect(cleared.events.isEmpty)
        #expect(cleared.lifecycle?.processID == original.processID)
        #expect(cleared.lifecycle?.scene == .background)
        let restored = WatchDiagnostics(logEvents: false, storeURL: url)
        restored.startProcess()
        let relaunched = restored.report(deviceModel: "watch", systemVersion: "26")
        #expect(relaunched.capture?.id == cleared.capture?.id)
        #expect(relaunched.lifecycle?.processID != original.processID)
        #expect(relaunched.lifecycle?.scene == .unknown)
        #expect(relaunched.events.map(\.kind) == [.processStarted])
        let data = try #require(relaunched.encoded())
        let decoded = try #require(WatchDiagnosticReport.decode(data))
        #expect(decoded.lifecycle == relaunched.lifecycle)
        #expect(decoded.events.first?.lifecycle == relaunched.lifecycle)
    }

    @Test("journaled events survive relaunch without rewriting the full ring or double counting receipts")
    func journalDurability() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "account", playlistIDs: [])
        let file = WatchContentFile(head: head, type: .music, filename: "private-name.mp3", bytes: 42, digest: "secret")
        capture.delivery(.contentCommitted, file: file, source: .cache)
        let checkpoint = try Data(contentsOf: url)
        for _ in 0..<64 { capture.delivery(.contentReused, file: file, source: .cache) }
        #expect(try Data(contentsOf: url) == checkpoint)
        let restored = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        let report = restored.report(deviceModel: "watch", systemVersion: "26")
        #expect(report.capture?.totalEvents == 65)
        #expect(report.capture?.droppedEvents == 63)
        #expect(report.totals?["contentCommitted:music"]?.bytes == 42)
        #expect(report.totals?["contentReused:music"] == nil)
        let journal = url.appendingPathExtension("events")
        let entries = try Data(contentsOf: journal)
        #expect(entries.split(separator: 10).count == 64)
        let text = try #require(String(data: entries, encoding: .utf8))
        #expect(!text.contains(file.filename))
        #expect(!text.contains(file.digest))
        restored.delivery(.receiptSent, file: file, source: .phone)
        #expect(try Data(contentsOf: url) != checkpoint)
        #expect(try Data(contentsOf: journal).isEmpty)
        #expect(WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
            .report(deviceModel: "watch", systemVersion: "26").capture?.totalEvents == 66)
    }

    @Test("interrupted journal cleanup cannot duplicate totals or revive a cleared capture")
    func checkpointReplay() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let journal = url.appendingPathExtension("events")
        let capture = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        for _ in 0..<65 { capture.record(.init(kind: .queueWakeup, id: UUID(), source: .system)) }
        let oldJournal = try Data(contentsOf: journal)
        capture.record(.init(kind: .queueWakeup, id: UUID(), source: .system))
        try oldJournal.write(to: journal)
        let restored = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        #expect(restored.report(deviceModel: "watch", systemVersion: "26").capture?.totalEvents == 66)
        #expect(restored.report(deviceModel: "watch", systemVersion: "26").totals?["queueWakeup:metadata"]?.count == 66)
        restored.clear()
        try oldJournal.write(to: journal)
        let cleared = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        #expect(cleared.events.isEmpty)
        #expect(cleared.report(deviceModel: "watch", systemVersion: "26").capture?.totalEvents == 0)
        cleared.record(.init(kind: .activationChanged, id: UUID(), source: .system))
        let latest = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url).report(deviceModel: "watch", systemVersion: "26")
        #expect(latest.capture?.totalEvents == 1)
        #expect(latest.totals?["queueWakeup:metadata"] == nil)
    }

    @Test("an interrupted journal append preserves its valid prefix and reports uncertain persistence")
    func damagedJournal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(logEvents: false, storeURL: url)
        for _ in 0..<2 { capture.record(.init(kind: .queueWakeup, id: UUID(), source: .system)) }
        let journal = url.appendingPathExtension("events")
        var bytes = try Data(contentsOf: journal)
        bytes.append(contentsOf: "{interrupted".utf8)
        try bytes.write(to: journal)
        let restored = WatchDiagnostics(logEvents: false, storeURL: url)
        #expect(restored.events.count == 2)
        #expect(restored.report(deviceModel: "watch", systemVersion: "26").capture?.persistenceFailed == true)
        restored.record(.init(kind: .queueWakeup, id: UUID(), source: .system))
        let latest = WatchDiagnostics(logEvents: false, storeURL: url).report(deviceModel: "watch", systemVersion: "26")
        #expect(latest.capture?.totalEvents == 3)
        #expect(latest.totals?["queueWakeup:metadata"]?.count == 3)
        #expect(latest.capture?.persistenceFailed == true)
    }

    @Test("a lost checkpoint cannot silently claim journal continuity", arguments: [false, true])
    func lostCheckpoint(corrupt: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(logEvents: false, storeURL: url)
        for _ in 0..<2 { capture.record(.init(kind: .queueWakeup, id: UUID(), source: .system)) }
        if corrupt { try Data("invalid".utf8).write(to: url) } else { try FileManager.default.removeItem(at: url) }
        let restored = WatchDiagnostics(logEvents: false, storeURL: url).report(deviceModel: "watch", systemVersion: "26")
        #expect(restored.events.isEmpty)
        #expect(restored.capture?.persistenceFailed == true)
        #expect(restored.capture?.id != capture.report(deviceModel: "watch", systemVersion: "26").capture?.id)
    }

    @Test("outstanding transfer ages survive relaunch and receipt waits retain their identity")
    func transferAges() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let enqueuedAt = env.now
        env.now.addTimeInterval(36_000)
        let restored = try env.queue()
        let outstanding = try #require(restored.diagnosticState().outstandingTransfers)
        #expect(Set(outstanding.map(\.id)) == Set(env.outstanding.map(\.id)))
        #expect(outstanding.allSatisfy { $0.startedAt == enqueuedAt && $0.ageSeconds == 36_000 })
        let file = try #require(env.outstanding.first)
        env.outstanding.removeAll { $0.id == file.id }
        try await restored.settledFinished(file, error: nil)
        let waiting = try #require(restored.diagnosticState().receiptTransfers?.first)
        #expect(waiting.id == file.id)
        #expect(waiting.startedAt == enqueuedAt)
        #expect(waiting.ageSeconds == 36_000)
        let data = try #require(env.phoneDiagnostics.report(deviceModel: "phone", systemVersion: "26",
                                                           delivery: restored.diagnosticState()).encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(file.filename))
        #expect(!text.contains(file.digest))
        #expect(!text.contains("account"))
    }

    @Test("a full larger capture remains bounded, persists, and shares in chunks")
    func largerCapture() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = WatchDiagnostics(logEvents: false)
        capture.startProcess()
        capture.applicationChanged(.background)
        capture.sceneChanged(.background)
        capture.clear()
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "account", playlistIDs: [])
        for _ in 0..<4100 {
            capture.record(.init(kind: .contentFailed, id: UUID(), source: .system, fileType: .music,
                                 bytes: 42, throughput: 3, bufferSeconds: 1, elapsed: 2,
                                 error: CocoaError(.fileWriteOutOfSpace), detail: .speaker,
                                 waitingReason: .evaluatingBufferingRate, identity: WatchDiagnosticIdentity(head), status: .retrying))
        }
        let report = capture.report(deviceModel: "watch", systemVersion: "26")
        #expect(report.events.count == 4096)
        #expect(report.capture?.droppedEvents == 4)
        #expect(report.totals?["contentFailed:music"]?.count == 4100)
        let data = try #require(report.encoded())
        #expect(data.count > 1_024_000)
        let url = root.appending(path: "saved.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)
        let persisted = WatchDiagnostics(logEvents: false, storeURL: url)
        let restored = persisted.report(deviceModel: "watch", systemVersion: "26")
        #expect(restored.events.map(\.id) == report.events.map(\.id))
        #expect(restored.events.map(\.lifecycle) == report.events.map(\.lifecycle))
        #expect(restored.capture?.droppedEvents == 4)
        let latest = WatchDiagnostic(kind: .queueWakeup, id: UUID(), source: .system)
        persisted.record(latest)
        let relaunched = WatchDiagnostics(logEvents: false, storeURL: url).report(deviceModel: "watch", systemVersion: "26")
        #expect(relaunched.events.count == 4096)
        #expect(relaunched.events.last?.id == latest.id)
        #expect(relaunched.capture?.droppedEvents == 5)
        #expect(relaunched.totals?["contentFailed:music"]?.count == 4100)
        let inbox = WatchDiagnosticInbox(directory: root.appending(path: "inbox"))
        let messages = try WatchDiagnosticMessage.messages(data)
        for message in messages.dropLast() {
            #expect(inbox.receiveMessage(message, phone: report) == WatchDiagnosticMessage.more)
        }
        #expect(inbox.receiveMessage(try #require(messages.last), phone: report) == WatchDiagnosticMessage.saved)
        #expect(inbox.reports.count == 2)
        let savedURL = try #require(inbox.reports.first)
        let saved = try #require(WatchDiagnosticReport.decode(Data(contentsOf: savedURL)))
        #expect(saved.events.map(\.id) == report.events.map(\.id))
        let oversized = WatchDiagnosticReport(capturedAt: report.capturedAt, deviceModel: "watch", systemVersion: "26",
                                               events: report.events + [latest])
        #expect(!inbox.receive(try #require(oversized.encoded())))
    }

    @Test("staged file ages survive recreation while a metadata pause blocks commits")
    func stagedAgesAndPause() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, url) = try #require(env.queued.first)
        let receiver = try env.receiver()
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        receiver.pause()
        try env.stage(file, url: url)
        let stagedURL = env.root.appending(path: "receiver").appending(path: file.id.uuidString)
        let stagedAt = Date().addingTimeInterval(-36_000)
        try FileManager.default.setAttributes([.creationDate: stagedAt], ofItemAtPath: stagedURL.path)
        env.now = stagedAt.addingTimeInterval(36_000)
        await receiver.settledStaged(file)
        let state = receiver.diagnosticState()
        #expect(state.processing?.paused == true)
        #expect(state.processing?.authorized == false)
        #expect(state.stagedFiles == 1)
        let staged = try #require(state.stagedTransfers?.first)
        #expect(staged.id == file.id)
        #expect(staged.authorized == false)
        #expect(abs(try #require(staged.ageSeconds) - 36_000) < 1)
        #expect(env.receipts.isEmpty)
        let restored = try env.receiver()
        #expect(restored.diagnosticState().stagedTransfers?.first?.startedAt == staged.startedAt)
        try await restored.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(restored.diagnosticState().stagedTransfers?.isEmpty == true)
        #expect(restored.diagnosticState().processing?.authorized == true)
        #expect(env.receipts.last?.status == .delivered)
    }

    @Test("legacy queue dates stay unknown rather than acquiring a fictitious age")
    func unknownTransferAge() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let url = env.root.appending(path: "queue/state.json")
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var jobs = try #require(saved["jobs"] as? [[String: Any]])
        for index in jobs.indices { jobs[index].removeValue(forKey: "enqueuedAt") }
        saved["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        let restored = try env.queue()
        let transfers = try #require(restored.diagnosticState().outstandingTransfers)
        #expect(transfers.count == env.outstanding.count)
        #expect(transfers.allSatisfy { $0.startedAt == nil && $0.ageSeconds == nil })
    }

    @Test("delivery totals outlive the ring and relaunch, while replayed verification adds no bytes")
    func cumulativeDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "private-account-url", playlistIDs: [])
        let file = WatchContentFile(head: head, type: .music, filename: "private-name.mp3", bytes: 42, digest: "secret")
        capture.delivery(.contentCommitted, file: file, source: .cache)
        capture.delivery(.contentReused, file: file, source: .cache)
        for _ in 0..<600 { capture.delivery(.receiptSent, file: file, source: .phone) }
        let restored = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        let report = restored.report(deviceModel: "watch", systemVersion: "26")
        #expect(report.capture?.totalEvents == 602)
        #expect(report.capture?.droppedEvents == 600)
        #expect(report.totals?["contentCommitted:music"]?.bytes == 42)
        #expect(report.totals?["contentReused:music"] == nil)
        #expect(report.totals?["receiptSent:music"]?.count == 600)
        #expect(report.totals?["receiptSent:music"]?.bytes == 0)
        let data = try #require(report.encoded())
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(!encoded.contains("private-account-url"))
        #expect(!encoded.contains("private-name"))
        #expect(!encoded.contains("secret"))
        #expect(report.events.last?.identity?.publisher == head.publisher)
        restored.clear()
        #expect(restored.report(deviceModel: "", systemVersion: "").capture?.totalEvents == 0)
    }

    @Test("upgrading a legacy ring preserves events without claiming historical cumulative coverage")
    func legacyCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "capture.json")
        let oldDate = Date(timeIntervalSince1970: 1000)
        let legacy = WatchDiagnosticReport(capturedAt: oldDate, deviceModel: "watch", systemVersion: "26",
            events: [.init(kind: .activationChanged, id: UUID(), source: .system, date: oldDate)])
        try #require(legacy.encoded()).write(to: url)
        let capture = WatchDiagnostics(logEvents: false, storeURL: url)
        let report = capture.report(deviceModel: "watch", systemVersion: "26")
        #expect(report.events.count == 1)
        #expect(report.capture?.startedAt == oldDate)
        #expect(try #require(report.capture?.totalsStartedAt) > oldDate)
        #expect(report.totals?.isEmpty == true)
    }

    @Test("capture survives relaunch and clear starts a distinct run")
    func persistsCapture() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "capture.json")
        let id = UUID()
        let first = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        first.record(.init(kind: .phoneAccepted, id: id, source: .phone))
        first.record(.init(kind: .phoneDelivered, id: id, source: .phone))
        first.record(.init(kind: .playbackStarted, id: UUID(), source: .http))

        let restored = WatchDiagnostics(capacity: 2, logEvents: false, storeURL: url)
        #expect(restored.events.map(\.kind) == [.phoneDelivered, .playbackStarted])
        restored.clear()
        #expect(WatchDiagnostics(logEvents: false, storeURL: url).events.isEmpty)
    }

    @Test("the phone saves multiple bounded reports for sharing")
    func savesReports() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let capture = WatchDiagnostics(logEvents: false)
        capture.record(.init(kind: .phoneMiss, id: UUID(), source: .phone,
                             error: NSError(domain: "secret-token=abc", code: 7)))
        let data = try #require(capture.report(deviceModel: "Apple Watch", systemVersion: "11").encoded())
        #expect(inbox.receive(data))
        #expect(inbox.receive(data))
        #expect(inbox.reports.count == 2)
        let saved = try Data(contentsOf: #require(inbox.reports.first))
        #expect(WatchDiagnosticReport.decode(saved)?.count(.phoneMiss) == 1)
        #expect(!(String(data: saved, encoding: .utf8) ?? "").contains("secret-token"))
        #expect(!inbox.receive(Data("invalid".utf8)))
        #expect(!inbox.receive(Data(count: WatchDiagnosticMessage.maximumReportBytes + 1)))
        #expect(inbox.reports.count == 2)
        #expect(WatchDiagnosticInbox(directory: root).reports.count == 2)
    }

    @Test("chunked reports save only after completion and preserve reports above the old inbox limit")
    func chunkedReports() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let capture = WatchDiagnostics(logEvents: false)
        let head = WatchLibraryHead(publisher: UUID(), revision: 7, libraryID: "account", playlistIDs: [])
        for _ in 0..<512 {
            capture.record(.init(kind: .contentFailed, id: UUID(), source: .system, fileType: .music,
                                 bytes: 42, throughput: 3, bufferSeconds: 1, elapsed: 2,
                                 error: CocoaError(.fileWriteOutOfSpace), detail: .speaker,
                                 waitingReason: .evaluatingBufferingRate, identity: WatchDiagnosticIdentity(head), status: .retrying))
        }
        let watch = capture.report(deviceModel: "watch", systemVersion: "26")
        let phone = capture.report(deviceModel: "phone", systemVersion: "26")
        let data = try #require(watch.encoded())
        #expect(data.count > 256_000)
        let messages = try WatchDiagnosticMessage.messages(data)
        for message in messages.dropLast() {
            #expect(inbox.receiveMessage(message, phone: phone) == WatchDiagnosticMessage.more)
            #expect(inbox.reports.isEmpty)
        }
        #expect(inbox.receiveMessage(try #require(messages.last), phone: phone) == WatchDiagnosticMessage.saved)
        #expect(inbox.reports.count == 2)
        let saved = try inbox.reports.map { try #require(WatchDiagnosticReport.decode(Data(contentsOf: $0))) }
        #expect(saved[0].pairID != nil && saved[0].pairID == saved[1].pairID)
        #expect(saved.allSatisfy { $0.events.map(\.id) == watch.events.map(\.id) })
    }

    @Test("missing, out-of-order and malformed chunks never save a partial capture")
    func rejectsIncompleteChunks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let report = WatchDiagnostics(logEvents: false).report(deviceModel: "phone", systemVersion: "26")
        let messages = try WatchDiagnosticMessage.messages(Data(count: 60_000))
        #expect(inbox.receiveMessage(messages[1], phone: report).isEmpty)
        #expect(inbox.receiveMessage(messages[0], phone: report) == WatchDiagnosticMessage.more)
        #expect(inbox.receiveMessage(messages[2], phone: report).isEmpty)
        #expect(inbox.receiveMessage(messages[1], phone: report).isEmpty)
        for message in messages { _ = inbox.receiveMessage(message, phone: report) }
        #expect(inbox.reports.isEmpty)
        let bad = WatchDiagnosticMessage(kind: "watchDiagnosticsChunk", id: UUID(), index: 0, count: Int.max, payload: Data([1]))
        #expect(inbox.receiveMessage(try JSONEncoder().encode(bad), phone: report).isEmpty)
        #expect(throws: WatchDiagnosticSendError.reportTooLarge) {
            try WatchDiagnosticMessage.messages(Data(count: WatchDiagnosticMessage.maximumReportBytes + 1))
        }
    }

    @Test("a chunked capture gets no success acknowledgment when the phone cannot persist it")
    func chunkedSaveFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let inbox = WatchDiagnosticInbox(directory: root)
        let capture = WatchDiagnostics(logEvents: false)
        for _ in 0..<512 { capture.record(.init(kind: .playbackStalled, id: UUID(), source: .system)) }
        let report = capture.report(deviceModel: "watch", systemVersion: "26")
        let messages = try WatchDiagnosticMessage.messages(#require(report.encoded()))
        var phoneCaptures = 0
        func phone() -> WatchDiagnosticReport { phoneCaptures += 1; return report }
        for message in messages.dropLast() {
            #expect(inbox.receiveMessage(message, phone: phone()) == WatchDiagnosticMessage.more)
        }
        #expect(phoneCaptures == 0)
        #expect(inbox.receiveMessage(try #require(messages.last), phone: phone()).isEmpty)
        #expect(phoneCaptures == 1)
        #expect(inbox.reports.isEmpty)
        #expect(capture.events.count == 512)
    }

    @Test("report subtitles use the capture date rather than the phone receipt date")
    func reportCaptureDates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let date = Date(timeIntervalSince1970: 1000)
        let report = WatchDiagnosticReport(capturedAt: date, deviceModel: "watch", systemVersion: "26", events: [])
        #expect(inbox.receive(try #require(report.encoded())))
        let watch = try #require(inbox.reports.first)
        let phone = try #require(inbox.savePhone(report))
        #expect(inbox.capturedAt(for: watch) == date)
        #expect(inbox.capturedAt(for: phone) == date)
        let restored = WatchDiagnosticInbox(directory: root)
        #expect(restored.capturedAt(for: watch) == date)
        #expect(restored.capturedAt(for: phone) == date)
    }

    @Test("deleting one report removes its file and preserves the other across relaunch")
    func deletesReport() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root)
        let report = WatchDiagnostics(logEvents: false).report(deviceModel: "phone", systemVersion: "26")
        let deleted = try #require(inbox.savePhone(report))
        #expect(inbox.receive(try #require(report.encoded())))
        let retained = try #require(inbox.reports.first { $0 != deleted })
        let retainedData = try Data(contentsOf: retained)
        try inbox.delete(deleted)
        #expect(!FileManager.default.fileExists(atPath: deleted.path))
        #expect(inbox.reports == [retained])
        #expect(try Data(contentsOf: retained) == retainedData)
        #expect(WatchDiagnosticInbox(directory: root).reports == [retained])
        try inbox.delete(retained)
        #expect(inbox.reports.isEmpty)
        #expect(WatchDiagnosticInbox(directory: root).reports.isEmpty)
    }

    @Test("failed deletion retains the row and cannot delete a file outside the inbox")
    func failedDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchDiagnosticInbox(directory: root.appending(path: "inbox"))
        let report = WatchDiagnostics(logEvents: false).report(deviceModel: "phone", systemVersion: "26")
        let url = try #require(inbox.savePhone(report))
        let moved = root.appending(path: "moved")
        try FileManager.default.moveItem(at: url.deletingLastPathComponent(), to: moved)
        #expect(throws: (any Error).self) { try inbox.delete(url) }
        #expect(inbox.reports == [url])
        let outside = moved.appending(path: url.lastPathComponent)
        #expect(throws: (any Error).self) { try inbox.delete(outside) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("phone replies distinguish misses and rejected requests")
    func classifiesReplies() {
        #expect(WatchDiagnostic.Kind.phoneReply(.cacheMiss) == .phoneMiss)
        #expect(WatchDiagnostic.Kind.phoneReply(.unauthorized) == .requestRejected)
        #expect(WatchDiagnostic.Kind.phoneReply(.queueFull) == .requestRejected)
        #expect(WatchDiagnostic.Kind.phoneReply(.accepted) == .phoneAccepted)
    }

    @Test("capture is bounded and contains only safe structured fields")
    func redactsAndBounds() {
        let capture = WatchDiagnostics(capacity: 2, logEvents: false)
        let id = UUID()
        capture.record(.init(kind: .phoneAccepted, id: id, source: .phone, bytes: 42))
        capture.record(.init(kind: .httpStarted, id: id, source: .http, error: NSError(
            domain: "secret-token=abc", code: 401)))
        capture.record(.init(kind: .storageFailure, id: id, source: .phone,
                             throughput: .infinity, bufferSeconds: .nan, elapsed: 3))
        #expect(capture.events.count == 2)
        let data = try? JSONEncoder().encode(capture.events)
        let encoded = String(data: data ?? Data(), encoding: .utf8) ?? ""
        #expect(!encoded.contains("secret-token"))
        #expect(!encoded.contains("abc"))
        #expect(encoded.contains("storageFailure"))
        #expect(!encoded.contains("Infinity"))
        #expect(!encoded.contains("NaN"))
        #expect(!encoded.contains("filename"))
        #expect(!encoded.contains("token"))
        let line = WatchDiagnostics.line(for: capture.events[0]) ?? ""
        #expect(line == line.lowercased())
        #expect(!line.contains("secret-token"))
    }

}

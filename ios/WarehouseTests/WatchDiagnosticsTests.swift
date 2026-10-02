import Foundation
import Testing
@testable import Warehouse

@Suite("watch diagnostics")
@MainActor
struct WatchDiagnosticsTests {
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
        #expect(!inbox.receive(Data(count: 256_001)))
        #expect(inbox.reports.count == 2)
        #expect(WatchDiagnosticInbox(directory: root).reports.count == 2)
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

    @Test("phone provider emits the actual acceptance reason without credentials")
    func providerReason() {
        let store = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let capture = WatchDiagnostics(logEvents: false)
        let provider = PhoneFileProvider(fileStore: store, currentToken: { "private-token" },
                                         outstanding: { [] }, enqueue: { _, _ in }, diagnostics: capture)
        let transfer = WatchFileTransfer(type: .music, filename: "missing.mp3")
        #expect(provider.request(transfer, token: "private-token") == .cacheMiss)
        #expect(provider.request(transfer, token: "stale-token") == .unauthorized)
        #expect(capture.events.map(\.kind) == [.phoneMiss, .requestRejected])
        #expect(capture.events.map(\.reply) == [.cacheMiss, .unauthorized])
        let encoded = String(data: (try? JSONEncoder().encode(capture.events)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!encoded.contains("private-token"))
        #expect(!encoded.contains("missing.mp3"))
    }
}

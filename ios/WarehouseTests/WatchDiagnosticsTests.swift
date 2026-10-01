import Foundation
import Testing
@testable import Warehouse

@Suite("watch diagnostics")
@MainActor
struct WatchDiagnosticsTests {
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

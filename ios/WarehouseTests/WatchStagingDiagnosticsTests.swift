import Foundation
import Testing
@testable import Warehouse

@Suite("watch synchronous staging diagnostics")
@MainActor
struct WatchStagingDiagnosticsTests {
    @Test("capacity lookup is inside its durable phase and rejects insufficient or unknown space", arguments: [false, true])
    func capacityBoundary(unknown: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try Data("music".utf8).write(to: source)
        let file = try descriptor(source)
        let captureURL = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(logEvents: false, storeURL: captureURL)
        let attempt = UUID()
        var lookups = 0
        func capacity() -> Int64? {
            lookups += 1
            let persisted = WatchDiagnostics(logEvents: false, storeURL: captureURL)
            #expect(persisted.events.last?.stagingPhase == .checkingCapacity)
            #expect(persisted.events.last?.operationID == attempt)
            return unknown ? nil : 0
        }
        let directory = root.appending(path: "inbox")
        #expect(throws: CocoaError.self) {
            try WatchContentReceiver.stage(source, file: file, directory: directory, availableBytes: capacity()) { phase in
                capture.staging(phase, file: file, operationID: attempt, elapsed: 0)
            }
        }
        #expect(lookups == 1)
        #expect(capture.events.compactMap(\.stagingPhase) == [.validating, .checkingSource, .checkingCapacity])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: source) == Data("music".utf8))
    }

    @Test("a failed copy retains its phase evidence and removes the unpublished manifest")
    func interruptedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try Data("music".utf8).write(to: source)
        let file = try descriptor(source)
        let captureURL = root.appending(path: "capture.json")
        let capture = WatchDiagnostics(logEvents: false, storeURL: captureURL)
        let directory = root.appending(path: "inbox")
        let attempt = UUID()
        #expect(throws: CocoaError.self) {
            try WatchContentReceiver.stage(source, file: file, directory: directory, availableBytes: 1_000_000_000) { phase in
                capture.staging(phase, file: file, operationID: attempt, elapsed: 0)
                if phase == .copying {
                    let persisted = WatchDiagnostics(logEvents: false, storeURL: captureURL)
                    #expect(persisted.events.last?.stagingPhase == .copying)
                    do { try FileManager.default.removeItem(at: source) } catch { Issue.record(error) }
                }
            }
        }
        #expect(capture.events.compactMap(\.stagingPhase) == [
            .validating, .checkingSource, .checkingCapacity, .preparingDirectory, .writingManifest, .copying, .cleaningUp
        ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let restored = WatchDiagnostics(logEvents: false, storeURL: captureURL)
        #expect(restored.events.map(\.operationID) == capture.events.map(\.operationID))
        let data = try #require(restored.report(deviceModel: "watch", systemVersion: "26").encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(file.filename) && !text.contains(file.digest) && !text.contains("account"))
    }

    private func descriptor(_ source: URL) throws -> WatchContentFile {
        let fingerprint = try WatchContentFile.fingerprint(source)
        return WatchContentFile(head: .init(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: [], metadataReady: true),
                                type: .music, filename: "private.mp3", bytes: fingerprint.bytes, digest: fingerprint.digest)
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class WatchDiagnosticInbox {
    private let directory: URL
    private(set) var reports: [URL] = []
    private var incoming: [UUID: Incoming] = [:]

    private struct Incoming {
        let count: Int
        var nextIndex = 0
        var data = Data()
        var updatedAt = Date()
    }

    init(directory: URL = FileStore.defaultRootURL().appending(path: "watch-reports")) {
        self.directory = directory
        refresh()
    }

    @discardableResult
    func receive(_ data: Data, phone: WatchDiagnosticReport? = nil) -> Bool {
        guard data.count <= WatchDiagnosticMessage.maximumReportBytes,
              var report = WatchDiagnosticReport.decode(data), report.events.count <= 512 else { return false }
        let pairID = UUID()
        if phone != nil { report.pairID = pairID }
        guard let cleanData = report.encoded() else { return false }
        let filename = "watch-\(Int(report.capturedAt.timeIntervalSince1970))-\(UUID().uuidString).json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if var phone {
                phone.pairID = pairID
                guard savePhone(phone) != nil else { return false }
            }
            try cleanData.write(to: directory.appending(path: filename), options: .atomic)
            refresh()
            return true
        } catch {
            return false
        }
    }

    func receiveMessage(_ data: Data, phone: @autoclosure () -> WatchDiagnosticReport) -> Data {
        guard let message = WatchDiagnosticMessage.decode(data) else {
            return receive(data, phone: phone()) ? WatchDiagnosticMessage.saved : Data()
        }
        incoming = incoming.filter { Date().timeIntervalSince($0.value.updatedAt) < 120 }
        let maximumChunks = (WatchDiagnosticMessage.maximumReportBytes + WatchDiagnosticMessage.chunkBytes - 1)
            / WatchDiagnosticMessage.chunkBytes
        guard message.count > 1,
              message.count <= maximumChunks,
              message.index >= 0, message.index < message.count,
              !message.payload.isEmpty, message.payload.count <= WatchDiagnosticMessage.chunkBytes else { return Data() }
        if message.index == 0 {
            if incoming.count >= 4, let oldest = incoming.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                incoming.removeValue(forKey: oldest)
            }
            incoming[message.id] = Incoming(count: message.count)
        }
        guard var transfer = incoming[message.id], transfer.count == message.count,
              transfer.nextIndex == message.index,
              transfer.data.count + message.payload.count <= WatchDiagnosticMessage.maximumReportBytes else {
            incoming.removeValue(forKey: message.id)
            return Data()
        }
        transfer.data.append(message.payload)
        transfer.nextIndex += 1
        transfer.updatedAt = Date()
        if transfer.nextIndex == transfer.count {
            incoming.removeValue(forKey: message.id)
            return receive(transfer.data, phone: phone()) ? WatchDiagnosticMessage.saved : Data()
        }
        incoming[message.id] = transfer
        return WatchDiagnosticMessage.more
    }

    @discardableResult
    func savePhone(_ report: WatchDiagnosticReport) -> URL? {
        guard let data = report.encoded() else { return nil }
        let url = directory.appending(path: "phone-\(Int(report.capturedAt.timeIntervalSince1970))-\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            refresh()
            return url
        } catch { return nil }
    }

    func refresh() {
        reports = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? [])
            .filter { ($0.lastPathComponent.hasPrefix("watch-") || $0.lastPathComponent.hasPrefix("phone-")) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func capturedAt(for url: URL) -> Date? {
        guard reports.contains(url), let data = try? Data(contentsOf: url) else { return nil }
        return WatchDiagnosticReport.decode(data)?.capturedAt
    }

    func delete(_ url: URL) throws {
        guard reports.contains(url) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.removeItem(at: url)
        refresh()
    }
}

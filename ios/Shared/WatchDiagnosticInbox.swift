import Foundation
import Observation

@MainActor
@Observable
final class WatchDiagnosticInbox {
    private let directory: URL
    private(set) var reports: [URL] = []

    init(directory: URL = FileStore.defaultRootURL().appending(path: "watch-reports")) {
        self.directory = directory
        refresh()
    }

    @discardableResult
    func receive(_ data: Data, phone: WatchDiagnosticReport? = nil) -> Bool {
        guard data.count <= 256_000,
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

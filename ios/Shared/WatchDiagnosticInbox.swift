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
    func receive(_ data: Data) -> Bool {
        guard data.count <= 256_000,
              let report = WatchDiagnosticReport.decode(data), report.events.count <= 512,
              let cleanData = report.encoded() else { return false }
        let filename = "watch-\(Int(report.capturedAt.timeIntervalSince1970))-\(UUID().uuidString).json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try cleanData.write(to: directory.appending(path: filename), options: .atomic)
            refresh()
            return true
        } catch {
            return false
        }
    }

    func refresh() {
        reports = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("watch-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

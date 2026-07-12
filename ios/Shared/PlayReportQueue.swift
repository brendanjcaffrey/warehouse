import Foundation

/// queues plays on the watch until the connectivity session can take them;
/// every play is written to disk before hand-off so nothing is lost to a
/// relaunch or the phone being out of range. once handed off the system's
/// transfer queue owns delivery, so items are removed here right away &
/// reconciled against the outstanding transfers after a relaunch
@MainActor
final class PlayReportQueue {
    private(set) var pending: [PlayPayload]

    private let fileURL: URL
    private let canSend: @MainActor () -> Bool
    private let outstandingIds: @MainActor () -> Set<String>
    private let send: @MainActor (PlayPayload) -> Void

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "plays.json")
    }

    init(
        fileURL: URL = PlayReportQueue.defaultFileURL(),
        canSend: @escaping @MainActor () -> Bool,
        outstandingIds: @escaping @MainActor () -> Set<String>,
        send: @escaping @MainActor (PlayPayload) -> Void
    ) {
        self.fileURL = fileURL
        self.canSend = canSend
        self.outstandingIds = outstandingIds
        self.send = send
        pending = Self.load(from: fileURL)
    }

    /// records a play & hands it off right away when the session is up; the
    /// play is persisted first so a crash can't drop it
    func add(trackId: String) {
        pending.append(PlayPayload(trackId: trackId))
        persist()
        drain()
    }

    /// hands every pending play to the session in order; skips ones the
    /// system already took so a crash between hand-off & persist can't
    /// double-count
    func drain() {
        guard canSend() else { return }
        let outstanding = outstandingIds()
        while let payload = pending.first {
            if !outstanding.contains(payload.id) {
                send(payload)
            }
            pending.removeFirst()
            persist()
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
        } catch {
            // the plays are still in memory & the next mutation retries the write
        }
    }

    private static func load(from fileURL: URL) -> [PlayPayload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PlayPayload].self, from: data)) ?? []
    }
}

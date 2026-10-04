import Foundation

/// retains plays until the phone acknowledges durable ownership; system enqueue
/// and transfer completion alone do not establish that the phone saved a play.
@MainActor
final class PlayReportQueue {
    private(set) var pending: [PlayPayload]

    private let fileURL: URL
    private let canSend: @MainActor () -> Bool
    private let outstandingIds: @MainActor () -> Set<String>
    private let send: @MainActor (PlayPayload) -> Void
    private let write: (Data, URL) throws -> Void
    private let retryInterval: TimeInterval
    private var retryTask: Task<Void, Never>?

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "plays.json")
    }

    init(
        fileURL: URL = PlayReportQueue.defaultFileURL(),
        canSend: @escaping @MainActor () -> Bool,
        outstandingIds: @escaping @MainActor () -> Set<String>,
        send: @escaping @MainActor (PlayPayload) -> Void,
        retryInterval: TimeInterval = 60,
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.fileURL = fileURL
        self.canSend = canSend
        self.outstandingIds = outstandingIds
        self.send = send
        self.retryInterval = retryInterval
        self.write = write
        pending = Self.load(from: fileURL)
    }

    func add(trackId: String) {
        pending.append(PlayPayload(trackId: trackId))
        drain()
    }

    /// persist before enqueue, retaining the same ids through every retry.
    func drain() {
        retryTask?.cancel()
        retryTask = nil
        defer { scheduleRetry() }
        guard persist(), canSend() else { return }
        let outstanding = outstandingIds()
        for payload in pending where !outstanding.contains(payload.id) {
            send(payload)
        }
    }

    func acknowledge(_ payload: PlayPayload) {
        let previous = pending
        pending.removeAll { $0 == payload }
        if !persist() { pending = previous }
        if pending.isEmpty {
            retryTask?.cancel()
            retryTask = nil
        } else {
            scheduleRetry()
        }
    }

    /// terminal errors and successful transfers both still need a phone receipt.
    func finished(_ payload: PlayPayload) {
        guard pending.contains(payload) else { return }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTask == nil, !pending.isEmpty else { return }
        retryTask = Task { [weak self, retryInterval] in
            try? await Task.sleep(for: .seconds(retryInterval))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.drain()
        }
    }

    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(pending), fileURL)
            return true
        } catch {
            // retain in memory and retry persistence before transferring ownership.
            return false
        }
    }

    private static func load(from fileURL: URL) -> [PlayPayload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PlayPayload].self, from: data)) ?? []
    }
}

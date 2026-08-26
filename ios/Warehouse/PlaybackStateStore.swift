import Foundation

/// keeps the last known now playing state on disk so it survives the app being
/// jettisoned in the background. cheap to write whole every time it changes:
/// the queue is stored as a list of track ids, not as the tracks themselves
struct PlaybackStateStore: Sendable {
    let fileURL: URL

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "playback.json")
    }

    // the file parameter is here for tests
    init(fileURL: URL = PlaybackStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() -> PlaybackSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PlaybackSnapshot.self, from: data)
    }

    /// writes the state, or clears it when there is nothing playing to come
    /// back to; a stale queue would otherwise outlive the one it came from
    func save(_ snapshot: PlaybackSnapshot?) {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // the state is still in memory & the next change writes it again
        }
    }
}

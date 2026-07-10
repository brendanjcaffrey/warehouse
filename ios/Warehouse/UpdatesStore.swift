import Foundation
import Observation

/// queues plays (& later edits) and pushes them to the server, the ios port
/// of the web app's update persister; every update is written to disk before
/// it's attempted so nothing is ever lost to a failed request or the app
/// dying in the background
@MainActor
@Observable
final class UpdatesStore {
    private(set) var pending = [PendingUpdate]()

    private let client: UpdateClient
    private let fileURL: URL
    private let metadata: LibraryMetadata
    private let retryInterval: TimeInterval
    private var token: String?
    private var baseURL: URL?
    private var flushing = false
    private var retryTask: Task<Void, Never>?

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "updates.json")
    }

    // the file, session, defaults & interval parameters are here for tests
    init(
        fileURL: URL = UpdatesStore.defaultFileURL(),
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        retryInterval: TimeInterval = 30,
        fileStore: FileStore = FileStore(rootURL: FileStore.defaultRootURL())
    ) {
        client = UpdateClient(session: session, fileStore: fileStore)
        self.fileURL = fileURL
        metadata = LibraryMetadata(defaults: defaults)
        self.retryInterval = retryInterval
        pending = Self.load(from: fileURL)
    }

    /// remembers where to send updates; call flush afterwards to push
    /// anything queued from a previous launch
    func configure(token: String?, baseURL: URL?) {
        self.token = token
        self.baseURL = baseURL
    }

    /// records a play for the track and tries to push it right away; the
    /// update is persisted first so a failure can't drop it
    func addPlay(trackId: String) async {
        add(PendingUpdate(kind: .play, trackId: trackId))
        await flush()
    }

    /// records edited track fields & tries to push them right away
    func addTrackUpdate(trackId: String, update: TrackUpdate) async {
        add(PendingUpdate(kind: .track, trackId: trackId, trackUpdate: update))
        await flush()
    }

    /// queues an artwork upload; must be queued before the track update that
    /// references the filename so the server has the file when it's set
    func addArtworkUpload(filename: String) async {
        let update = PendingUpdate(kind: .artworkUpload, trackId: "", params: ["filename": filename])
        // the same file may back multiple edits, one upload covers them all
        guard !pending.contains(update) else { return }
        add(update)
        await flush()
    }

    /// artwork files still waiting to upload, protected from sync cleanup
    var pendingArtworkFilenames: Set<String> {
        Set(pending.compactMap { $0.kind == .artworkUpload ? $0.params["filename"] : nil })
    }

    /// whether edits are worth offering; unknown before the first sync, so
    /// optimistically true until the server says it isn't tracking changes
    var canEditTracks: Bool {
        metadata.updateTimeNs == 0 || metadata.trackUserChanges
    }

    /// pushes every pending update to the server in order, keeping the ones
    /// that fail queued for the retry timer
    func flush() async {
        retryTask?.cancel()
        retryTask = nil
        defer { scheduleRetry() }

        guard !flushing, let token, let baseURL, !pending.isEmpty else { return }
        // before the first sync there's no way to know whether the server
        // wants user changes, so hold everything until then
        guard metadata.updateTimeNs != 0 else { return }
        guard metadata.trackUserChanges else {
            pending = []
            persist()
            return
        }

        flushing = true
        defer { flushing = false }
        var index = 0
        while index < pending.count {
            do {
                try await client.send(pending[index], token: token, baseURL: baseURL)
                pending.remove(at: index)
            } catch UpdateClient.UpdateError.missingFile {
                // the file is gone from disk so this can never succeed
                pending.remove(at: index)
            } catch {
                // keep the update & move on so one failure can't block the rest
                index += 1
            }
            persist()
        }
    }

    private func add(_ update: PendingUpdate) {
        // when the server isn't tracking user changes there's no reason to
        // queue; before the first sync we can't know, so queue to be safe
        if metadata.updateTimeNs != 0 && !metadata.trackUserChanges { return }
        pending.append(update)
        persist()
    }

    private func scheduleRetry() {
        guard retryTask == nil, !pending.isEmpty, token != nil else { return }
        retryTask = Task { [weak self, retryInterval] in
            try? await Task.sleep(for: .seconds(retryInterval))
            guard !Task.isCancelled, let self else { return }
            // clear the handle first: flush cancels retryTask, & cancelling
            // this task from within would abort its own requests
            self.retryTask = nil
            await self.flush()
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
        } catch {
            // the updates are still in memory & the next mutation retries the write
        }
    }

    private static func load(from fileURL: URL) -> [PendingUpdate] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PendingUpdate].self, from: data)) ?? []
    }
}

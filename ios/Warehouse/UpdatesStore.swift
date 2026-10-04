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

    private struct State: Codable {
        var pending: [PendingUpdate]
        var watchPlays: [String: PlayPayload]

        enum CodingKeys: String, CodingKey { case pending, watchPlays }

        init(pending: [PendingUpdate], watchPlays: [String: PlayPayload]) {
            self.pending = pending
            self.watchPlays = watchPlays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pending = try container.decode([PendingUpdate].self, forKey: .pending)
            if let owned = try? container.decode([String: PlayPayload].self, forKey: .watchPlays) {
                watchPlays = owned
            } else {
                let legacy = try container.decode([String: String].self, forKey: .watchPlays)
                watchPlays = [:]
                for (id, trackId) in legacy { watchPlays[id] = PlayPayload(id: id, trackId: trackId) }
            }
        }
    }

    private var watchPlays = [String: PlayPayload]()
    private let write: (Data, URL) throws -> Void
    private let client: UpdateClient
    private let fileURL: URL
    private let metadata: LibraryMetadata
    private let retryInterval: TimeInterval
    private var token: String?
    private var baseURL: URL?
    private var libraryID: String? { LibraryIdentity.make(token: token, baseURL: baseURL) }
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
        fileStore: FileStore = FileStore(rootURL: FileStore.defaultRootURL()),
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        client = UpdateClient(session: session, fileStore: fileStore)
        self.fileURL = fileURL
        metadata = LibraryMetadata(defaults: defaults)
        self.retryInterval = retryInterval
        self.write = write
        let state = Self.load(from: fileURL)
        pending = state.pending
        watchPlays = state.watchPlays
    }

    /// remembers where to send updates; call flush afterwards to push
    /// anything queued from a previous launch
    func configure(token: String?, baseURL: URL?) {
        let previousIdentity = libraryID
        self.token = token
        self.baseURL = baseURL
        if previousIdentity != libraryID {
            retryTask?.cancel()
            retryTask = nil
        }
        scheduleRetry()
    }

    /// records a play for the track and tries to push it right away; the
    /// update is persisted first so a failure can't drop it
    func addPlay(trackId: String, libraryID: String?) async {
        add(PendingUpdate(kind: .play, trackId: trackId, libraryID: libraryID))
        await flush()
    }

    /// ownership transfers only after the event id and update share an atomic save.
    func recordWatchPlay(_ play: PlayPayload) throws {
        if let owned = watchPlays[play.id] {
            guard owned == play else { throw CocoaError(.coderInvalidValue) }
            return
        }
        let previous = pending
        watchPlays[play.id] = play
        // tracking policy belongs to the active library, not an old watch report.
        pending.append(PendingUpdate(kind: .play, trackId: play.trackId, libraryID: play.libraryID))
        do {
            try save()
        } catch {
            pending = previous
            watchPlays.removeValue(forKey: play.id)
            throw error
        }
    }

    /// records edited track fields & tries to push them right away
    func addTrackUpdate(trackId: String, update: TrackUpdate, libraryID: String?) async {
        add(PendingUpdate(kind: .track, trackId: trackId, trackUpdate: update, libraryID: libraryID))
        await flush()
    }

    /// queues an artwork upload; must be queued before the track update that
    /// references the filename so the server has the file when it's set
    func addArtworkUpload(filename: String, libraryID: String?) async {
        let update = PendingUpdate(kind: .artworkUpload, trackId: "", params: ["filename": filename], libraryID: libraryID)
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

        guard persist(), !flushing, libraryID != nil, !pending.isEmpty else { return }
        // before the first sync there's no way to know whether the server
        // wants user changes, so hold everything until then
        guard metadata.updateTimeNs != 0, metadata.libraryID == libraryID else { return }
        flushing = true
        defer { flushing = false }
        var index = 0
        while index < pending.count {
            // recheck after every await: configuration may change during a request.
            let update = pending[index]
            guard let identity = libraryID, metadata.libraryID == identity, let token, let baseURL else { break }
            guard update.libraryID == identity else { index += 1; continue }
            if !metadata.trackUserChanges {
                pending.remove(at: index)
                persist()
                continue
            }
            do {
                try await client.send(update, token: token, baseURL: baseURL)
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
        if update.libraryID != nil && update.libraryID == libraryID,
           metadata.libraryID == libraryID,
           metadata.updateTimeNs != 0 && !metadata.trackUserChanges { return }
        pending.append(update)
        persist()
    }

    private func scheduleRetry() {
        guard retryTask == nil, let identity = libraryID, metadata.libraryID == identity,
              pending.contains(where: { $0.libraryID == identity }) else { return }
        retryTask = Task { [weak self, retryInterval] in
            try? await Task.sleep(for: .seconds(retryInterval))
            guard !Task.isCancelled, let self else { return }
            // clear the handle first: flush cancels retryTask, & cancelling
            // this task from within would abort its own requests
            self.retryTask = nil
            await self.flush()
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try save()
            return true
        } catch {
            // do not send new updates until their durable state can be saved.
            return false
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(State(pending: pending, watchPlays: watchPlays)), fileURL)
    }

    private static func load(from fileURL: URL) -> State {
        guard let data = try? Data(contentsOf: fileURL) else { return State(pending: [], watchPlays: [:]) }
        if let state = try? JSONDecoder().decode(State.self, from: data) { return state }
        // older phone installs persisted just the pending array.
        let pending = (try? JSONDecoder().decode([PendingUpdate].self, from: data)) ?? []
        return State(pending: pending, watchPlays: [:])
    }
}

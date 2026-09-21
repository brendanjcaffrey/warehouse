import Foundation
import Observation

/// persisted playlist intent owns preparation independently of any playback queue
@MainActor
@Observable
final class OfflineLibrary {
    enum State: Equatable {
        case notSelected, queued, waitingForPhone, downloading, paused, failed, storageFull, ready
    }

    struct Progress: Equatable {
        let completed: Int
        let total: Int
        let state: State
    }

    private struct Selection: Codable {
        var name: String
        var trackIds: [String]
        var filenames: [String: String]
        var paused = false
    }

    private struct Job {
        let id: UUID
        let filename: String
        let task: Task<Void, Never>
    }

    private var selections: [String: Selection] = [:]
    private var durableSelections: [String: Selection] = [:]
    private var downloaded: Set<String>
    private var failures: [String: State] = [:]
    private var phase: State = .queued
    private var persistenceFailed = false
    private var foreground = false
    private var demand: [String] = []
    private var job: Job?
    private var token: String?
    private var baseURL: URL?
    private let fileCache: FileCache
    private let downloader: SingleFileDownloading
    private let availableBytes: @MainActor () -> Int64?
    private var fileStore: FileStore { fileCache.fileStore }
    private var manifestURL: URL { fileStore.rootURL.appending(path: "offline-playlists.json") }

    init(
        fileCache: FileCache, downloader: SingleFileDownloading,
        availableBytes: @escaping @MainActor () -> Int64? = { FileStore.deviceStorage()?.availableBytes }
    ) {
        self.fileCache = fileCache
        self.downloader = downloader
        self.availableBytes = availableBytes
        downloaded = fileCache.fileStore.list(.music)
        if let data = try? Data(contentsOf: manifestURL) {
            do {
                selections = try JSONDecoder().decode([String: Selection].self, from: data)
            } catch {
                persistenceFailed = true
            }
        }
        durableSelections = selections
        updateRetention()
    }

    var selectedPlaylistIds: [String] { selections.keys.sorted() }
    var errorMessage: String? { persistenceFailed ? "Couldn't save offline selections. Try again." : nil }

    func name(_ id: String) -> String { selections[id]?.name ?? id }
    func isSelected(_ id: String) -> Bool { selections[id] != nil }

    func progress(_ id: String) -> Progress {
        guard let selection = selections[id] else { return Progress(completed: 0, total: 0, state: .notSelected) }
        let completed = selection.trackIds.filter { track in
            selection.filenames[track].map { downloaded.contains($0) } ?? false
        }.count
        let state: State
        if persistenceFailed {
            state = .failed
        } else if completed == selection.trackIds.count, completed > 0 {
            state = .ready
        } else if selection.paused {
            state = .paused
        } else if failures.values.contains(.storageFull) {
            state = .storageFull
        } else if let failure = selection.filenames.values.compactMap({ failures[$0] }).first {
            state = failure
        } else if let job, selection.filenames.values.contains(job.filename) {
            state = phase
        } else if selection.filenames.count < selection.trackIds.count {
            state = .failed
        } else {
            state = foreground ? .queued : .paused
        }
        return Progress(completed: completed, total: selection.trackIds.count, state: state)
    }

    func prepare(_ playlist: PlaylistItem, songs: [Song]) {
        guard !playlist.isFolder else { return }
        selections[playlist.id] = selection(for: playlist, songs: songs)
        if let selection = selections[playlist.id] {
            for filename in selection.filenames.values { failures[filename] = nil }
        }
        saveAndReconcile()
    }

    func pause(_ id: String) {
        selections[id]?.paused = true
        saveAndReconcile()
    }

    func resume(_ id: String) {
        selections[id]?.paused = false
        if let selection = selections[id] {
            for filename in selection.filenames.values { failures[filename] = nil }
        }
        saveAndReconcile()
    }

    /// cancel releases retention but leaves completed files as ordinary cache
    func cancel(_ id: String) {
        selections[id] = nil
        saveAndReconcile()
    }

    /// remove also deletes completed files unless another selection or playback needs them
    func remove(_ id: String) {
        let filenames = Set(selections[id]?.filenames.values ?? [:].values)
        cancel(id)
        guard !persistenceFailed else { return }
        for filename in filenames.subtracting(retained) where !fileCache.isMusicInUse(filename) {
            try? fileStore.delete(.music, filename)
        }
        refreshFiles()
        fileCache.noteMusicStored()
    }

    /// absent playlists keep their saved membership until explicitly removed
    func reconcile(playlists: [PlaylistItem], songs: [Song]) {
        for playlist in playlists where selections[playlist.id] != nil {
            var updated = selection(for: playlist, songs: songs)
            updated.paused = selections[playlist.id]?.paused ?? false
            selections[playlist.id] = updated
        }
        saveAndReconcile()
    }

    func refreshFiles() {
        downloaded = fileStore.list(.music)
    }

    func setCredentials(token: String?, baseURL: URL?) {
        guard self.token != token || self.baseURL != baseURL else { return }
        cancelJob()
        self.token = token
        self.baseURL = baseURL
        failures = [:]
        schedule()
    }

    func setForeground(_ foreground: Bool) {
        if foreground, !self.foreground {
            failures = failures.filter { $0.value != .failed }
        }
        self.foreground = foreground
        if !foreground { cancelJob() }
        refreshFiles()
        schedule()
    }

    /// opportunistic demand can change without cancelling a selected playlist's job
    func setPlaybackDemand(_ filenames: [String]) {
        guard demand != filenames else { return }
        for filename in Set(filenames).subtracting(demand) where failures[filename] == .failed {
            failures[filename] = nil
        }
        demand = filenames
        reconcileJob()
        schedule()
    }

    private var retained: Set<String> { Set(selections.values.flatMap { $0.filenames.values }) }
    private var desired: [String] {
        selections.keys.sorted().flatMap { id -> [String] in
            guard let selection = selections[id], !selection.paused else { return [] }
            return selection.trackIds.compactMap { selection.filenames[$0] }
        }
    }

    private func selection(for playlist: PlaylistItem, songs: [Song]) -> Selection {
        let members = SongListBuilder.playlistSongs(songs, trackIds: playlist.trackIds)
        var seen = Set<String>()
        return Selection(
            name: playlist.name, trackIds: playlist.trackIds.filter { seen.insert($0).inserted },
            filenames: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.musicFilename) }))
    }

    private func updateRetention() {
        fileCache.retainMusic(retained)
    }

    private func saveAndReconcile() {
        do {
            try FileManager.default.createDirectory(at: fileStore.rootURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(selections).write(to: manifestURL, options: .atomic)
            durableSelections = selections
            persistenceFailed = false
        } catch {
            selections = durableSelections
            persistenceFailed = true
        }
        updateRetention()
        refreshFiles()
        let wanted = Set(desired + demand)
        failures = failures.filter { wanted.contains($0.key) }
        reconcileJob()
        schedule()
    }

    private func reconcileJob() {
        if let job, !(desired + demand).contains(job.filename) || persistenceFailed { cancelJob() }
    }

    private func cancelJob() {
        job?.task.cancel()
        job = nil
    }

    private func schedule() {
        guard job == nil, foreground, !persistenceFailed, let token, let baseURL else { return }
        guard !failures.values.contains(.storageFull) else { return }
        let candidates = Array(demand.prefix(1)) + desired + demand.dropFirst()
        guard let filename = candidates.first(where: { !downloaded.contains($0) && failures[$0] == nil }) else { return }
        let selected = retained.contains(filename)
        // deep opportunistic filling stops at the budget instead of evicting its own work
        guard selected || filename == demand.first || fileCache.musicRoom() > 0 else { return }
        guard !selected || fileCache.makeMusicRoom(), let available = availableBytes(), available > 32_000_000 else {
            failures[filename] = .storageFull
            return
        }
        let id = UUID()
        phase = .downloading
        let task = Task { @MainActor [weak self, downloader] in
            let result = await downloader.downloadResult(.music, filename: filename, token: token, baseURL: baseURL) { [weak self] phase in
                guard self?.job?.id == id else { return }
                self?.phase = phase == .waitingForPhone ? .waitingForPhone : .downloading
            }
            guard let self, self.job?.id == id, !Task.isCancelled else { return }
            self.job = nil
            self.finish(filename, result: result)
            self.schedule()
        }
        job = Job(id: id, filename: filename, task: task)
    }

    private func finish(_ filename: String, result: FileDownloadResult) {
        switch result {
        case .downloaded:
            let selected = retained.contains(filename)
            if selected || filename == demand.first { fileCache.evict() }
            if selected, fileCache.musicRoom() < 0, !fileCache.isMusicInUse(filename) {
                try? fileStore.delete(.music, filename)
                failures[filename] = .storageFull
            } else if !fileStore.exists(.music, filename) {
                failures[filename] = .failed
            }
        case .failed:
            failures[filename] = .failed
        case .outOfSpace:
            failures[filename] = .storageFull
        }
        refreshFiles()
        fileCache.noteMusicStored()
    }
}

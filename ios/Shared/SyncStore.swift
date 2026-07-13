import Foundation
import Observation

@MainActor
@Observable
final class SyncStore {
    enum State: Equatable {
        case idle
        case checkingForUpdates
        case updateAvailable(newLibraryData: Bool, missingFiles: Int)
        case fetchingLibrary
        case savingLibrary
        case downloadingFiles(DownloadProgress)
        case upToDate(failedDownloads: Int)
        case storageFull
        case error(String)
    }

    private enum LibraryStatus {
        case needsUpdate
        case haveLatestVersion
        case offline
    }

    private enum SyncError: LocalizedError {
        case server(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .server(let message):
                return message
            case .emptyResponse:
                return "The server returned an empty response."
            }
        }
    }

    private(set) var state: State = .idle
    /// artwork filenames to keep even when no track references them, e.g.
    /// files still waiting in the update queue to be uploaded
    var protectedArtworkFilenames: () -> Set<String> = { [] }
    /// lets the watch trim the fetched library to just its synced playlists
    /// before anything is saved or downloaded
    var libraryFilter: (Library) -> Library = { $0 }
    /// bumped when a sync attempt finishes, so views can reload without
    /// observing every per-file progress update in `state`
    private(set) var completedSyncs = 0
    /// bumped at most once per refresh interval while files download, so the
    /// songs list can update its downloaded icons during long syncs
    private(set) var downloadRefreshTicks = 0

    private let client: LibraryClient
    /// where version & library data comes from; the watch injects a relay
    /// that asks the phone instead of the server
    private let libraryProvider: LibraryProviding
    private let database: LibraryDatabase
    private let fileStore: FileStore
    private let metadata: LibraryMetadata
    private let downloadRefreshInterval: TimeInterval
    /// how missing files are fetched; the watch injects a background-session
    /// downloader so transfers survive the app being suspended
    private let fileDownloader: BulkFileDownloading
    private var lastDownloadRefresh = Date.distantPast
    private var syncInProgress = false

    // the session, defaults, interval & downloader parameters are here for tests
    init(
        database: LibraryDatabase,
        fileStore: FileStore,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        downloadRefreshInterval: TimeInterval = 5,
        fileDownloader: BulkFileDownloading? = nil,
        libraryProvider: LibraryProviding? = nil
    ) {
        client = LibraryClient(session: session)
        self.libraryProvider = libraryProvider ?? client
        self.database = database
        self.fileStore = fileStore
        metadata = LibraryMetadata(defaults: defaults)
        self.downloadRefreshInterval = downloadRefreshInterval
        self.fileDownloader = fileDownloader ?? FileDownloader(client: client, fileStore: fileStore)
    }

    var isBusy: Bool {
        switch state {
        case .checkingForUpdates, .fetchingLibrary, .savingLibrary, .downloadingFiles:
            return true
        case .idle, .updateAvailable, .upToDate, .storageFull, .error:
            return false
        }
    }

    /// true only while actually moving library data or files, not for the quick
    /// version check, so a no-op sync doesn't flash the full-screen progress view
    var isTransferringLibrary: Bool {
        switch state {
        case .fetchingLibrary, .savingLibrary, .downloadingFiles:
            return true
        case .idle, .checkingForUpdates, .updateAvailable, .upToDate, .storageFull, .error:
            return false
        }
    }

    /// counts & sizes of the downloaded files; safe to call off the main actor
    nonisolated func downloadStats() -> DownloadStats {
        fileStore.downloadStats()
    }

    /// checks whether there's new library data or missing files, without syncing anything
    func checkForUpdates(token: String?, baseURL: URL?) async {
        guard let token, let baseURL, !syncInProgress else { return }
        syncInProgress = true
        defer { syncInProgress = false }

        state = .checkingForUpdates
        do {
            switch try await fetchLibraryStatus(token: token, baseURL: baseURL) {
            case .offline:
                state = .upToDate(failedDownloads: 0)
            case .needsUpdate:
                state = .updateAvailable(newLibraryData: true, missingFiles: 0)
            case .haveLatestVersion:
                let missing = try await missingFiles()
                state = missing.isEmpty
                    ? .upToDate(failedDownloads: 0)
                    : .updateAvailable(newLibraryData: false, missingFiles: missing.count)
            }
        } catch let error as URLError where error.isOfflineError {
            state = .upToDate(failedDownloads: 0)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// checks for new library data, replaces the local database if there is any,
    /// then downloads all missing music & artwork files
    func sync(token: String?, baseURL: URL?) async {
        guard let token, let baseURL, !syncInProgress else { return }
        syncInProgress = true
        defer {
            syncInProgress = false
            completedSyncs += 1
        }

        do {
            state = .checkingForUpdates
            switch try await fetchLibraryStatus(token: token, baseURL: baseURL) {
            case .offline:
                // if we're offline, use whatever we already have
                state = .upToDate(failedDownloads: 0)
                return
            case .haveLatestVersion:
                break
            case .needsUpdate:
                state = .fetchingLibrary
                let library = libraryFilter(try await fetchLibrary(token: token, baseURL: baseURL))
                state = .savingLibrary
                try await database.replaceLibrary(with: library)
                metadata.update(from: library)
            }

            let progress = try await syncFiles(token: token, baseURL: baseURL)
            state = progress.outOfSpace
                ? .storageFull
                : .upToDate(failedDownloads: progress.failed)
        } catch let error as URLError where error.isOfflineError {
            state = .upToDate(failedDownloads: 0)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func fetchLibraryStatus(token: String, baseURL: URL) async throws -> LibraryStatus {
        // nothing synced yet, no point checking the version
        if metadata.updateTimeNs == 0 {
            return .needsUpdate
        }

        do {
            switch try await libraryProvider.fetchVersion(token: token, baseURL: baseURL) {
            case .updateTimeNs(let updateTimeNs):
                return updateTimeNs == metadata.updateTimeNs ? .haveLatestVersion : .needsUpdate
            case .error(let message):
                throw SyncError.server(message)
            case .empty:
                throw SyncError.emptyResponse
            }
        } catch let error as URLError where error.isOfflineError {
            return .offline
        }
    }

    private func fetchLibrary(token: String, baseURL: URL) async throws -> Library {
        switch try await libraryProvider.fetchLibrary(token: token, baseURL: baseURL) {
        case .library(let library):
            return library
        case .error(let message):
            throw SyncError.server(message)
        case .empty:
            throw SyncError.emptyResponse
        }
    }

    private func missingFiles() async throws -> [FileToDownload] {
        let musicFilenames = try await database.musicFilenames()
        let artworkFilenames = try await database.artworkFilenames()
        return Self.missing(music: musicFilenames, artwork: artworkFilenames, fileStore: fileStore)
    }

    // also used by the watch's background refresh to nudge the phone relay
    static func missing(music: Set<String>, artwork: Set<String>, fileStore: FileStore) -> [FileToDownload] {
        let missingMusic = music.subtracting(fileStore.list(.music)).sorted()
        let missingArtwork = artwork.subtracting(fileStore.list(.artwork)).sorted()
        return missingMusic.map { FileToDownload(type: .music, filename: $0) }
            + missingArtwork.map { FileToDownload(type: .artwork, filename: $0) }
    }

    /// deletes files no longer referenced by any track, then downloads all missing ones
    private func syncFiles(token: String, baseURL: URL) async throws -> DownloadProgress {
        try fileStore.prepare()
        let musicFilenames = try await database.musicFilenames()
        let artworkFilenames = try await database.artworkFilenames()
        fileStore.deleteFiles(.music, keeping: musicFilenames)
        fileStore.deleteFiles(.artwork, keeping: artworkFilenames.union(protectedArtworkFilenames()))

        let missing = Self.missing(music: musicFilenames, artwork: artworkFilenames, fileStore: fileStore)
        guard !missing.isEmpty else { return DownloadProgress() }

        state = .downloadingFiles(DownloadProgress(files: missing))
        lastDownloadRefresh = Date()
        return await fileDownloader.downloadAll(missing, token: token, baseURL: baseURL) { [weak self] progress in
            self?.state = .downloadingFiles(progress)
            self?.tickDownloadRefreshIfDue()
        }
    }

    private func tickDownloadRefreshIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastDownloadRefresh) >= downloadRefreshInterval else { return }
        lastDownloadRefresh = now
        downloadRefreshTicks += 1
    }
}

import Foundation

struct FileToDownload: Hashable, Codable, Sendable {
    let type: LibraryFileType
    let filename: String
}

struct DownloadProgress: Equatable, Sendable {
    /// one file type's slice of the progress, so the ui can report music and
    /// artwork separately
    struct Counts: Equatable, Sendable {
        var completed = 0
        var failed = 0
        var total = 0

        var finished: Int { completed + failed }
    }

    var music = Counts()
    var artwork = Counts()
    /// downloading stopped early because the device has no room left
    var outOfSpace = false

    init() {}

    /// starts with the per-type totals of everything the sync will download
    init(files: [FileToDownload]) {
        music.total = files.filter { $0.type == .music }.count
        artwork.total = files.filter { $0.type == .artwork }.count
    }

    subscript(type: LibraryFileType) -> Counts {
        get {
            switch type {
            case .music: return music
            case .artwork: return artwork
            }
        }
        set {
            switch type {
            case .music: music = newValue
            case .artwork: artwork = newValue
            }
        }
    }

    var completed: Int { music.completed + artwork.completed }
    var failed: Int { music.failed + artwork.failed }
    var total: Int { music.total + artwork.total }
    var finished: Int { completed + failed }

    var fraction: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }
}

/// downloads files one at a time, music before artwork, skipping over failures
/// so one bad file can't block the rest of the library
struct FileDownloader: BulkFileDownloading, Sendable {
    let client: LibraryClient
    let fileStore: FileStore

    private enum FetchOutcome {
        case downloaded
        case failed
        case outOfSpace
    }

    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        var progress = DownloadProgress(files: files)
        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                break
            }
            switch await fetch(file.type, filename: file.filename, token: token, baseURL: baseURL) {
            case .downloaded:
                progress[file.type].completed += 1
            case .failed:
                progress[file.type].failed += 1
            case .outOfSpace:
                // everything after this would fail the same way, so stop here
                // and count this file & the rest as failed
                progress.outOfSpace = true
                for remaining in files[index...] {
                    progress[remaining.type].failed += 1
                }
            }
            let current = progress
            await onProgress(current)
            if progress.outOfSpace {
                break
            }
        }
        return progress
    }

    /// fetches a single file into the store, returning whether it succeeded;
    /// skips the fetch when the file is already on disk so a sync and an
    /// on-demand play don't download the same file twice
    func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
        await fetch(type, filename: filename, token: token, baseURL: baseURL) == .downloaded
    }

    private func fetch(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> FetchOutcome {
        if fileStore.exists(type, filename) { return .downloaded }
        do {
            let data = try await client.fetchFile(type, filename: filename, token: token, baseURL: baseURL)
            try fileStore.write(type, filename, data: data)
            return .downloaded
        } catch {
            return BackgroundDownload.isOutOfSpace(error) ? .outOfSpace : .failed
        }
    }
}

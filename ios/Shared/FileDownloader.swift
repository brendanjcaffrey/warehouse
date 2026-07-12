import Foundation

struct FileToDownload: Hashable, Sendable {
    let type: LibraryFileType
    let filename: String
}

struct DownloadProgress: Equatable, Sendable {
    var completed = 0
    var failed = 0
    var total = 0
    /// downloading stopped early because the device has no room left
    var outOfSpace = false

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
        var progress = DownloadProgress(total: files.count)
        for file in files {
            if Task.isCancelled {
                break
            }
            switch await fetch(file.type, filename: file.filename, token: token, baseURL: baseURL) {
            case .downloaded:
                progress.completed += 1
            case .failed:
                progress.failed += 1
            case .outOfSpace:
                // everything after this would fail the same way, so stop here
                // and count the rest as failed
                progress.outOfSpace = true
                progress.failed = files.count - progress.completed
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

import Foundation

struct FileToDownload: Equatable, Sendable {
    let type: LibraryFileType
    let filename: String
}

struct DownloadProgress: Equatable, Sendable {
    var completed = 0
    var failed = 0
    var total = 0

    var finished: Int { completed + failed }

    var fraction: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }
}

/// downloads files one at a time, music before artwork, skipping over failures
/// so one bad file can't block the rest of the library
struct FileDownloader: Sendable {
    let client: LibraryClient
    let fileStore: FileStore

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
            if await download(file.type, filename: file.filename, token: token, baseURL: baseURL) {
                progress.completed += 1
            } else {
                progress.failed += 1
            }
            let current = progress
            await onProgress(current)
        }
        return progress
    }

    /// fetches a single file into the store, returning whether it succeeded;
    /// skips the fetch when the file is already on disk so a sync and an
    /// on-demand play don't download the same file twice
    func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
        if fileStore.exists(type, filename) { return true }
        do {
            let data = try await client.fetchFile(type, filename: filename, token: token, baseURL: baseURL)
            try fileStore.write(type, filename, data: data)
            return true
        } catch {
            return false
        }
    }
}

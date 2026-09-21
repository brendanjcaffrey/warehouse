import Foundation

/// abstracts how the missing files get fetched. there's one real
/// implementation now that the watch fetches on demand, but SyncStore's tests
/// inject a stub through it to assert what a sync asks for
protocol BulkFileDownloading: Sendable {
    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress
}

/// abstracts fetching one file on demand. the watch's artwork fetcher takes it
/// this way so tests can hand back a downloader they finish by hand, instead
/// of racing whatever the mock url protocol gets around to serving
protocol SingleFileDownloading: Sendable {
    func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool
    func downloadResult(
        _ type: LibraryFileType, filename: String, token: String, baseURL: URL,
        onPhase: @escaping @MainActor @Sendable (FileDownloadPhase) -> Void
    ) async -> FileDownloadResult
}

enum FileDownloadResult: Sendable {
    case downloaded
    case failed
    case outOfSpace
}

enum FileDownloadPhase: Sendable {
    case waitingForPhone
    case downloading
}

extension SingleFileDownloading {
    func downloadResult(
        _ type: LibraryFileType, filename: String, token: String, baseURL: URL,
        onPhase: @escaping @MainActor @Sendable (FileDownloadPhase) -> Void
    ) async -> FileDownloadResult {
        await onPhase(.downloading)
        return await download(type, filename: filename, token: token, baseURL: baseURL) ? .downloaded : .failed
    }
}

enum BackgroundDownload {
    /// whether an error (or any of its underlying errors) means the device has
    /// run out of storage, so a sync can stop early and say why
    static func isOutOfSpace(_ error: Error?) -> Bool {
        var next = error
        while let current = next {
            let nsError = current as NSError
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)),
                 (NSURLErrorDomain, NSURLErrorCannotWriteToFile):
                return true
            default:
                next = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            }
        }
        return false
    }
}

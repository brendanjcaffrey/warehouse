import Foundation

/// abstracts how the missing files get fetched, so the watch can swap the
/// in-process downloader for one backed by a background url session that keeps
/// running while the app is suspended, instead of stalling every screen sleep
protocol BulkFileDownloading: Sendable {
    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress
}

/// pure helpers shared by the downloaders and their tests: when a failed
/// fetch is worth another try, whether a finished task returned a file worth
/// keeping, and whether an error means the device is out of storage
enum BackgroundDownload {
    /// identifies the watch's single background url session across relaunches
    static let sessionIdentifier = "com.jcaffrey.warehouse.watchkitapp.downloads"

    /// how many times one sync re-tries a request that failed
    static let retriesPerFile = 2

    /// whether a finished task's file is worth fetching again: it never landed
    /// on disk, it has retries left, and the failure isn't one a retry can't
    /// fix (out of storage, or the transfer was deliberately cancelled)
    static func shouldRetry(error: Error?, isOnDisk: Bool, retriesUsed: Int) -> Bool {
        guard !isOnDisk, retriesUsed < retriesPerFile, !isOutOfSpace(error) else { return false }
        if let error, (error as NSError).domain == NSURLErrorDomain,
           (error as NSError).code == NSURLErrorCancelled {
            return false
        }
        return true
    }

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

    /// mirrors LibraryClient.fetchFile: only a 200 that isn't the auth-failure
    /// html redirect is a real file, so we don't save an error page as music
    static func isAcceptable(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && http.mimeType != "text/html"
    }
}

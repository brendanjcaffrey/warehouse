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

/// pure helpers shared by the downloaders and their tests: what a sync should
/// enqueue vs adopt, how a download task remembers which file it is fetching,
/// whether a finished task returned a file worth keeping, and whether an error
/// means the device is out of storage
enum BackgroundDownload {
    /// identifies the watch's single background url session across relaunches
    static let sessionIdentifier = "com.jcaffrey.warehouse.watchkitapp.downloads"

    /// which transfers a sync should start and which already-running ones it
    /// should adopt and wait for, so a relaunch mid-download resumes the sync
    /// instead of either re-fetching files or declaring itself done early
    struct Plan: Equatable, Sendable {
        var toEnqueue: [FileToDownload] = []
        var adopted: Set<FileToDownload> = []

        /// every file the sync must wait on before it can be considered finished
        var outstanding: Set<FileToDownload> { adopted.union(toEnqueue) }
    }

    static func plan(
        files: [FileToDownload],
        inFlight: Set<FileToDownload>,
        isOnDisk: (FileToDownload) -> Bool
    ) -> Plan {
        let wanted = files.filter { !isOnDisk($0) }
        return Plan(
            toEnqueue: wanted.filter { !inFlight.contains($0) },
            adopted: inFlight.intersection(wanted))
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

    /// a human-readable label on each task, handy in the console; the identity
    /// used for saving comes from the request url instead, since the background
    /// daemon preserves that reliably where taskDescription can be lost
    static func taskDescription(for file: FileToDownload) -> String {
        "\(file.type.rawValue)/\(file.filename)"
    }

    /// the file a task is fetching, read back from its request url, whose last
    /// two path components are the type & filename (…/music/<name>)
    static func file(fromURL url: URL?) -> FileToDownload? {
        guard let url else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 2 else { return nil }
        let filename = parts[parts.count - 1]
        let rawType = parts[parts.count - 2]
        guard let type = LibraryFileType(rawValue: rawType), !filename.isEmpty else { return nil }
        return FileToDownload(type: type, filename: filename)
    }

    /// mirrors LibraryClient.fetchFile: only a 200 that isn't the auth-failure
    /// html redirect is a real file, so we don't save an error page as music
    static func isAcceptable(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && http.mimeType != "text/html"
    }
}

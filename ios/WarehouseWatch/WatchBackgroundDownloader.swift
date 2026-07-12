import Foundation
import WatchKit

/// fetches the watch's missing files on a background url session so transfers
/// keep running while the app is suspended, instead of stalling every time the
/// screen sleeps. progress is read back from what actually landed on disk, so
/// the count can't drift from reality and a relaunch mid-download just resumes
final class WatchBackgroundDownloader: NSObject, BulkFileDownloading, @unchecked Sendable {
    static let shared = WatchBackgroundDownloader(
        fileStore: FileStore(rootURL: FileStore.defaultRootURL()))

    private let fileStore: FileStore
    private let lock = NSLock()

    // everything below is guarded by `lock`
    private var onProgress: (@MainActor @Sendable (DownloadProgress) -> Void)?
    private var targets: [FileToDownload] = []
    private var pending = 0
    private var continuation: CheckedContinuation<DownloadProgress, Never>?
    private var cancelled = false
    private var eventsCompletion: (() -> Void)?

    init(fileStore: FileStore) {
        self.fileStore = fileStore
        super.init()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: BackgroundDownload.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        try? fileStore.prepare()

        // skip anything already on disk or still downloading from an earlier run
        let inFlight = await inFlightFiles()
        let toEnqueue = files.filter { !inFlight.contains($0) && !fileStore.exists($0.type, $0.filename) }

        lock.lock()
        cancelled = false
        lock.unlock()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                // if cancellation already fired, resume at once rather than
                // storing a continuation nothing will ever resume
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: progressSnapshot(for: files))
                    return
                }
                self.onProgress = onProgress
                self.targets = files
                self.pending = toEnqueue.count
                self.continuation = continuation
                lock.unlock()

                // start the transfers only after the state above is in place, so
                // a task that finishes immediately can't strand the continuation
                for file in toEnqueue {
                    let task = session.downloadTask(with: request(for: file, token: token, baseURL: baseURL))
                    task.taskDescription = BackgroundDownload.taskDescription(for: file)
                    task.resume()
                }

                // nothing new to fetch: settle with whatever's already on disk,
                // leaving any pre-existing in-flight transfers to finish on their own
                if toEnqueue.isEmpty {
                    resumeContinuationIfNeeded()
                }
            }
        } onCancel: {
            // the view drove the sync away; unwind the awaiting task but leave
            // the background transfers running so they still finish
            lock.lock()
            cancelled = true
            lock.unlock()
            resumeContinuationIfNeeded()
        }
    }

    /// re-establishes the session so watchos can deliver events that queued up
    /// while the app was suspended, then completes the refresh task once they
    /// have all been handed over
    func reconnect(sessionIdentifier: String, completion: @escaping () -> Void) {
        guard sessionIdentifier == BackgroundDownload.sessionIdentifier else {
            completion()
            return
        }
        lock.lock()
        eventsCompletion = completion
        lock.unlock()
        _ = session
    }

    private func request(for file: FileToDownload, token: String, baseURL: URL) -> URLRequest {
        let url = baseURL.appendingPathComponent(file.type.directory).appendingPathComponent(file.filename)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func inFlightFiles() async -> Set<FileToDownload> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(
                    tasks.compactMap { BackgroundDownload.file(fromURL: $0.originalRequest?.url) }))
            }
        }
    }

    /// how many of `files` have made it to disk, reported as live progress
    private func progressSnapshot(for files: [FileToDownload]) -> DownloadProgress {
        let done = files.filter { fileStore.exists($0.type, $0.filename) }.count
        return DownloadProgress(completed: done, failed: 0, total: files.count)
    }

    private func resumeContinuationIfNeeded() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let files = targets
        self.onProgress = nil
        lock.unlock()

        guard let continuation else { return }
        // whatever never landed on disk is a failed download
        let done = files.filter { fileStore.exists($0.type, $0.filename) }.count
        continuation.resume(returning: DownloadProgress(
            completed: done, failed: files.count - done, total: files.count))
    }
}

extension WatchBackgroundDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard BackgroundDownload.isAcceptable(downloadTask.response),
              let file = BackgroundDownload.file(fromURL: downloadTask.originalRequest?.url) else {
            return
        }
        // move the temp file into place synchronously, before it's cleaned up
        let destination = fileStore.fileURL(file.type, file.filename)
        try? FileManager.default.createDirectory(
            at: fileStore.directoryURL(file.type), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: location, to: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if pending > 0 { pending -= 1 }
        let files = targets
        let callback = onProgress
        let finished = pending <= 0
        lock.unlock()

        // count from disk so a task we couldn't map still can't stall the total
        let snapshot = progressSnapshot(for: files)
        if let callback {
            Task { @MainActor in callback(snapshot) }
        }
        if finished {
            resumeContinuationIfNeeded()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = eventsCompletion
        eventsCompletion = nil
        lock.unlock()
        completion?()
    }
}

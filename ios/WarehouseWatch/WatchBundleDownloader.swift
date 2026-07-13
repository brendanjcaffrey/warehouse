import Foundation
import WatchKit

/// fetches the watch's missing files as tar bundles on a background url
/// session, one request in flight at a time: register a bundle of missing
/// files with the server, download the tar it built, unpack it, repeat. every
/// hop is a single enqueue inside a background wake, so the chain keeps
/// advancing overnight while the app is suspended. progress is read back from
/// what actually landed on disk, so the count can't drift from reality
final class WatchBundleDownloader: NSObject, BulkFileDownloading, @unchecked Sendable {
    static let shared = WatchBundleDownloader(
        fileStore: FileStore(rootURL: FileStore.defaultRootURL()),
        stateURL: BundleSync.defaultStateURL())

    private let fileStore: FileStore
    private let stateURL: URL
    private let lock = NSLock()

    // everything below is guarded by `lock`
    private var activity: SyncActivityLog?
    /// reads credentials at request time, so a background wake can keep the
    /// chain moving without the ui running
    private var credentialsProvider: (@Sendable () -> (token: String, baseURL: URL)?)?
    private var syncState = BundleSync.State()
    private var onProgress: (@MainActor @Sendable (DownloadProgress) -> Void)?
    private var continuation: CheckedContinuation<DownloadProgress, Never>?
    private var cancelled = false
    private var outOfSpace = false
    private var eventsCompletion: (() -> Void)?
    /// registration response bytes, keyed by task identifier
    private var responseData: [Int: Data] = [:]
    /// upload body temp files to clean up, keyed by task identifier
    private var uploadBodies: [Int: URL] = [:]

    init(fileStore: FileStore, stateURL: URL) {
        self.fileStore = fileStore
        self.stateURL = stateURL
        super.init()
        syncState = BundleSync.loadState(from: stateURL) ?? BundleSync.State()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: BackgroundDownload.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// wires the activity feed & credential source once at app start
    func configure(
        activity: SyncActivityLog,
        credentials: @escaping @Sendable () -> (token: String, baseURL: URL)?
    ) {
        lock.lock()
        self.activity = activity
        credentialsProvider = credentials
        lock.unlock()
    }

    func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        try? fileStore.prepare()

        lock.lock()
        cancelled = false
        outOfSpace = false
        // a bundle registered on an earlier run is still worth downloading:
        // the server cached it, and anything it contains that's no longer
        // wanted gets cleaned up by the next sync's delete pass
        syncState = BundleSync.State(
            pendingFiles: files, pendingBundleId: syncState.pendingBundleId, retriesUsed: 0)
        BundleSync.save(syncState, to: stateURL)
        lock.unlock()

        note { $0.startedSync(total: files.count) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                // if cancellation already fired, resume at once rather than
                // storing a continuation nothing will ever resume
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: progressSnapshot(for: files, final: true))
                    return
                }
                self.onProgress = onProgress
                self.continuation = continuation
                lock.unlock()

                Task { @MainActor in WKExtension.shared().isFrontmostTimeoutExtended = true }

                // adopt a request still in flight from an earlier launch;
                // its delegate callbacks will drive the chain from there
                session.getAllTasks { [weak self] tasks in
                    guard let self else { return }
                    if tasks.isEmpty {
                        advance()
                    }
                }
            }
        } onCancel: {
            // the view drove the sync away; unwind the awaiting task but let
            // the chain keep advancing in the background
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

    /// the single next request in the chain, or the end of the sync
    private func advance() {
        lock.lock()
        let state = syncState
        let full = outOfSpace
        lock.unlock()

        guard !full, let credentials = credentialsProvider?() else {
            resumeContinuationIfNeeded()
            return
        }

        switch BundleSync.nextStep(state: state, isOnDisk: { fileStore.exists($0.type, $0.filename) }) {
        case .finished:
            resumeContinuationIfNeeded()
        case .register(let type, let filenames):
            register(type: type, filenames: filenames, credentials: credentials)
        case .download(let bundleId):
            download(bundleId: bundleId, credentials: credentials)
        }
    }

    /// asks the server to build a tar of the next chunk of missing files; an
    /// upload task so the request survives the app suspending mid-flight
    private func register(type: LibraryFileType, filenames: [String], credentials: (token: String, baseURL: URL)) {
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            let body = try BundleSync.registrationRequest(type: type, filenames: filenames)
            try body.write(to: bodyURL)
        } catch {
            note { $0.bundleFailed(reason: error.localizedDescription) }
            resumeContinuationIfNeeded()
            return
        }

        var request = URLRequest(url: credentials.baseURL.appendingPathComponent("api/bundle"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: bodyURL)
        lock.lock()
        uploadBodies[task.taskIdentifier] = bodyURL
        lock.unlock()
        note { $0.requestedBundle(type: type, count: filenames.count) }
        task.resume()
    }

    private func download(bundleId: String, credentials: (token: String, baseURL: URL)) {
        var request = URLRequest(url: credentials.baseURL
            .appendingPathComponent("bundle").appendingPathComponent(bundleId))
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        session.downloadTask(with: request).resume()
    }

    /// how many of `files` have made it to disk; a final snapshot counts
    /// whatever never landed as failed
    private func progressSnapshot(for files: [FileToDownload], final: Bool) -> DownloadProgress {
        lock.lock()
        let full = outOfSpace
        lock.unlock()
        var progress = DownloadProgress(files: files)
        for file in files where fileStore.exists(file.type, file.filename) {
            progress[file.type].completed += 1
        }
        if final {
            progress.music.failed = progress.music.total - progress.music.completed
            progress.artwork.failed = progress.artwork.total - progress.artwork.completed
        }
        progress.outOfSpace = full
        return progress
    }

    private func reportProgress() {
        lock.lock()
        let files = syncState.pendingFiles
        let callback = onProgress
        lock.unlock()
        guard let callback else { return }
        let snapshot = progressSnapshot(for: files, final: false)
        Task { @MainActor in callback(snapshot) }
    }

    private func resumeContinuationIfNeeded() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let files = syncState.pendingFiles
        self.onProgress = nil
        lock.unlock()

        guard let continuation else { return }
        Task { @MainActor in WKExtension.shared().isFrontmostTimeoutExtended = false }
        let progress = progressSnapshot(for: files, final: true)
        note { $0.finishedSync(progress) }
        continuation.resume(returning: progress)
    }

    private func note(_ body: @escaping @MainActor @Sendable (SyncActivityLog) -> Void) {
        lock.lock()
        let activity = activity
        lock.unlock()
        guard let activity else { return }
        Task { @MainActor in body(activity) }
    }

    /// unpacks a downloaded bundle straight into the file store, returning
    /// what landed; a write that runs out of space stops the whole sync
    private func extract(from location: URL) throws -> [FileToDownload] {
        var extracted: [FileToDownload] = []
        try TarReader.extract(from: location) { name, data in
            let parts = name.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let type = LibraryFileType(rawValue: String(parts[0])) else { return }
            let filename = String(parts[1])
            try fileStore.write(type, filename, data: data)
            extracted.append(FileToDownload(type: type, filename: filename))
        }
        return extracted
    }
}

extension WatchBundleDownloader: URLSessionDownloadDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // the temp file dies when this returns, so unpack synchronously
        guard BackgroundDownload.isAcceptable(downloadTask.response) else { return }
        do {
            let extracted = try extract(from: location)
            lock.lock()
            // cleared here, not in didComplete, so a completed download whose
            // extraction failed still counts as a failure there
            syncState.pendingBundleId = nil
            syncState.retriesUsed = 0
            BundleSync.save(syncState, to: stateURL)
            lock.unlock()
            if let type = extracted.first?.type {
                note { $0.downloadedBundle() }
                note { $0.extracted(extracted, type: type) }
            }
        } catch {
            if BackgroundDownload.isOutOfSpace(error) {
                lock.lock()
                outOfSpace = true
                lock.unlock()
                note { $0.outOfSpace() }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = uploadBodies.removeValue(forKey: task.taskIdentifier)
        let response = responseData.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let body {
            try? FileManager.default.removeItem(at: body)
        }

        let path = task.originalRequest?.url?.path ?? ""
        if path.hasSuffix("api/bundle") {
            registrationFinished(task: task, error: error, response: response)
        } else if path.contains("/bundle/") {
            downloadFinished(task: task, error: error)
        }
    }

    private func registrationFinished(task: URLSessionTask, error: Error?, response: Data?) {
        if error == nil, BackgroundDownload.isAcceptable(task.response), let response {
            do {
                let bundleId = try BundleSync.bundleId(fromResponseData: response)
                lock.lock()
                syncState.pendingBundleId = bundleId
                syncState.retriesUsed = 0
                BundleSync.save(syncState, to: stateURL)
                lock.unlock()
                note { $0.bundleRegistered() }
                advance()
            } catch {
                // the server answered but said no (stale library, bad auth);
                // retrying the same request can't fix that, so end the sync
                // and let the next one refetch
                note { $0.bundleFailed(reason: error.localizedDescription) }
                resumeContinuationIfNeeded()
            }
            return
        }
        retryOrFail(error: error, reason: "couldn't reach the server")
    }

    private func downloadFinished(task: URLSessionTask, error: Error?) {
        lock.lock()
        let extractedOK = syncState.pendingBundleId == nil
        let full = outOfSpace
        lock.unlock()

        if full {
            note { $0.outOfSpace() }
            resumeContinuationIfNeeded()
            return
        }
        if error == nil, extractedOK {
            reportProgress()
            advance()
            return
        }
        retryOrFail(error: error, reason: "bundle download failed")
    }

    /// retries the current step in place, or gives up on the whole sync;
    /// whatever isn't on disk counts as failed and the next sync tries again
    private func retryOrFail(error: Error?, reason: String) {
        lock.lock()
        let retriesUsed = syncState.retriesUsed
        let retry = BackgroundDownload.shouldRetry(error: error, isOnDisk: false, retriesUsed: retriesUsed)
        if retry {
            syncState.retriesUsed += 1
            BundleSync.save(syncState, to: stateURL)
        }
        lock.unlock()

        if retry {
            advance()
        } else {
            note { $0.bundleFailed(reason: error?.localizedDescription ?? reason) }
            resumeContinuationIfNeeded()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = eventsCompletion
        eventsCompletion = nil
        let hasContinuation = continuation != nil
        let state = syncState
        lock.unlock()
        completion?()

        // woken with no sync awaiting (the app was relaunched in the
        // background); if files are still missing, keep the chain moving
        guard !hasContinuation else { return }
        let step = BundleSync.nextStep(state: state, isOnDisk: { fileStore.exists($0.type, $0.filename) })
        guard step != .finished else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self, tasks.isEmpty else { return }
            advance()
        }
    }
}

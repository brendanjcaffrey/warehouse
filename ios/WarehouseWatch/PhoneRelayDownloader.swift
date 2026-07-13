import Foundation
import WatchKit

/// fetches the watch's missing files by asking the phone to send them over
/// watch connectivity, so the watch never needs the server. the phone's
/// transfer queue survives both apps being suspended; this side just tracks
/// arrivals, re-sends its shrinking missing list so the phone keeps topping
/// its queue up, and keeps a background refresh chain alive so nudges still
/// go out when the app leaves the foreground
@MainActor
final class PhoneRelayDownloader: BulkFileDownloading {
    /// how often to re-send the missing list while awaiting a download
    private static let nudgeInterval: TimeInterval = 60
    /// give up waiting after this long with no arrival or result at all;
    /// comfortably longer than the background refresh interval, so a quiet
    /// stretch while both apps are suspended isn't mistaken for a dead
    /// pipeline
    private static let stallTimeout: TimeInterval = 35 * 60
    /// how long until the next background wake that keeps nudging
    private static let backgroundRefreshInterval: TimeInterval = 15 * 60

    private let phone: WatchPhoneSession
    private let database: LibraryDatabase
    private let fileStore: FileStore

    private var tracker: RelayDownloadTracker?
    private var continuation: CheckedContinuation<DownloadProgress, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var lastActivity = Date()

    init(phone: WatchPhoneSession, database: LibraryDatabase, fileStore: FileStore) {
        self.phone = phone
        self.database = database
        self.fileStore = fileStore
    }

    nonisolated func downloadAll(
        _ files: [FileToDownload],
        token: String,
        baseURL: URL,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        // the protocol witness is nonisolated; all the state lives on the
        // main actor, so hop over once and stay there
        await run(files, onProgress: onProgress)
    }

    private func run(
        _ files: [FileToDownload],
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async -> DownloadProgress {
        let tracker = RelayDownloadTracker(
            files: files, isOnDisk: { [fileStore] in fileStore.exists($0.type, $0.filename) })
        self.tracker = tracker
        guard !tracker.isComplete else {
            self.tracker = nil
            return tracker.progress()
        }

        phone.onFileReceived = { [weak self] file in
            tracker.fileArrived(file)
            self?.noteActivity(onProgress)
        }
        phone.onFileFailed = { [weak self] file in
            tracker.filesFailed([file])
            self?.noteActivity(onProgress)
        }
        phone.onFileResult = { [weak self] result in
            tracker.filesFailed(result.failed)
            self?.noteActivity(onProgress)
        }
        phone.onOutOfSpace = { [weak self] in
            tracker.markOutOfSpace()
            self?.phone.sendCancelFileRequests()
            self?.noteActivity(onProgress)
        }

        // buy extra frontmost runtime after wrist-down and keep a chain of
        // background wakes scheduled while the download runs
        WKExtension.shared().isFrontmostTimeoutExtended = true
        Self.scheduleBackgroundRefresh()

        lastActivity = Date()
        phone.send(FileRequestPayload(files: tracker.missing))
        startNudging()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // completion or cancellation may have raced ahead of the
                // assignment above; settle now rather than strand the sync
                if Task.isCancelled || self.tracker?.isComplete != false {
                    self.finish()
                }
            }
        } onCancel: {
            // the view drove the sync away; settle with what's on disk and
            // let the transfers keep landing on their own
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
    }

    /// runs on the periodic background refresh, even after a relaunch with
    /// no sync awaiting: while files are missing, ask the phone again and
    /// keep the chain alive
    func keepDownloadsMoving() async {
        let music = (try? await database.musicFilenames()) ?? []
        let artwork = (try? await database.artworkFilenames()) ?? []
        let missing = SyncStore.missing(music: music, artwork: artwork, fileStore: fileStore)
        guard !missing.isEmpty else { return }
        phone.send(FileRequestPayload(files: missing))
        Self.scheduleBackgroundRefresh()
    }

    private func noteActivity(_ onProgress: @MainActor @Sendable (DownloadProgress) -> Void) {
        lastActivity = Date()
        guard let tracker else { return }
        onProgress(tracker.progress())
        if tracker.isComplete {
            finish()
        }
    }

    private func startNudging() {
        nudgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.nudgeInterval))
                guard !Task.isCancelled else { return }
                self?.nudge()
            }
        }
    }

    private func nudge() {
        guard let tracker, !tracker.isComplete else { return }
        if Date().timeIntervalSince(lastActivity) > Self.stallTimeout {
            // nothing has moved in a long time; count the rest as failed and
            // let a future sync ask again
            tracker.filesFailed(tracker.missing)
            finish()
            return
        }
        phone.send(FileRequestPayload(files: tracker.missing))
    }

    private func finish() {
        nudgeTask?.cancel()
        nudgeTask = nil
        phone.onFileReceived = nil
        phone.onFileFailed = nil
        phone.onFileResult = nil
        phone.onOutOfSpace = nil
        WKExtension.shared().isFrontmostTimeoutExtended = false

        guard let continuation, let tracker else { return }
        self.continuation = nil
        self.tracker = nil
        continuation.resume(returning: tracker.progress())
    }

    @MainActor
    private static func scheduleBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: backgroundRefreshInterval),
            userInfo: nil) { _ in }
    }
}

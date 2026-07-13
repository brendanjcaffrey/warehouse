import Foundation
import WatchConnectivity
import WatchKit

/// receives the phone's application context & hands it to the settings
/// store, carries queued play reports back to the phone, and runs the watch
/// side of relayed syncs: requests ride to the phone as messages & user
/// info, and the library & media files ride back as file transfers
@MainActor
final class WatchPhoneSession: NSObject {
    private let settings: WatchSettingsStore
    private let receiver: RelayFileReceiver
    /// arrivals are logged here rather than through the relay callbacks below,
    /// which are only wired up while a sync is awaiting them; files keep
    /// landing when nothing is, and those are the ones worth showing
    private let activity: SyncActivityLog

    /// fired once the session activates so held plays can be drained
    var onActivated: (@MainActor () -> Void)?
    /// relay callbacks, wired up by whoever is awaiting a bulk download
    var onFileReceived: (@MainActor (FileToDownload) -> Void)?
    var onFileFailed: (@MainActor (FileToDownload) -> Void)?
    var onFileResult: (@MainActor (FileResultPayload) -> Void)?
    var onOutOfSpace: (@MainActor () -> Void)?
    var onReachabilityChange: (@MainActor (Bool) -> Void)?

    private var libraryContinuation: CheckedContinuation<Data, Error>?
    private var libraryGeneration = 0
    private lazy var connectivityTasks = ConnectivityTaskHolder<WKWatchConnectivityRefreshBackgroundTask>(
        isIdle: {
            WCSession.default.activationState == .activated && !WCSession.default.hasContentPending
        },
        complete: { $0.setTaskCompletedWithSnapshot(false) })

    init(settings: WatchSettingsStore, fileStore: FileStore, activity: SyncActivityLog) {
        self.settings = settings
        self.activity = activity
        receiver = RelayFileReceiver(fileStore: fileStore)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var canSend: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    /// whether a message sent right now could reach the phone
    nonisolated static var isPhoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    /// plays already handed to the system's transfer queue, which persists
    /// across launches
    var outstandingPlayIds: Set<String> {
        Set(WCSession.default.outstandingUserInfoTransfers.compactMap {
            PlayPayload(dictionary: $0.userInfo)?.id
        })
    }

    /// queues the play for background delivery to the phone; the system
    /// retries until the phone takes it, even across relaunches
    func send(_ payload: PlayPayload) {
        WCSession.default.transferUserInfo(payload.encode())
    }

    /// queues a file request; delivery wakes the phone app in the background
    func send(_ request: FileRequestPayload) {
        WCSession.default.transferUserInfo(request.encode())
    }

    /// tells the phone to drop everything queued for this watch
    func sendCancelFileRequests() {
        WCSession.default.transferUserInfo(RelayRequest.encode(RelayRequest.cancelFileRequests))
    }

    /// sends a message the phone answers immediately; failures surface as
    /// thrown errors for the caller to map onto its offline path
    func sendWithReply(_ message: [String: Any]) async throws -> [String: Any] {
        guard canSend, WCSession.default.isReachable else {
            throw URLError(.notConnectedToInternet)
        }
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message) { reply in
                continuation.resume(returning: reply)
            } errorHandler: { error in
                continuation.resume(throwing: error)
            }
        }
    }

    /// waits for the phone's library transfer to land after an accepted
    /// library request; a fresh wait supersedes a stale one
    func awaitLibrary(timeout: TimeInterval) async throws -> Data {
        libraryContinuation?.resume(throwing: RelayLibraryError.timeout)
        libraryContinuation = nil
        libraryGeneration += 1
        let generation = libraryGeneration
        return try await withCheckedThrowingContinuation { continuation in
            libraryContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.expireLibraryWait(generation: generation)
            }
        }
    }

    /// holds a connectivity background task while the session still has content
    /// queued for us, then lets the app suspend again. a task held past the
    /// system's 15s allowance gets the app killed outright, so the holder lets
    /// go on a deadline too; the remaining transfers just wake us again
    func handleBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        connectivityTasks.hold(task)
    }

    private func completeConnectivityTasksIfIdle() {
        connectivityTasks.completeIfIdle()
    }

    private func expireLibraryWait(generation: Int) {
        guard generation == libraryGeneration, let continuation = libraryContinuation else { return }
        libraryContinuation = nil
        continuation.resume(throwing: RelayLibraryError.timeout)
    }

    private func resolveLibrary(with result: Result<Data, Error>) {
        guard let continuation = libraryContinuation else { return }
        libraryContinuation = nil
        continuation.resume(with: result)
    }

    private func handleReceived(_ received: RelayFileReceiver.Received) {
        switch received {
        case .library(let data):
            activity.receivedLibrary()
            resolveLibrary(with: .success(data))
        case .file(let file):
            activity.received(file)
            onFileReceived?(file)
        case .fileOutOfSpace:
            activity.outOfSpace()
            onOutOfSpace?()
        case .fileFailed(let file):
            activity.failed(file)
            onFileFailed?(file)
        case .ignored:
            break
        }
    }
}

extension WatchPhoneSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        // the last received context persists across launches, so settings
        // are available even when the phone isn't reachable
        apply(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            onActivated?()
            onReachabilityChange?(reachable)
            completeConnectivityTasksIfIdle()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            onReachabilityChange?(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
        Task { @MainActor in
            completeConnectivityTasksIfIdle()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            if let result = FileResultPayload(dictionary: userInfo) {
                activity.failed(result.failed)
                onFileResult?(result)
            } else if let result = LibraryResultPayload(dictionary: userInfo) {
                resolveLibrary(with: .failure(RelayLibraryError.server(result.error)))
            }
            completeConnectivityTasksIfIdle()
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // the file must be claimed before this call returns; the decode &
        // move are synchronous, only the notifications hop actors
        let received = receiver.receive(fileAt: file.fileURL, metadata: file.metadata)
        Task { @MainActor in
            handleReceived(received)
            completeConnectivityTasksIfIdle()
        }
    }

    private nonisolated func apply(_ context: [String: Any]) {
        guard let payload = WatchPayload(dictionary: context) else { return }
        Task { @MainActor in
            settings.apply(payload)
        }
    }
}

import Foundation
import WatchConnectivity

/// receives the phone's application context & hands it to the settings
/// store; also carries queued play reports back to the phone, and the live
/// remote traffic: what the phone is playing coming in, transport commands
/// going out
@MainActor
final class WatchPhoneSession: NSObject {
    weak var files: WatchFileDownloader?
    private let settings: WatchSettingsStore

    /// fired once the session activates so held plays can be drained
    var onActivated: (@MainActor () -> Void)?
    /// the store showing what the phone is playing; set after init because it
    /// sends its commands back through here
    weak var remote: WatchRemoteStore?

    init(settings: WatchSettingsStore) {
        self.settings = settings
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var canSend: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    /// whether the phone app is up & close enough to take a command
    var isReachable: Bool {
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

    /// sends a transport command & takes the phone's resulting state from the
    /// reply, which arrives whether or not the phone finds us reachable back
    func send(_ command: RemoteCommand) {
        guard isReachable else { return }
        WCSession.default.sendMessage(
            WatchRemoteMessage.command(command).encode(),
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(message: reply)
                }
            },
            // the phone went away mid-tap; the screen is corrected when it
            // comes back & reachability flips
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.updateReachability()
                }
            })
    }

    func requestFile(_ transfer: WatchFileTransfer, token: String, reply: @escaping @MainActor (PhoneFileReply) -> Void) {
        guard canSend, isReachable else { reply(.unavailable); return }
        var message = transfer.encode()
        message["token"] = token
        WCSession.default.sendMessage(message, replyHandler: { response in
            let result = (response["result"] as? String).flatMap(PhoneFileReply.init(rawValue:)) ?? .unavailable
            Task { @MainActor in reply(result) }
        }, errorHandler: { error in
            Task { @MainActor in
                WatchDiagnostics.shared.record(.init(kind: .requestRejected, id: transfer.id,
                                                     source: .phone, reply: .unavailable, error: error))
                reply(.unavailable)
            }
        })
    }

    func fileSize(_ type: LibraryFileType, filename: String, token: String) async -> Int64? {
        guard canSend, isReachable else { return nil }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                ["kind": "cachedFileSize", "fileType": type.rawValue, "filename": filename, "token": token],
                replyHandler: { response in
                    continuation.resume(returning: (response["bytes"] as? NSNumber)?.int64Value)
                }, errorHandler: { _ in continuation.resume(returning: nil) })
        }
    }

    func cancelFile(_ id: UUID) {
        guard canSend, isReachable else { return }
        WCSession.default.sendMessage(
            ["kind": "cancelCachedFile", "id": id.uuidString], replyHandler: nil, errorHandler: { _ in })
    }

    private func apply(message: [String: Any]) {
        if message["failed"] as? Bool == true, let transfer = WatchFileTransfer(dictionary: message) {
            files?.failed(transfer)
            return
        }
        guard let message = WatchRemoteMessage(dictionary: message) else { return }
        remote?.apply(message)
    }

    private func updateReachability() {
        WatchDiagnostics.shared.record(.init(kind: .reachabilityChanged, id: UUID(), source: .system,
                                             detail: isReachable ? .reachable : .unreachable))
        remote?.setReachable(isReachable)
        reconcileFiles()
    }

    private func reconcileFiles() {
        files?.configurationChanged()
        guard canSend, isReachable, let token = settings.token, files != nil else { return }
        let generation = settings.fileGeneration
        WCSession.default.sendMessage(
            ["kind": "reconcileCachedFiles", "token": token],
            replyHandler: { [weak self] message in
                let progress = (message["transfers"] as? [[String: Any]])?.compactMap(PhoneFileProgress.init(dictionary:))
                Task { @MainActor in
                    guard let self, self.settings.fileGeneration == generation, let progress else { return }
                    self.files?.reconcile(progress)
                }
            }, errorHandler: { _ in })
    }
}

extension WatchPhoneSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            WatchDiagnostics.shared.record(.init(kind: .activationChanged, id: UUID(), source: .system,
                                                 error: error, detail: activationState == .activated ? .activated : .inactive))
        }
        guard activationState == .activated else { return }
        // the last received context persists across launches, so settings
        // are available even when the phone isn't reachable
        let payload = WatchPayload(dictionary: session.receivedApplicationContext)
        Task { @MainActor in
            if let payload { settings.apply(payload) }
            files?.configurationChanged()
            onActivated?()
            updateReachability()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            apply(message: message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let staged: (WatchFileTransfer, URL)
        do {
            guard let result = try WatchFileTransfer.stage(file.fileURL, metadata: file.metadata) else { return }
            staged = result
        } catch {
            guard let metadata = file.metadata, let transfer = WatchFileTransfer(dictionary: metadata) else { return }
            let outOfSpace = BackgroundDownload.isOutOfSpace(error)
            Task { @MainActor in files?.stagingFailed(transfer, outOfSpace: outOfSpace) }
            return
        }
        let (transfer, temporary) = staged
        Task { @MainActor in
            guard let files else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            files.receive(transfer, from: temporary)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateReachability()
        }
    }

    private nonisolated func apply(_ context: [String: Any]) {
        guard let payload = WatchPayload(dictionary: context) else { return }
        Task { @MainActor in
            settings.apply(payload)
            files?.configurationChanged()
            reconcileFiles()
        }
    }
}

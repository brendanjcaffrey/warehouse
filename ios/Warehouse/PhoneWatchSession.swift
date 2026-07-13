import Foundation
import WatchConnectivity

/// pushes the server credentials & playlist selection to the watch through
/// the application context, which is delivered even when the watch app isn't
/// running and always reflects the latest value; also receives play reports
/// queued on the watch, and relays sync requests so the watch never has to
/// reach the server itself
@MainActor
final class PhoneWatchSession: NSObject {
    private let payload: @MainActor () -> WatchPayload
    private let onPlay: @MainActor (String) -> Void

    /// a file request or cancel arrived from the watch
    var onFileRequest: (@MainActor (FileRequestPayload) -> Void)?
    var onCancelFileRequests: (@MainActor () -> Void)?
    /// the watch wants the server's library version or the library itself
    var onVersionRequest: (@MainActor () async -> VersionReply)?
    var onLibraryRequest: (@MainActor () -> Void)?
    /// a queued transfer to the watch finished (or failed)
    var onFileTransferFinished: (@MainActor (FileTransferMetadata, URL, Error?) -> Void)?

    init(
        payload: @escaping @MainActor () -> WatchPayload,
        onPlay: @escaping @MainActor (String) -> Void
    ) {
        self.payload = payload
        self.onPlay = onPlay
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        // failures are fine: the context is re-pushed on the next change or activation
        try? WCSession.default.updateApplicationContext(payload().encode())
    }

    /// hands a file to the system's transfer queue, which delivers it to the
    /// watch even while both apps are suspended
    func transferFile(at url: URL, metadata: FileTransferMetadata) {
        WCSession.default.transferFile(url, metadata: metadata.encode())
    }

    /// the files the system's persisted transfer queue already owns, so the
    /// relay engine never queues the same file twice
    var outstandingFileTransfers: Set<FileToDownload> {
        Set(WCSession.default.outstandingFileTransfers.compactMap {
            if case .file(let file) = FileTransferMetadata(dictionary: $0.file.metadata) {
                return file
            }
            return nil
        })
    }

    /// drops queued file transfers when the watch reports it's out of space;
    /// a queued library transfer is small & left alone
    func cancelOutstandingFileTransfers() {
        for transfer in WCSession.default.outstandingFileTransfers {
            if case .file = FileTransferMetadata(dictionary: transfer.file.metadata) {
                transfer.cancel()
            }
        }
    }

    func send(_ result: FileResultPayload) {
        WCSession.default.transferUserInfo(result.encode())
    }

    func send(_ result: LibraryResultPayload) {
        WCSession.default.transferUserInfo(result.encode())
    }
}

extension PhoneWatchSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.push()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo: userInfo)
    }

    // split from the delegate method so tests can exercise the decode & hop
    // without a real session
    nonisolated func receive(userInfo: [String: Any]) {
        if let payload = PlayPayload(dictionary: userInfo) {
            Task { @MainActor in
                onPlay(payload.trackId)
            }
        } else if let request = FileRequestPayload(dictionary: userInfo) {
            Task { @MainActor in
                onFileRequest?(request)
            }
        } else if RelayRequest.matches(userInfo, RelayRequest.cancelFileRequests) {
            Task { @MainActor in
                onCancelFileRequests?()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receive(message: message, reply: replyHandler)
    }

    // also split out for tests; the reply always fires so the watch's send
    // never times out waiting on an unknown message
    nonisolated func receive(message: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void) {
        if RelayRequest.matches(message, RelayRequest.version) {
            Task { @MainActor in
                let versionReply = await onVersionRequest?() ?? .offline
                reply(versionReply.encode())
            }
        } else if RelayRequest.matches(message, RelayRequest.library) {
            Task { @MainActor in
                // accept right away; the library arrives as a file transfer
                reply(RelayRequest.acceptedReply())
                onLibraryRequest?()
            }
        } else {
            reply([:])
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard let metadata = FileTransferMetadata(dictionary: fileTransfer.file.metadata) else { return }
        let url = fileTransfer.file.fileURL
        Task { @MainActor in
            onFileTransferFinished?(metadata, url, error)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // the session deactivates when the user switches watches; reactivate
        // so the new watch gets the context
        session.activate()
    }
}

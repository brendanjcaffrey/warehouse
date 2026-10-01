import Foundation
import WatchConnectivity

/// pushes the server credentials & playlist selection to the watch through
/// the application context, which is delivered even when the watch app isn't
/// running and always reflects the latest value; also receives play reports
/// queued on the watch, and — while the watch app is up — mirrors what the
/// phone is playing so the watch can drive it as a remote
@MainActor
final class PhoneWatchSession: NSObject {
    private let files: PhoneFileProvider?
    private let payload: @MainActor () -> WatchPayload
    private let onPlay: @MainActor (String) -> Void
    private let nowPlaying: @MainActor () -> RemotePlaybackPayload?
    private let onCommand: @MainActor (RemoteCommand) -> Void

    init(
        files: PhoneFileProvider? = nil,
        payload: @escaping @MainActor () -> WatchPayload,
        onPlay: @escaping @MainActor (String) -> Void,
        nowPlaying: @escaping @MainActor () -> RemotePlaybackPayload? = { nil },
        onCommand: @escaping @MainActor (RemoteCommand) -> Void = { _ in }
    ) {
        self.files = files
        self.payload = payload
        self.onPlay = onPlay
        self.nowPlaying = nowPlaying
        self.onCommand = onCommand
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

    /// sends what's playing to a watch that is listening. this rides
    /// sendMessage rather than the context: it's only useful while the watch
    /// app is up, & the context belongs to the settings, which must not be
    /// overwritten by a stream of playback updates
    func pushNowPlaying() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable
        else {
            return
        }
        WCSession.default.sendMessage(
            WatchRemoteMessage.nowPlaying(nowPlaying()).encode(),
            replyHandler: nil,
            // nothing to do about it: the watch asks again when it next opens
            errorHandler: { _ in })
    }
}

extension PhoneWatchSession: WCSessionDelegate {
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
        guard let payload = PlayPayload(dictionary: userInfo) else { return }
        Task { @MainActor in
            onPlay(payload.trackId)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message: message)
    }

    /// the watch asks with a reply handler so the answer doesn't depend on the
    /// phone finding it reachable in the other direction
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receive(message: message, replyHandler: replyHandler)
    }

    nonisolated func receive(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["kind"] as? String == "cachedFileSize" {
            let token = message["token"] as? String ?? ""
            let type = (message["fileType"] as? String).flatMap(LibraryFileType.init(rawValue:))
            let filename = message["filename"] as? String
            Task { @MainActor in
                guard let type, let filename,
                      let size = files?.fileSize(type, filename: filename, token: token) else {
                    replyHandler([:])
                    return
                }
                replyHandler(["bytes": size])
            }
            return
        }
        if message["kind"] as? String == "reconcileCachedFiles" {
            let token = message["token"] as? String ?? ""
            Task { @MainActor in
                guard let progress = files?.progress(token: token) else {
                    replyHandler(["result": PhoneFileReply.unauthorized.rawValue])
                    return
                }
                replyHandler(["transfers": progress.map { $0.encode() }])
            }
            return
        }
        if let transfer = WatchFileTransfer(dictionary: message) {
            let token = message["token"] as? String ?? ""
            Task { @MainActor in
                replyHandler(["result": (files?.request(transfer, token: token) ?? .unavailable).rawValue])
            }
            return
        }
        receive(message: message)
        Task { @MainActor in
            replyHandler(WatchRemoteMessage.nowPlaying(nowPlaying()).encode())
        }
    }

    /// split from the delegate method for the same reason as `receive(userInfo:)`
    nonisolated func receive(message: [String: Any]) {
        if message["kind"] as? String == "cancelCachedFile",
           let rawID = message["id"] as? String, let id = UUID(uuidString: rawID) {
            Task { @MainActor in files?.cancel(id) }
            return
        }
        guard case .command(let command)? = WatchRemoteMessage(dictionary: message) else { return }
        Task { @MainActor in
            // a state request only wants the answer below
            if command != .requestState {
                onCommand(command)
            }
            // the watch is showing what it thinks is happening; tell it what
            // actually did
            pushNowPlaying()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let metadata = fileTransfer.file.metadata,
           let transfer = WatchFileTransfer(dictionary: metadata) {
            Task { @MainActor in files?.finished(transfer, error: error) }
        }
        guard error != nil, session.isReachable,
              let metadata = fileTransfer.file.metadata,
              let transfer = WatchFileTransfer(dictionary: metadata)
        else { return }
        var message = transfer.encode()
        message["failed"] = true
        session.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // the watch app just came up or went away; a watch that's listening
        // needs the current track, since pushes made while it was gone were
        // dropped
        Task { @MainActor in
            self.pushNowPlaying()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // the session deactivates when the user switches watches; reactivate
        // so the new watch gets the context
        session.activate()
    }
}

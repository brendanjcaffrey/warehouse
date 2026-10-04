import Foundation
import WatchConnectivity
import UIKit

/// publishes the phone-supplied library and receives durable play reports.
/// live remote messages mirror phone playback and carry transport commands.
@MainActor
final class PhoneWatchSession: NSObject {
    var content: PhoneWatchContentQueue?
    var publishLibrary: (() -> Void)?
    private let diagnostics: WatchDiagnostics
    private let onPlay: @MainActor (PlayPayload) throws -> Void
    private let acknowledgePlay: @MainActor (PlayPayload) -> Void
    private let nowPlaying: @MainActor () -> RemotePlaybackPayload?
    private let onCommand: @MainActor (RemoteCommand) -> Void
    private let diagnosticInbox: WatchDiagnosticInbox

    init(
        onPlay: @escaping @MainActor (PlayPayload) throws -> Void,
        acknowledgePlay: @escaping @MainActor (PlayPayload) -> Void = { play in
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
            let receipt = PlayReceipt(play)
            let queued = WCSession.default.outstandingUserInfoTransfers.contains {
                PlayReceipt(dictionary: $0.userInfo)?.play == play
            }
            if !queued { WCSession.default.transferUserInfo(receipt.encode()) }
        },
        nowPlaying: @escaping @MainActor () -> RemotePlaybackPayload? = { nil },
        onCommand: @escaping @MainActor (RemoteCommand) -> Void = { _ in },
        diagnosticInbox: WatchDiagnosticInbox? = nil, diagnostics: WatchDiagnostics? = nil
    ) {
        self.diagnostics = diagnostics ?? .shared
        self.onPlay = onPlay
        self.acknowledgePlay = acknowledgePlay
        self.nowPlaying = nowPlaying
        self.onCommand = onCommand
        self.diagnosticInbox = diagnosticInbox ?? WatchDiagnosticInbox()
    }

    func diagnosticReport(deviceModel: String, systemVersion: String) -> WatchDiagnosticReport {
        diagnostics.report(deviceModel: deviceModel, systemVersion: systemVersion, delivery: content?.diagnosticState())
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push() {
        content?.requestInventory()
        publishLibrary?()
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
        if userInfo["kind"] as? String == "watchLibraryRequest" {
            Task { @MainActor in push() }
            return
        }
        if let report = WatchInventoryReport(dictionary: userInfo) {
            Task { @MainActor in try? content?.receive(report) }
            return
        }
        if let receipt = WatchContentReceipt(dictionary: userInfo) {
            Task { @MainActor in
                try? content?.receive(receipt)
            }
            return
        }
        guard let payload = PlayPayload(dictionary: userInfo) else { return }
        Task { @MainActor in
            do {
                try onPlay(payload)
                acknowledgePlay(payload)
            } catch {
                // no acknowledgment: the watch retains ownership and retries.
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message: message)
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        receive(data: messageData, replyHandler: replyHandler)
    }

    nonisolated func receive(data: Data, replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor in
            let device = UIDevice.current
            replyHandler(diagnosticInbox.receiveMessage(data,
                phone: diagnosticReport(deviceModel: device.model, systemVersion: device.systemVersion)))
        }
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
        if ["cachedFileSize", "reconcileCachedFiles", "cachedFile", "cancelCachedFile"].contains(message["kind"] as? String ?? "") {
            replyHandler(["result": "unavailable"])
            return
        }
        receive(message: message)
        Task { @MainActor in
            replyHandler(WatchRemoteMessage.nowPlaying(nowPlaying()).encode())
        }
    }

    /// split from the delegate method for the same reason as `receive(userInfo:)`
    nonisolated func receive(message: [String: Any]) {
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
        receiveFileCompletion(metadata: fileTransfer.file.metadata, error: error)
    }

    @discardableResult
    nonisolated func receiveFileCompletion(metadata: [String: Any]?, error: Error?) -> Bool {
        if metadata?["kind"] as? String == "watchContentFile", let metadata, let file = WatchContentFile(dictionary: metadata) {
            Task { @MainActor in try? content?.finished(file, error: error) }
            return true
        }
        if metadata?["kind"] as? String == "watchLibrarySnapshot" {
            let key = metadata?["watchLibraryKey"] as? String
            Task { @MainActor in
                let parts = key?.split(separator: "-")
                let publisher = key.flatMap { UUID(uuidString: String($0.prefix(36))) }
                let revision = parts?.last.flatMap { Int64($0) }
                let head = publisher.flatMap { publisher in
                    revision.map { WatchLibraryHead(publisher: publisher, revision: $0, libraryID: nil, playlistIDs: []) }
                }
                diagnostics.record(.init(kind: error == nil ? .metadataCompleted : .metadataFailed,
                                         id: publisher ?? UUID(), source: .system, error: error,
                                         identity: head.map(WatchDiagnosticIdentity.init)))
                if error != nil {
                    try? await Task.sleep(for: .seconds(5))
                    publishLibrary?()
                }
            }
            return true
        }
        return false
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // the watch app just came up or went away; a watch that's listening
        // needs the current track, since pushes made while it was gone were
        // dropped
        Task { @MainActor in
            self.pushNowPlaying()
            if session.isReachable { self.push() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // the session deactivates when the user switches watches; reactivate
        // so the new watch gets the context
        session.activate()
    }
}

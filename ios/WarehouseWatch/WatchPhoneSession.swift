import Foundation
import WatchConnectivity

/// receives the phone's application context & hands it to the settings
/// store; also carries queued play reports back to the phone
@MainActor
final class WatchPhoneSession: NSObject {
    private let settings: WatchSettingsStore

    /// fired once the session activates so held plays can be drained
    var onActivated: (@MainActor () -> Void)?

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
        Task { @MainActor in
            onActivated?()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    private nonisolated func apply(_ context: [String: Any]) {
        guard let payload = WatchPayload(dictionary: context) else { return }
        Task { @MainActor in
            settings.apply(payload)
        }
    }
}

import Foundation
import WatchConnectivity

/// receives the phone's application context & hands it to the settings
/// store; also carries queued play reports back to the phone, and the live
/// remote traffic: what the phone is playing coming in, transport commands
/// going out
@MainActor
final class WatchPhoneSession: NSObject {
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

    private func apply(message: [String: Any]) {
        guard let message = WatchRemoteMessage(dictionary: message) else { return }
        remote?.apply(message)
    }

    private func updateReachability() {
        remote?.setReachable(isReachable)
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

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateReachability()
        }
    }

    private nonisolated func apply(_ context: [String: Any]) {
        guard let payload = WatchPayload(dictionary: context) else { return }
        Task { @MainActor in
            settings.apply(payload)
        }
    }
}

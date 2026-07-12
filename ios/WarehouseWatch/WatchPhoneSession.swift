import Foundation
import WatchConnectivity

/// receives the phone's application context & hands it to the settings store
@MainActor
final class WatchPhoneSession: NSObject {
    private let settings: WatchSettingsStore

    init(settings: WatchSettingsStore) {
        self.settings = settings
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
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

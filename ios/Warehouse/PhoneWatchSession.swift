import Foundation
import WatchConnectivity

/// pushes the server credentials & playlist selection to the watch through
/// the application context, which is delivered even when the watch app isn't
/// running and always reflects the latest value; also receives play reports
/// queued on the watch
@MainActor
final class PhoneWatchSession: NSObject {
    private let payload: @MainActor () -> WatchPayload
    private let onPlay: @MainActor (String) -> Void

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
        guard let payload = PlayPayload(dictionary: userInfo) else { return }
        Task { @MainActor in
            onPlay(payload.trackId)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // the session deactivates when the user switches watches; reactivate
        // so the new watch gets the context
        session.activate()
    }
}

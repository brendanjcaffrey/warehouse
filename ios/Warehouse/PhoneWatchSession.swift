import Foundation
import WatchConnectivity

/// pushes the server credentials & playlist selection to the watch through
/// the application context, which is delivered even when the watch app isn't
/// running and always reflects the latest value
@MainActor
final class PhoneWatchSession: NSObject {
    private let payload: @MainActor () -> WatchPayload

    init(payload: @escaping @MainActor () -> WatchPayload) {
        self.payload = payload
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

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // the session deactivates when the user switches watches; reactivate
        // so the new watch gets the context
        session.activate()
    }
}

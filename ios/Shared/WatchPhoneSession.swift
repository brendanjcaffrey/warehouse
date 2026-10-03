import Foundation
import WatchConnectivity

/// receives the phone-supplied library, returns durable play reports and controls phone playback.
@MainActor
final class WatchPhoneSession: NSObject {
    nonisolated let contentActivity = WatchContentActivity()
    var content: WatchContentReceiver?
    let library: WatchLibraryReceiver
    let lifetime = WatchLibraryBackgroundLifetime()
    private var contentObservation: NSKeyValueObservation?
    private let sendDiagnosticData: @MainActor (Data, @escaping @MainActor (Bool) -> Void) -> Void

    /// fired once the session activates so held plays can be drained
    var onActivated: (@MainActor () -> Void)?
    /// the store showing what the phone is playing; set after init because it
    /// sends its commands back through here
    weak var remote: WatchRemoteStore?

    init(
        library: WatchLibraryReceiver,
        sendDiagnosticData: @escaping @MainActor (Data, @escaping @MainActor (Bool) -> Void) -> Void = { data, completion in
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
                completion(false)
                return
            }
            WCSession.default.sendMessageData(data, replyHandler: { reply in
                Task { @MainActor in completion(reply == Data("saved".utf8)) }
            }, errorHandler: { _ in
                Task { @MainActor in completion(false) }
            })
        }
    ) {
        self.library = library
        self.sendDiagnosticData = sendDiagnosticData
        super.init()
        library.onIdle = { [weak self] in self?.updateBackgroundLifetime() }
    }

    func diagnosticReport(deviceModel: String, systemVersion: String) -> WatchDiagnosticReport {
        WatchDiagnostics.shared.report(deviceModel: deviceModel, systemVersion: systemVersion, delivery: content?.diagnosticState())
    }

    func sendDiagnostics(_ report: WatchDiagnosticReport, completion: @escaping @MainActor (Bool) -> Void) {
        guard let data = report.encoded() else { completion(false); return }
        sendDiagnosticData(data, completion)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        contentObservation = WCSession.default.observe(\.hasContentPending, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.updateBackgroundLifetime() }
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func updateBackgroundLifetime() {
        lifetime.update(activated: WCSession.default.activationState == .activated,
                        contentPending: WCSession.default.hasContentPending, importsPending: library.pendingOperations + contentActivity.count)
    }

    func requestLibrary() {
        guard canSend else { return }
        WCSession.default.transferUserInfo(["kind": "watchLibraryRequest"])
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
        WatchDiagnostics.shared.record(.init(kind: .reachabilityChanged, id: UUID(), source: .system,
                                             detail: isReachable ? .reachable : .unreachable))
        remote?.setReachable(isReachable)
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
        // the last received library head persists across launches, even
        // when the phone is unavailable
        let context = session.receivedApplicationContext
        Task { @MainActor in
            applyContext(context)
            library.resume()
            content?.resume()
            updateBackgroundLifetime()
            onActivated?()
            requestLibrary()
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

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let request = WatchInventoryRequest(dictionary: userInfo) {
            contentActivity.begin()
            Task { @MainActor in
                defer { contentActivity.end(); updateBackgroundLifetime() }
                try? content?.query(request)
            }
            return
        }
        if let report = WatchLibraryDeliveryReport(dictionary: userInfo) {
            Task { @MainActor in try? content?.receive(report) }
            return
        }
        guard userInfo["kind"] as? String == "watchContentQuery", let file = WatchContentFile(dictionary: userInfo) else { return }
        Task { @MainActor in try? content?.query(file) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if file.metadata?["kind"] as? String == "watchContentFile",
           let metadata = file.metadata, let contentFile = WatchContentFile(dictionary: metadata) {
            contentActivity.begin()
            do {
                try WatchContentReceiver.stage(file.fileURL, file: contentFile)
                Task { @MainActor in
                    defer { contentActivity.end(); updateBackgroundLifetime() }
                    content?.staged(contentFile)
                }
            } catch {
                Task { @MainActor in
                    defer { contentActivity.end(); updateBackgroundLifetime() }
                    content?.stagingFailed(contentFile, error: error)
                }
            }
            return
        }
        if file.metadata?["kind"] as? String == "watchLibrarySnapshot" {
            do {
                _ = try WatchLibraryReceiver.stage(file.fileURL)
                Task { @MainActor in library.received(); updateBackgroundLifetime() }
            } catch {
                Task { @MainActor in library.failed(error); updateBackgroundLifetime() }
            }
            return
        }
        // obsolete file protocols are ignored; saved local files remain available.
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateReachability()
            if session.isReachable { requestLibrary() }
        }
    }

    private nonisolated func apply(_ context: [String: Any]) {
        Task { @MainActor in applyContext(context) }
    }

    func applyContext(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        content?.pause()
        if let head = WatchLibraryHead(context: context) {
            library.expect(head)
        } else {
            library.rejectContext()
        }
        updateBackgroundLifetime()
    }
}

#if os(iOS)
extension WatchPhoneSession {
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
}
#endif

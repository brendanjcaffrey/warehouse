import Foundation
import WatchConnectivity

/// receives the phone-supplied library, returns durable play reports and controls phone playback.
@MainActor
final class WatchPhoneSession: NSObject {
    struct LibraryTransport {
        var available: () -> Bool = { WCSession.isSupported() && WCSession.default.activationState == .activated }
        var outstanding: () -> [[String: Any]] = { WCSession.default.outstandingUserInfoTransfers.map(\.userInfo) }
        var enqueue: ([String: Any]) -> Void = { WCSession.default.transferUserInfo($0) }
    }

    nonisolated let contentActivity = WatchContentActivity()
    var content: WatchContentReceiver? {
        didSet {
            oldValue?.onActivityChanged = {}
            content?.onActivityChanged = { [weak self] in self?.updateBackgroundLifetime() }
            updateBackgroundLifetime()
        }
    }
    let library: WatchLibraryReceiver
    let lifetime = WatchLibraryBackgroundLifetime()
    private nonisolated let metadataDirectory: URL
    private let sessionState: @MainActor () -> (activated: Bool, contentPending: Bool)
    private var contentObservation: NSKeyValueObservation?
    private let sendDiagnosticData: @MainActor (Data, @escaping @MainActor (Result<Data, Error>) -> Void) -> Void
    private let remoteReachable: @MainActor () -> Bool
    private let sendRemoteMessage: ([String: Any], @escaping ([String: Any]) -> Void, @escaping () -> Void) -> Void
    private let libraryTransport: LibraryTransport
    private var libraryRequestTask: Task<Void, Never>?

    var onPlayReceipt: (@MainActor (PlayPayload) -> Void)?
    var onPlayTransferFinished: (@MainActor (PlayPayload) -> Void)?
    /// fired once the session activates so held plays can be drained
    var onActivated: (@MainActor () -> Void)?
    /// the store showing what the phone is playing; set after init because it
    /// sends its commands back through here
    weak var remote: WatchRemoteStore?

    init(
        library: WatchLibraryReceiver,
        libraryTransport: LibraryTransport = .init(),
        sessionState: @escaping @MainActor () -> (activated: Bool, contentPending: Bool) = {
            (WCSession.default.activationState == .activated, WCSession.default.hasContentPending)
        },
        remoteReachable: @escaping @MainActor () -> Bool = {
            WCSession.isSupported() && WCSession.default.isReachable
        },
        sendRemoteMessage: @escaping ([String: Any], @escaping ([String: Any]) -> Void, @escaping () -> Void) -> Void = { message, reply, failure in
            WCSession.default.sendMessage(message, replyHandler: reply, errorHandler: { _ in failure() })
        },
        sendDiagnosticData: @escaping @MainActor (Data, @escaping @MainActor (Result<Data, Error>) -> Void) -> Void = { data, completion in
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
                completion(.failure(NSError(domain: WCErrorDomain, code: WCError.Code.sessionNotActivated.rawValue)))
                return
            }
            WCSession.default.sendMessageData(data, replyHandler: { reply in
                Task { @MainActor in completion(.success(reply)) }
            }, errorHandler: { error in
                Task { @MainActor in completion(.failure(error)) }
            })
        }
    ) {
        self.library = library
        self.libraryTransport = libraryTransport
        metadataDirectory = library.directory
        self.sessionState = sessionState
        self.remoteReachable = remoteReachable
        self.sendRemoteMessage = sendRemoteMessage
        self.sendDiagnosticData = sendDiagnosticData
        super.init()
        library.onIdle = { [weak self] in self?.updateBackgroundLifetime() }
    }

    func diagnosticReport(deviceModel: String, systemVersion: String) -> WatchDiagnosticReport {
        WatchDiagnostics.shared.report(deviceModel: deviceModel, systemVersion: systemVersion, delivery: content?.diagnosticState())
    }

    func sendDiagnostics(_ report: WatchDiagnosticReport, completion: @escaping @MainActor (Result<Void, WatchDiagnosticSendError>) -> Void) {
        guard let data = report.encoded() else { completion(.failure(.encoding)); return }
        do {
            let messages = try WatchDiagnosticMessage.messages(data)
            sendDiagnosticMessages(messages[...], completion: completion)
        } catch {
            completion(.failure(.reportTooLarge))
        }
    }

    private func sendDiagnosticMessages(_ messages: ArraySlice<Data>, completion: @escaping @MainActor (Result<Void, WatchDiagnosticSendError>) -> Void) {
        guard let data = messages.first else { completion(.success(())); return }
        sendDiagnosticData(data) { [self] result in
            switch result {
            case .failure(let error):
                let error = error as NSError
                completion(.failure(.connectivity(code: error.domain == WCErrorDomain ? error.code : nil)))
            case .success(let reply):
                let expected = messages.count == 1 ? WatchDiagnosticMessage.saved : WatchDiagnosticMessage.more
                guard reply == expected else { completion(.failure(.phoneRejected)); return }
                sendDiagnosticMessages(messages.dropFirst(), completion: completion)
            }
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        contentObservation = WCSession.default.observe(\.hasContentPending, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            self.dispatch { [self] in self.updateBackgroundLifetime() }
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func updateBackgroundLifetime() {
        let state = sessionState()
        lifetime.update(activated: state.activated, contentPending: state.contentPending,
                        importsPending: library.pendingOperations + contentActivity.count + (content?.pendingOperations ?? 0))
    }

    func requestLibrary() {
        guard libraryRequestTask == nil else { return }
        contentActivity.begin()
        updateBackgroundLifetime()
        libraryRequestTask = Task {
            defer {
                libraryRequestTask = nil
                contentActivity.end()
                updateBackgroundLifetime()
            }
            await library.waitForImport()
            guard libraryTransport.available() else { return }
            let request = WatchLibraryRequest(acceptedHead: library.snapshot?.head)
            guard !libraryTransport.outstanding().contains(where: { WatchLibraryRequest(dictionary: $0) == request }),
                  let info = try? request.encode() else { return }
            libraryTransport.enqueue(info)
        }
    }

    func waitForLibraryRequest() async { await libraryRequestTask?.value }

    var canSend: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    /// whether the phone app is up & close enough to take a command
    var isReachable: Bool {
        remoteReachable()
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
    func send(_ command: RemoteCommand, completion: @escaping @MainActor (WatchRemoteMessage?) -> Void) {
        guard isReachable else {
            updateReachability()
            completion(nil)
            return
        }
        sendRemoteMessage(
            WatchRemoteMessage.command(command).encode(),
            { [weak self] reply in
                self?.dispatch {
                    completion(WatchRemoteMessage(dictionary: reply))
                }
            },
            { [weak self] in
                self?.dispatch { [self] in
                    self?.updateReachability()
                    completion(nil)
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

    /// register delegate work before yielding, since system delivery can already be idle.
    private nonisolated func dispatch(_ operation: @escaping @MainActor () -> Void) {
        contentActivity.begin()
        dispatchHeld(operation)
    }

    /// file callbacks acquire their hold before staging and keep it through this actor hop.
    private nonisolated func dispatchHeld(_ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            defer { contentActivity.end(); updateBackgroundLifetime() }
            operation()
        }
    }
}

extension WatchPhoneSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        dispatch { [self] in
            WatchDiagnostics.shared.record(.init(kind: .activationChanged, id: UUID(), source: .system,
                                                 error: error, detail: activationState == .activated ? .activated : .inactive))
            guard activationState == .activated else { return }
            // the last received library head persists across launches, even
            // when the phone is unavailable
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
        dispatch { [self] in
            apply(message: message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let receipt = PlayReceipt(dictionary: userInfo) {
            dispatch { [self] in onPlayReceipt?(receipt.play) }
            return
        }
        if let completion = WatchInventoryCompletion(dictionary: userInfo) {
            dispatch { [self] in try? content?.receive(completion) }
            return
        }
        if let request = WatchInventoryRequest(dictionary: userInfo) {
            dispatch { [self] in
                try? content?.query(request)
            }
            return
        }
        if let report = WatchLibraryDeliveryReport(dictionary: userInfo) {
            dispatch { [self] in try? content?.receive(report) }
            return
        }
        guard userInfo["kind"] as? String == "watchContentQuery", let file = WatchContentFile(dictionary: userInfo) else { return }
        dispatch { [self] in try? content?.query(file) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        receivePlayCompletion(userInfoTransfer.userInfo, error: error)
    }

    nonisolated func receivePlayCompletion(_ userInfo: [String: Any], error: Error?) {
        guard let play = PlayPayload(dictionary: userInfo) else { return }
        dispatch { [self] in onPlayTransferFinished?(play) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        receiveFile(file.fileURL, metadata: file.metadata)
    }

    nonisolated func receiveFile(_ source: URL, metadata: [String: Any]?) {
        if metadata?["kind"] as? String == "watchContentFile",
           let metadata, let contentFile = WatchContentFile(dictionary: metadata) {
            contentActivity.begin()
            do {
                try WatchContentReceiver.stage(source, file: contentFile)
                dispatchHeld { [self] in
                    content?.staged(contentFile)
                }
            } catch {
                dispatchHeld { [self] in
                    content?.stagingFailed(contentFile, error: error)
                }
            }
            return
        }
        if metadata?["kind"] as? String == "watchLibrarySnapshot" {
            contentActivity.begin()
            do {
                _ = try WatchLibraryReceiver.stage(source, directory: metadataDirectory)
                dispatchHeld { [self] in library.received() }
            } catch {
                dispatchHeld { [self] in library.failed(error) }
            }
            return
        }
        // obsolete file protocols are ignored; saved local files remain available.
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        dispatch { [self] in
            updateReachability()
            if session.isReachable { requestLibrary() }
        }
    }

    private nonisolated func apply(_ context: [String: Any]) {
        dispatch { [self] in applyContext(context) }
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

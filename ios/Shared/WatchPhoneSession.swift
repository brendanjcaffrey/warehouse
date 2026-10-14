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
            resendContentReceipts()
        }
    }
    let library: WatchLibraryReceiver
    let lifetime = WatchLibraryBackgroundLifetime()
    private nonisolated let metadataDirectory: URL
    private nonisolated let contentDirectory: URL
    private let sessionState: @MainActor () -> (activated: Bool, contentPending: Bool)
    private var contentObservation: NSKeyValueObservation?
    private let sendDiagnosticData: @MainActor (Data, @escaping @MainActor (Result<Data, Error>) -> Void) -> Void
    private let remoteReachable: @MainActor () -> Bool
    private let sendRemoteMessage: ([String: Any], @escaping ([String: Any]) -> Void, @escaping () -> Void) -> Void
    private let libraryTransport: LibraryTransport
    private var libraryRequestTask: Task<Void, Never>?
    private var receiptReplayTask: Task<Void, Never>?
    private var receiptReplayRequested = false
    private var receiptReplayOutstanding: [UUID: [WatchContentReceipt]]?
    private static let receiptReplayBatchSize = 16
    private nonisolated let diagnostics: WatchDiagnostics
    private var lastBackground: WatchDiagnosticBackground?

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
        },
        diagnostics: WatchDiagnostics? = nil,
        contentDirectory: URL = WatchContentReceiver.defaultDirectory()
    ) {
        self.library = library
        self.libraryTransport = libraryTransport
        metadataDirectory = library.directory
        self.contentDirectory = contentDirectory
        self.sessionState = sessionState
        self.remoteReachable = remoteReachable
        self.sendRemoteMessage = sendRemoteMessage
        self.sendDiagnosticData = sendDiagnosticData
        self.diagnostics = diagnostics ?? .shared
        super.init()
        lifetime.onChanged = { [weak self] in self?.recordBackground() }
        lifetime.onCompleted = { [weak self] count in self?.recordBackground(completed: count) }
        library.onIdle = { [weak self] in self?.updateBackgroundLifetime() }
    }

    func diagnosticReport(deviceModel: String, systemVersion: String) -> WatchDiagnosticReport {
        var delivery = content?.diagnosticState() ?? WatchDeliveryDiagnosticState(peer: .watch)
        delivery.background = backgroundState()
        return diagnostics.report(deviceModel: deviceModel, systemVersion: systemVersion, delivery: delivery)
    }

    private func backgroundState() -> WatchDiagnosticBackground {
        let state = sessionState()
        return WatchDiagnosticBackground(activated: state.activated, contentPending: state.contentPending,
                                         libraryOperations: library.pendingOperations, callbackOperations: contentActivity.count,
                                         contentOperations: content?.pendingOperations ?? 0, heldTasks: lifetime.heldTasks)
    }

    private func recordBackground(completed: Int? = nil) {
        let background = backgroundState()
        guard completed != nil || background != lastBackground else { return }
        lastBackground = background
        var event = WatchDiagnostic(kind: completed == nil ? .backgroundStateChanged : .backgroundCompleted,
                                    id: UUID(), source: .system)
        event.background = background
        event.completedTasks = completed
        diagnostics.record(event)
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
        diagnostics.record(.init(kind: .sessionActivationRequested, id: UUID(), source: .system))
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

    func receivedBackgroundTask() {
        var event = WatchDiagnostic(kind: .backgroundTaskReceived, id: UUID(), source: .system)
        event.background = backgroundState()
        diagnostics.record(event)
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

    func sendContentReceipt(_ receipt: WatchContentReceipt) {
        guard libraryTransport.available(), let info = try? receipt.encode() else { return }
        if let outstanding = receiptReplayOutstanding {
            guard outstanding[receipt.file.id]?.contains(receipt) != true else { return }
        } else {
            guard !libraryTransport.outstanding().contains(where: { WatchContentReceipt(dictionary: $0) == receipt }) else { return }
        }
        libraryTransport.enqueue(info)
        receiptReplayOutstanding?[receipt.file.id, default: []].append(receipt)
    }

    private func resendContentReceipts() {
        receiptReplayRequested = true
        guard receiptReplayTask == nil, content?.receipts.isEmpty == false, libraryTransport.available() else { return }
        // register before dispatch so a connectivity task cannot complete while replay is queued.
        contentActivity.begin()
        updateBackgroundLifetime()
        receiptReplayTask = Task { [weak self, contentActivity] in
            guard let self else { contentActivity.end(); return }
            defer {
                receiptReplayTask = nil
                receiptReplayOutstanding = nil
                contentActivity.end()
                updateBackgroundLifetime()
            }
            guard content?.receipts.isEmpty == false, libraryTransport.available() else { return }
            receiptReplayOutstanding = Dictionary(grouping: libraryTransport.outstanding().compactMap(WatchContentReceipt.init(dictionary:)),
                                                  by: { $0.file.id })
            while receiptReplayRequested, !Task.isCancelled {
                receiptReplayRequested = false
                guard let receiver = content, libraryTransport.available() else { return }
                await replayContentReceipts(from: receiver)
            }
        }
    }

    private func replayContentReceipts(from receiver: WatchContentReceiver) async {
        let receipts = receiver.receipts
        var revision = receiver.receiptsRevision
        var current = Dictionary(grouping: receipts, by: { $0.file.id })
        for (offset, receipt) in receipts.enumerated() {
            guard !Task.isCancelled, content === receiver, libraryTransport.available() else { return }
            if revision != receiver.receiptsRevision {
                revision = receiver.receiptsRevision
                current = Dictionary(grouping: receiver.receipts, by: { $0.file.id })
            }
            // reconciliation can retire or replace a saved receipt while another batch is suspended.
            if current[receipt.file.id]?.contains(receipt) == true { sendContentReceipt(receipt) }
            if (offset + 1).isMultiple(of: Self.receiptReplayBatchSize) { await Task.yield() }
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
        contentActivity.begin()
        diagnostics.record(.init(kind: .sessionActivationCompleted, id: UUID(), source: .system,
                                 error: error, detail: activationState == .activated ? .activated : .inactive))
        let context = session.receivedApplicationContext
        dispatchHeld { [self] in
            diagnostics.record(.init(kind: .activationChanged, id: UUID(), source: .system,
                                     error: error, detail: activationState == .activated ? .activated : .inactive))
            guard activationState == .activated else { return }
            // the last received library head persists across launches, even
            // when the phone is unavailable
            applyContext(context)
            library.resume()
            content?.resume()
            updateBackgroundLifetime()
            resendContentReceipts()
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
        contentActivity.begin()
        let entered = ProcessInfo.processInfo.systemUptime
        diagnostics.delivery(.contentQueryReceived, file: file, source: .phone)
        dispatchHeld { [self] in
            diagnostics.delivery(.contentQueryHandled, file: file, source: .phone,
                                 elapsed: ProcessInfo.processInfo.systemUptime - entered)
            try? content?.query(file)
        }
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
        let receivedAt = Date()
        let entered = ProcessInfo.processInfo.systemUptime
        if metadata?["kind"] as? String == "watchContentFile",
           let metadata, let contentFile = WatchContentFile(dictionary: metadata) {
            contentActivity.begin()
            diagnostics.delivery(.contentCallbackReceived, file: contentFile, source: .phone, date: receivedAt)
            do {
                try WatchContentReceiver.stage(source, file: contentFile, directory: contentDirectory)
                diagnostics.delivery(.contentStagingCompleted, file: contentFile, source: .cache,
                                     elapsed: ProcessInfo.processInfo.systemUptime - entered)
                let staged = ProcessInfo.processInfo.systemUptime
                dispatchHeld { [self] in
                    diagnostics.delivery(.contentCallbackHandled, file: contentFile, source: .phone,
                                         elapsed: ProcessInfo.processInfo.systemUptime - staged)
                    content?.staged(contentFile)
                }
            } catch {
                diagnostics.delivery(.contentStagingFailed, file: contentFile, source: .cache, error: error,
                                     elapsed: ProcessInfo.processInfo.systemUptime - entered)
                let failed = ProcessInfo.processInfo.systemUptime
                dispatchHeld { [self] in
                    diagnostics.delivery(.contentCallbackHandled, file: contentFile, source: .phone,
                                         elapsed: ProcessInfo.processInfo.systemUptime - failed)
                    content?.stagingFailed(contentFile, error: error)
                }
            }
            return
        }
        if metadata?["kind"] as? String == "watchLibrarySnapshot" {
            contentActivity.begin()
            let callbackID = UUID()
            diagnostics.record(.init(kind: .metadataCallbackReceived, id: callbackID, source: .phone, date: receivedAt))
            do {
                _ = try WatchLibraryReceiver.stage(source, directory: metadataDirectory)
                diagnostics.record(.init(kind: .metadataStagingCompleted, id: callbackID, source: .cache,
                                         elapsed: ProcessInfo.processInfo.systemUptime - entered))
                let staged = ProcessInfo.processInfo.systemUptime
                dispatchHeld { [self] in
                    diagnostics.record(.init(kind: .metadataCallbackHandled, id: callbackID, source: .phone,
                                             elapsed: ProcessInfo.processInfo.systemUptime - staged))
                    library.received()
                }
            } catch {
                diagnostics.record(.init(kind: .metadataStagingFailed, id: callbackID, source: .cache,
                                         elapsed: ProcessInfo.processInfo.systemUptime - entered, error: error))
                let failed = ProcessInfo.processInfo.systemUptime
                dispatchHeld { [self] in
                    diagnostics.record(.init(kind: .metadataCallbackHandled, id: callbackID, source: .phone,
                                             elapsed: ProcessInfo.processInfo.systemUptime - failed))
                    library.failed(error)
                }
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
        contentActivity.begin()
        let entered = ProcessInfo.processInfo.systemUptime
        let head = WatchLibraryHead(context: context)
        let callbackID = head?.publisher ?? UUID()
        let identity = head.map(WatchDiagnosticIdentity.init)
        diagnostics.record(.init(kind: .contextCallbackReceived, id: callbackID, source: .phone, identity: identity))
        dispatchHeld { [self] in
            diagnostics.record(.init(kind: .contextCallbackHandled, id: callbackID, source: .phone,
                                     elapsed: ProcessInfo.processInfo.systemUptime - entered, identity: identity))
            applyContext(context)
        }
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

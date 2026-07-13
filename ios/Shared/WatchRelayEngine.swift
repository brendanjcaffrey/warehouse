import Foundation

/// the phone side of relayed watch sync: takes file requests from the watch
/// and queues watch connectivity transfers for the files already in the
/// phone's library, within a bounded window. files the phone hasn't
/// downloaded itself yet are reported back as failed right away — the watch
/// asks again on a later sync, once the phone has them. keeps no disk state —
/// the watch re-sends its missing list while syncing, and requests are
/// deduped against the system's persisted transfer queue, so a relaunch on
/// either side heals itself
@MainActor
final class WatchRelayEngine {
    struct Config {
        /// how many watch connectivity transfers are kept queued at once
        var maxConcurrentTransfers = 8
    }

    private struct Request {
        let id: String
        var remaining: Set<FileToDownload>
        var failed: Set<FileToDownload>
    }

    private let config: Config
    private let isOnPhone: @MainActor (FileToDownload) -> Bool
    private let transfer: @MainActor (FileToDownload) -> Void
    private let outstandingTransfers: @MainActor () -> Set<FileToDownload>
    private let sendResult: @MainActor (FileResultPayload) -> Void

    private var requests: [Request] = []
    private var pendingTransfer: [FileToDownload] = []
    private var retriesUsed: [FileToDownload: Int] = [:]

    init(
        config: Config = Config(),
        isOnPhone: @escaping @MainActor (FileToDownload) -> Bool,
        transfer: @escaping @MainActor (FileToDownload) -> Void,
        outstandingTransfers: @escaping @MainActor () -> Set<FileToDownload>,
        sendResult: @escaping @MainActor (FileResultPayload) -> Void
    ) {
        self.config = config
        self.isOnPhone = isOnPhone
        self.transfer = transfer
        self.outstandingTransfers = outstandingTransfers
        self.sendResult = sendResult
    }

    /// takes a request from the watch; because the watch re-sends its missing
    /// list, anything already moving through the pipeline is only waited on,
    /// never enqueued twice
    func handle(_ request: FileRequestPayload) {
        let inFlight = Set(pendingTransfer).union(outstandingTransfers())

        var seen = inFlight
        var toTransfer: [FileToDownload] = []
        var notOnPhone: [FileToDownload] = []
        for file in request.files where seen.insert(file).inserted {
            if isOnPhone(file) {
                toTransfer.append(file)
            } else {
                notOnPhone.append(file)
            }
        }

        if request.priority {
            pendingTransfer.insert(contentsOf: toTransfer, at: 0)
        } else {
            pendingTransfer.append(contentsOf: toTransfer)
        }

        requests.append(Request(id: request.id, remaining: Set(request.files), failed: []))
        for file in notOnPhone {
            resolve(file, failed: true)
        }
        flushFinishedRequests()
        pump()
    }

    /// called when a queued transfer completes, including ones left over from
    /// an earlier launch
    func transferDidFinish(file: FileToDownload, error: Error?) {
        if let error {
            if BackgroundDownload.shouldRetry(
                error: error, isOnDisk: false, retriesUsed: retriesUsed[file, default: 0]) {
                retriesUsed[file, default: 0] += 1
                pendingTransfer.append(file)
            } else {
                resolve(file, failed: true)
            }
        } else {
            resolve(file, failed: false)
        }
        pump()
    }

    /// the watch ran out of space; drop everything queued here. the caller
    /// also cancels the transfers the system already owns
    func cancelAll() {
        pendingTransfer = []
        requests = []
        retriesUsed = [:]
    }

    private func pump() {
        while !pendingTransfer.isEmpty, outstandingTransfers().count < config.maxConcurrentTransfers {
            transfer(pendingTransfer.removeFirst())
        }
    }

    private func resolve(_ file: FileToDownload, failed: Bool) {
        retriesUsed[file] = nil
        for index in requests.indices where requests[index].remaining.contains(file) {
            requests[index].remaining.remove(file)
            if failed {
                requests[index].failed.insert(file)
            }
        }
        flushFinishedRequests()
    }

    private func flushFinishedRequests() {
        let finished = requests.filter { $0.remaining.isEmpty }
        guard !finished.isEmpty else { return }
        requests.removeAll { $0.remaining.isEmpty }
        for request in finished {
            sendResult(FileResultPayload(
                requestId: request.id,
                failed: request.failed.sorted { $0.pathKey < $1.pathKey }))
        }
    }
}

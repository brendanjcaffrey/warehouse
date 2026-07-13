import Foundation
import Observation

/// one thing the relay did, for the watch's sync detail feed
struct SyncActivityEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case syncStarted(total: Int)
        case requestedFiles(count: Int)
        case nudgedPhone(count: Int)
        case backgroundNudge(count: Int)
        case libraryReceived
        case fileReceived(name: String)
        case fileFailed(name: String)
        case filesFailed(count: Int)
        case outOfSpace
        case stalled
        case phoneReachable(Bool)
        case syncFinished(completed: Int, failed: Int)
    }

    enum Tone: Equatable, Sendable {
        case normal
        case good
        case warning
        case bad
    }

    let id: UUID
    let at: Date
    let kind: Kind

    init(id: UUID = UUID(), at: Date, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

extension SyncActivityEvent.Kind {
    var message: String {
        switch self {
        case .syncStarted(let total):
            return "Syncing \(total) \(Self.files(total))"
        case .requestedFiles(let count):
            return "Asked iPhone for \(count) \(Self.files(count))"
        case .nudgedPhone(let count):
            return "Asking iPhone again for \(count) \(Self.files(count))"
        case .backgroundNudge(let count):
            return "Background check: \(count) \(Self.files(count)) still missing"
        case .libraryReceived:
            return "Received library"
        case .fileReceived(let name):
            return "Received \(name)"
        case .fileFailed(let name):
            return "iPhone doesn't have \(name)"
        case .filesFailed(let count):
            return "iPhone couldn't send \(count) \(Self.files(count))"
        case .outOfSpace:
            return "Out of space on this watch"
        case .stalled:
            return "Gave up waiting for the iPhone"
        case .phoneReachable(let reachable):
            return reachable ? "iPhone reachable" : "iPhone out of range"
        case .syncFinished(let completed, let failed):
            if failed > 0 {
                return "Finished: \(completed) downloaded, \(failed) failed"
            }
            return "Finished: \(completed) downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .syncStarted:
            return "arrow.trianglehead.2.clockwise"
        case .requestedFiles, .nudgedPhone, .backgroundNudge:
            return "arrow.up.circle"
        case .libraryReceived, .fileReceived:
            return "checkmark.circle"
        case .fileFailed, .filesFailed:
            return "xmark.circle"
        case .outOfSpace:
            return "externaldrive.badge.exclamationmark"
        case .stalled:
            return "clock.badge.exclamationmark"
        case .phoneReachable(let reachable):
            return reachable ? "iphone.radiowaves.left.and.right" : "iphone.slash"
        case .syncFinished:
            return "checkmark.circle.fill"
        }
    }

    var tone: SyncActivityEvent.Tone {
        switch self {
        case .syncStarted, .requestedFiles, .nudgedPhone, .backgroundNudge:
            return .normal
        case .libraryReceived, .fileReceived:
            return .good
        case .fileFailed, .filesFailed:
            return .warning
        case .outOfSpace, .stalled:
            return .bad
        case .phoneReachable(let reachable):
            return reachable ? .good : .warning
        case .syncFinished(_, let failed):
            return failed > 0 ? .warning : .good
        }
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }
}

/// a rolling record of what the phone relay is doing, so the watch can show
/// that a quiet sync is still alive rather than just a stalled spinner. owned
/// for the life of the app, so the feed survives a sync ending & keeps
/// filling while files land in the background
@MainActor
@Observable
final class SyncActivityLog {
    enum RequestReason: Equatable, Sendable {
        case initial
        case nudge
        case background
    }

    /// what the heartbeat line is built from
    struct Status: Equatable, Sendable {
        let isPhoneReachable: Bool
        /// nil until a file has ever arrived
        let sinceLastFile: TimeInterval?
        /// nil when no download is outstanding
        let untilNextNudge: TimeInterval?
    }

    nonisolated static let defaultCapacity = 50

    /// newest first
    private(set) var events: [SyncActivityEvent] = []
    private(set) var isPhoneReachable = false
    private(set) var isDownloading = false
    private(set) var lastArrivalAt: Date?
    private(set) var lastRequestAt: Date?

    private let now: () -> Date
    private let capacity: Int
    private let describe: (FileToDownload) -> String

    init(
        now: @escaping () -> Date = Date.init,
        capacity: Int = SyncActivityLog.defaultCapacity,
        describe: @escaping (FileToDownload) -> String = { $0.filename }
    ) {
        self.now = now
        self.capacity = capacity
        self.describe = describe
    }

    func startedSync(total: Int) {
        isDownloading = true
        record(.syncStarted(total: total))
    }

    func requested(count: Int, reason: RequestReason) {
        lastRequestAt = now()
        switch reason {
        case .initial:
            record(.requestedFiles(count: count))
        case .nudge:
            record(.nudgedPhone(count: count))
        case .background:
            record(.backgroundNudge(count: count))
        }
    }

    func receivedLibrary() {
        record(.libraryReceived)
    }

    func received(_ file: FileToDownload) {
        lastArrivalAt = now()
        record(.fileReceived(name: describe(file)))
    }

    func failed(_ file: FileToDownload) {
        record(.fileFailed(name: describe(file)))
    }

    /// one line for a batch the phone reported it couldn't send, rather than
    /// flooding the feed with a line per file
    func failed(_ files: [FileToDownload]) {
        guard !files.isEmpty else { return }
        if files.count == 1, let file = files.first {
            failed(file)
        } else {
            record(.filesFailed(count: files.count))
        }
    }

    func outOfSpace() {
        record(.outOfSpace)
    }

    func stalled() {
        record(.stalled)
    }

    func finishedSync(_ progress: DownloadProgress) {
        isDownloading = false
        if progress.outOfSpace {
            record(.outOfSpace)
        } else {
            record(.syncFinished(completed: progress.completed, failed: progress.failed))
        }
    }

    /// reachability flaps every time the phone app leaves the foreground, so
    /// only transitions are worth a line; otherwise the feed is nothing else
    func phoneReachabilityChanged(to reachable: Bool) {
        guard reachable != isPhoneReachable else { return }
        isPhoneReachable = reachable
        record(.phoneReachable(reachable))
    }

    func clear() {
        events.removeAll()
    }

    func status(now: Date) -> Status {
        Status(
            isPhoneReachable: isPhoneReachable,
            sinceLastFile: SyncActivityFormatting.sinceLastFile(lastArrivalAt: lastArrivalAt, now: now),
            untilNextNudge: SyncActivityFormatting.untilNextNudge(
                lastRequestAt: lastRequestAt, isDownloading: isDownloading, now: now))
    }

    private func record(_ kind: SyncActivityEvent.Kind) {
        events.insert(SyncActivityEvent(at: now(), kind: kind), at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }
}

import Foundation
import Observation

/// one thing the bundle downloader did, for the watch's sync detail feed
struct SyncActivityEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case syncStarted(total: Int)
        case libraryReceived
        case requestedBundle(type: LibraryFileType, count: Int)
        case bundleRegistered
        case downloadedBundle
        case fileReceived(name: String)
        case bundleExtracted(type: LibraryFileType, count: Int)
        case bundleFailed(reason: String)
        case outOfSpace
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
        case .libraryReceived:
            return "Received library"
        case .requestedBundle(let type, let count):
            return "Requested a bundle of \(count) \(Self.noun(type, count))"
        case .bundleRegistered:
            return "Server prepared the bundle"
        case .downloadedBundle:
            return "Bundle downloaded, unpacking"
        case .fileReceived(let name):
            return "Received \(name)"
        case .bundleExtracted(let type, let count):
            return "Unpacked \(count) \(Self.noun(type, count))"
        case .bundleFailed(let reason):
            return "Bundle failed: \(reason)"
        case .outOfSpace:
            return "Out of space on this watch"
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
        case .requestedBundle:
            return "arrow.up.circle"
        case .bundleRegistered:
            return "shippingbox"
        case .downloadedBundle:
            return "arrow.down.circle"
        case .libraryReceived, .fileReceived, .bundleExtracted:
            return "checkmark.circle"
        case .bundleFailed:
            return "xmark.circle"
        case .outOfSpace:
            return "externaldrive.badge.exclamationmark"
        case .syncFinished:
            return "checkmark.circle.fill"
        }
    }

    var tone: SyncActivityEvent.Tone {
        switch self {
        case .syncStarted, .requestedBundle, .bundleRegistered, .downloadedBundle:
            return .normal
        case .libraryReceived, .fileReceived, .bundleExtracted:
            return .good
        case .bundleFailed:
            return .warning
        case .outOfSpace:
            return .bad
        case .syncFinished(_, let failed):
            return failed > 0 ? .warning : .good
        }
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    private static func noun(_ type: LibraryFileType, _ count: Int) -> String {
        switch type {
        case .music: return count == 1 ? "song" : "songs"
        case .artwork: return count == 1 ? "artwork file" : "artwork files"
        }
    }
}

/// a rolling record of what the bundle downloader is doing, so the watch can
/// show that a quiet overnight sync is still alive rather than just a stalled
/// spinner. owned for the life of the app, so the feed survives a sync ending
/// & keeps filling while bundles land in the background
@MainActor
@Observable
final class SyncActivityLog {
    /// what the heartbeat line is built from
    struct Status: Equatable, Sendable {
        /// nil until a file has ever arrived
        let sinceLastFile: TimeInterval?
        let isDownloading: Bool
    }

    nonisolated static let defaultCapacity = 50

    /// newest first
    private(set) var events: [SyncActivityEvent] = []
    private(set) var isDownloading = false
    private(set) var lastArrivalAt: Date?

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

    func receivedLibrary() {
        record(.libraryReceived)
    }

    func requestedBundle(type: LibraryFileType, count: Int) {
        record(.requestedBundle(type: type, count: count))
    }

    func bundleRegistered() {
        record(.bundleRegistered)
    }

    func downloadedBundle() {
        record(.downloadedBundle)
    }

    /// music arrivals get a line per song; artwork lands a thousand at a time,
    /// so only the per-bundle summary is worth a line
    func extracted(_ files: [FileToDownload], type: LibraryFileType) {
        lastArrivalAt = now()
        if type == .music {
            for file in files {
                record(.fileReceived(name: describe(file)))
            }
        }
        record(.bundleExtracted(type: type, count: files.count))
    }

    func bundleFailed(reason: String) {
        record(.bundleFailed(reason: reason))
    }

    func outOfSpace() {
        record(.outOfSpace)
    }

    func finishedSync(_ progress: DownloadProgress) {
        isDownloading = false
        if progress.outOfSpace {
            record(.outOfSpace)
        } else {
            record(.syncFinished(completed: progress.completed, failed: progress.failed))
        }
    }

    func clear() {
        events.removeAll()
    }

    func status(now: Date) -> Status {
        Status(
            sinceLastFile: SyncActivityFormatting.sinceLastFile(lastArrivalAt: lastArrivalAt, now: now),
            isDownloading: isDownloading)
    }

    private func record(_ kind: SyncActivityEvent.Kind) {
        events.insert(SyncActivityEvent(at: now(), kind: kind), at: 0)
        if events.count > capacity {
            events.removeLast(events.count - capacity)
        }
    }
}

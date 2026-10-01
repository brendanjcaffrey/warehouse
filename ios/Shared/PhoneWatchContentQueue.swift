import Foundation
import Observation

/// intent, transfer ownership and verified delivery survive independently.
@MainActor
@Observable
final class PhoneWatchContentQueue {
    struct Transport {
        var available: () -> Bool
        var outstanding: () -> [WatchContentFile]
        var enqueue: (WatchContentFile, URL) -> Void
        var cancel: (UUID) -> Void
        var query: (WatchContentFile) -> Void
        var report: (WatchLibraryDeliveryReport) -> Void = { _ in }
    }

    struct Job: Codable {
        let type: LibraryFileType
        let filename: String
        var file: WatchContentFile?
        var status: WatchContentStatus = .pending
        var attempts = 0
        var nextAttempt = Date.distantPast
    }

    private struct Saved: Codable {
        var head: WatchLibraryHead?
        var jobs: [Job] = []
        var snapshot: WatchLibrarySnapshot?
        var report: WatchLibraryDeliveryReport?
    }

    static let maximumTransfers = 4
    private let fileStore: FileStore
    private let directory: URL
    private let transport: Transport
    private let now: () -> Date
    private let schedulesRetries: Bool
    private var saved: Saved
    private var timer: Task<Void, Never>?
    private(set) var errorMessage: String?
    var jobs: [Job] { saved.jobs }

    init(fileStore: FileStore, directory: URL = defaultDirectory(), transport: Transport,
         now: @escaping () -> Date = { Date() }, schedulesRetries: Bool = true) throws {
        self.fileStore = fileStore
        self.directory = directory
        self.transport = transport
        self.now = now
        self.schedulesRetries = schedulesRetries
        let url = directory.appending(path: "state.json")
        saved = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url)) : Saved()
        try save()
    }

    nonisolated static func defaultDirectory() -> URL { URL.applicationSupportDirectory.appending(path: "watch-content-queue") }

    /// invalidate immediately on configuration change, before the asynchronous metadata read.
    func invalidate(identity: String?, playlistIDs: [String]) throws {
        guard saved.head?.libraryID != identity || saved.head?.playlistIDs != playlistIDs else { return }
        try reconcile(head: nil, snapshot: nil)
    }

    func reconcile(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) throws {
        if saved.head != head {
            let old = saved.jobs.compactMap(\.file)
            saved = Saved(head: head)
            try save()
            old.forEach { transport.cancel($0.id) }
        }
        if let snapshot, snapshot.head == head {
            _ = try snapshot.validatedLibrary()
            saved.snapshot = snapshot
            try save()
        }
        if saved.jobs.isEmpty, let snapshot, snapshot.head == head {
            _ = try snapshot.validatedLibrary()
            saved.jobs = try snapshot.music.sorted().map { Job(type: .music, filename: $0) }
                + snapshot.artwork.sorted().map { Job(type: .artwork, filename: $0) }
            try save()
        }
        try pump()
    }

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        WatchLibraryProgress.make(head: saved.head, snapshot: saved.snapshot, playlistID: playlistID) { type, name in
            guard let job = saved.jobs.first(where: { $0.type == type && $0.filename == name }) else { return .pending }
            if job.file == nil && !fileStore.exists(type, name) { return .missingOnPhone }
            return job.status
        }
    }

    func receive(_ receipt: WatchContentReceipt) throws {
        guard let index = saved.jobs.firstIndex(where: { $0.file == receipt.file }), saved.head == receipt.file.head,
              [.delivered, .retrying, .storageFull, .failed].contains(receipt.status) else { return }
        if saved.jobs[index].status == .delivered { return }
        if saved.jobs[index].status == .failed && receipt.status != .delivered { return }
        saved.jobs[index].status = receipt.status
        if receipt.status == .retrying || receipt.status == .storageFull {
            saved.jobs[index].nextAttempt = now().addingTimeInterval(backoff(saved.jobs[index].attempts))
        }
        try save()
        try pump()
    }

    func finished(_ file: WatchContentFile, error: Error?) throws {
        guard let index = saved.jobs.firstIndex(where: { $0.file == file }),
              ![.delivered, .failed, .storageFull, .retrying].contains(saved.jobs[index].status) else {
            try pump(); return
        }
        if let error {
            saved.jobs[index].status = Self.isPermanent(error) ? .failed : .retrying
            saved.jobs[index].nextAttempt = now().addingTimeInterval(backoff(saved.jobs[index].attempts))
        } else {
            saved.jobs[index].status = .awaitingReceipt
            saved.jobs[index].nextAttempt = .distantPast
        }
        try save()
        try pump()
    }

    func update(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) {
        do { try reconcile(head: head, snapshot: snapshot); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    func resume() {
        do { try pump(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    private static func isPermanent(_ error: Error) -> Bool {
        if error is FileStore.FilenameError || error is WatchLibraryError { return true }
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code)
    }

    private func backoff(_ attempts: Int) -> TimeInterval { min(3600, 5 * pow(2, Double(min(attempts, 10)))) }
    private func source(_ file: WatchContentFile) -> URL { directory.appending(path: file.id.uuidString) }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: directory.appending(path: "state.json"), options: .atomic)
    }

    private func pump() throws {
        timer?.cancel()
        guard transport.available() else { try publishReport(); return }
        let outstanding = transport.outstanding()
        let systemIDs = Set(outstanding.map(\.id))
        // source copies may be removed only after the system relinquishes them.
        let needed = Set(saved.jobs.filter { $0.status != .delivered && $0.status != .failed }.compactMap { $0.file?.id })
            .union(systemIDs)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), !needed.contains(id) { try FileManager.default.removeItem(at: url) }
        }
        var occupied = outstanding.count + saved.jobs.filter {
            [.transferring, .awaitingReceipt].contains($0.status) && $0.file.map { !systemIDs.contains($0.id) } == true
        }.count
        for index in saved.jobs.indices {
            var job = saved.jobs[index]
            guard job.status != .delivered, job.status != .failed else { continue }
            if let file = job.file, systemIDs.contains(file.id) {
                if ![.storageFull, .retrying].contains(job.status) { job.status = .transferring }
                saved.jobs[index] = job
                continue
            }
            if job.status == .transferring { job.status = .awaitingReceipt; job.nextAttempt = .distantPast }
            if job.status == .awaitingReceipt {
                if job.nextAttempt <= now(), let file = job.file {
                    job.nextAttempt = now().addingTimeInterval(60)
                    saved.jobs[index] = job
                    try save()
                    transport.query(file)
                }
                saved.jobs[index] = job
                continue
            }
            guard occupied < Self.maximumTransfers, job.nextAttempt <= now(), let head = saved.head,
                  head.metadataReady, head.failed != true, head.libraryID != nil else { continue }
            do {
                if job.file == nil {
                    let original = fileStore.fileURL(job.type, job.filename)
                    guard fileStore.exists(job.type, job.filename) else {
                        job.status = .missingOnPhone
                        job.nextAttempt = now().addingTimeInterval(60)
                        saved.jobs[index] = job
                        continue
                    }
                    let id = UUID()
                    let copy = directory.appending(path: id.uuidString)
                    try FileManager.default.copyItem(at: original, to: copy)
                    let fingerprint = try WatchContentFile.fingerprint(copy)
                    let file = WatchContentFile(id: id, head: head, type: job.type, filename: job.filename,
                                                bytes: fingerprint.bytes, digest: fingerprint.digest)
                    try file.validate()
                    job.file = file
                }
                guard let file = job.file else { continue }
                job.attempts += 1
                job.status = .transferring
                saved.jobs[index] = job
                // the write precedes enqueue, so interrupted enqueue is recovered by a receipt query.
                try save()
                transport.enqueue(file, source(file))
                occupied += 1
            } catch {
                job.status = Self.isPermanent(error) ? .failed : .retrying
                job.attempts += 1
                job.nextAttempt = now().addingTimeInterval(backoff(job.attempts))
                saved.jobs[index] = job
                errorMessage = error.localizedDescription
            }
        }
        try save()
        try publishReport()
        schedule()
    }

    private func publishReport() throws {
        guard let head = saved.head, saved.snapshot?.head == head else { return }
        let overall = progress()
        let playlists = Dictionary(uniqueKeysWithValues: head.playlistIDs.map { ($0, progress(playlistID: $0)) })
        if saved.report?.head != head || saved.report?.overall != overall || saved.report?.playlists != playlists {
            let sequence = (saved.report?.sequence ?? 0) + 1
            saved.report = WatchLibraryDeliveryReport(head: head, sequence: sequence, overall: overall, playlists: playlists)
            try save()
        }
        if let report = saved.report { transport.report(report) }
    }

    private func schedule() {
        guard schedulesRetries else { return }
        let waiting = saved.jobs.filter { [.awaitingReceipt, .retrying, .missingOnPhone, .storageFull].contains($0.status) }
        guard !waiting.isEmpty else { return }
        // due retries blocked by occupied slots wait for completion or a later wakeup, never a one-second loop.
        let next = waiting.map(\.nextAttempt).filter { $0 > now() }.min() ?? now().addingTimeInterval(60)
        let delay = max(1, next.timeIntervalSince(now()))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.resume()
        }
    }
}

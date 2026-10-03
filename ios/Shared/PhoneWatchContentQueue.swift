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
        var inventory: (WatchInventoryRequest) -> Void = { _ in }
    }

    struct Job: Codable {
        let type: LibraryFileType
        let filename: String
        var file: WatchContentFile?
        var status: WatchContentStatus = .pending
        var attempts = 0
        var nextAttempt = Date.distantPast
        var inventoryRequestID: UUID?
    }

    private struct Saved: Codable {
        var head: WatchLibraryHead?
        var jobs: [Job] = []
        var snapshot: WatchLibrarySnapshot?
        var report: WatchLibraryDeliveryReport?
        var inventory: WatchInventoryRequest?
        var inventoryNextAttempt: Date?
        var inventoryCompletedAt: Date?
        var inventoryStartedAt: Date?
    }

    static let maximumTransfers = 4
    private let diagnostics: WatchDiagnostics
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
         now: @escaping () -> Date = { Date() }, schedulesRetries: Bool = true, diagnostics: WatchDiagnostics? = nil) throws {
        self.diagnostics = diagnostics ?? .shared
        self.fileStore = fileStore
        self.directory = directory
        self.transport = transport
        self.now = now
        self.schedulesRetries = schedulesRetries
        let url = directory.appending(path: "state.json")
        saved = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url)) : Saved()
        if saved.inventoryStartedAt == nil {
            // older queues already sent pending challenges; start their daily limit conservatively on upgrade.
            saved.inventoryStartedAt = saved.inventory != nil && saved.inventoryNextAttempt != .distantPast ? now() : saved.inventoryCompletedAt
        }
        try save()
    }

    nonisolated static func defaultDirectory() -> URL { URL.applicationSupportDirectory.appending(path: "watch-content-queue") }

    /// invalidate immediately on configuration change, before the asynchronous metadata read.
    func invalidate(identity: String?, playlistIDs: [String]) throws {
        guard saved.head?.libraryID != identity || saved.head?.playlistIDs != playlistIDs else { return }
        guard let head = saved.head, let identity, identity == head.libraryID, !playlistIDs.isEmpty else {
            try reconcile(head: nil, snapshot: nil)
            return
        }
        // pause obsolete transfers while preserving receipts until the new selection's inventory arrives.
        var pending = WatchLibraryHead(publisher: head.publisher, revision: head.revision,
                                       libraryID: identity, playlistIDs: playlistIDs)
        pending.version = head.version
        try reconcile(head: pending, snapshot: nil)
    }

    func reconcile(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) throws {
        let snapshot = snapshot?.head == head ? snapshot : nil
        if let snapshot { _ = try snapshot.validatedLibrary() }
        if saved.head != head {
            let old = saved.jobs.compactMap(\.file)
            // exported filenames identify content; a metadata revision does not revoke verified watch storage.
            let retainsDelivery = head?.libraryID != nil && head?.libraryID == saved.head?.libraryID
                && head?.publisher == saved.head?.publisher && head?.version == saved.head?.version
                && (head?.revision ?? 0) >= (saved.head?.revision ?? 0)
            saved = Saved(head: head, jobs: retainsDelivery ? saved.jobs.filter { $0.status == .delivered } : [],
                          snapshot: retainsDelivery ? saved.snapshot : nil, inventoryStartedAt: saved.inventoryStartedAt)
            for index in saved.jobs.indices { saved.jobs[index].inventoryRequestID = nil }
            try save()
            old.forEach { transport.cancel($0.id) }
        }
        if let snapshot {
            let previous = Dictionary(grouping: saved.jobs, by: \.type).mapValues {
                Dictionary($0.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
            }
            saved.snapshot = snapshot
            saved.jobs = try snapshot.music.sorted().map { previous[.music]?[$0] ?? Job(type: .music, filename: $0) }
                + snapshot.artwork.sorted().map { previous[.artwork]?[$0] ?? Job(type: .artwork, filename: $0) }
            try save()
        }
        try beginInventory()
        try pump()
    }

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        WatchLibraryProgress.make(head: saved.head, snapshot: saved.snapshot, playlistID: playlistID) { type, name in
            guard let job = saved.jobs.first(where: { $0.type == type && $0.filename == name }) else { return .pending }
            if job.file == nil && !fileStore.exists(type, name) { return .missingOnPhone }
            return job.status
        }
    }

    func diagnosticState() -> WatchDeliveryDiagnosticState {
        var state = WatchDeliveryDiagnosticState(peer: .phone)
        state.head = saved.head.map(WatchDiagnosticIdentity.init)
        state.inventoryHead = saved.snapshot.map { WatchDiagnosticIdentity($0.head) }
        state.transportAvailable = transport.available()
        state.systemOutstanding = transport.outstanding().count
        state.receiptWait = saved.jobs.count { $0.status == .awaitingReceipt }
        state.inventoryPending = saved.jobs.count { $0.inventoryRequestID != nil }
        state.inventoryRequestID = saved.inventory?.id
        state.inventoryCompletedAt = saved.inventoryCompletedAt
        state.inventoryStartedAt = saved.inventoryStartedAt
        state.inventoryEligibleAt = saved.inventoryStartedAt?.addingTimeInterval(WatchInventoryRequest.minimumInterval)
        state.availableBytes = FileStore.deviceStorage()?.availableBytes
        let jobDeadlines = saved.jobs.filter {
            [.awaitingReceipt, .retrying, .storageFull, .missingOnPhone].contains($0.status)
        }.map(\.nextAttempt)
        state.nextAttemptAt = (jobDeadlines + [saved.inventoryNextAttempt].compactMap { $0 }).min()
        let entries = Dictionary(uniqueKeysWithValues: LibraryFileType.allCases.map { type in
            (type, Dictionary(fileStore.entries(type).map { ($0.filename, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first }))
        })
        for job in saved.jobs {
            let bytes = job.file?.bytes ?? entries[job.type]?[job.filename]
            let status: WatchContentStatus = job.file == nil && !fileStore.exists(job.type, job.filename) ? .missingOnPhone : job.status
            state.add(type: job.type, status: status, bytes: bytes)
        }
        return state
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
        diagnostics.delivery(receipt.status == .delivered ? .phoneAcknowledged : Self.event(receipt.status),
                             file: receipt.file, source: .phone, status: receipt.status)
        try pump()
    }

    private static func event(_ status: WatchContentStatus) -> WatchDiagnostic.Kind {
        switch status {
        case .storageFull: .contentStorageFull
        case .failed: .contentFailed
        default: .contentRetry
        }
    }

    func finished(_ file: WatchContentFile, error: Error?) throws {
        diagnostics.delivery(error == nil ? .contentCompleted : .contentTransferFailed, file: file, source: .system, error: error)
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
        if let error {
            diagnostics.delivery(Self.event(saved.jobs[index].status), file: file, source: .system,
                                 status: saved.jobs[index].status, error: error)
        }
        try pump()
    }

    func update(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) {
        do { try reconcile(head: head, snapshot: snapshot); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    func resume() {
        do { try pump(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    func requestInventory() {
        do { try beginInventory(); try pump(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    private func beginInventory() throws {
        guard saved.inventory == nil, let head = saved.head, saved.snapshot?.head == head,
              head.metadataReady, head.failed != true, saved.jobs.contains(where: { $0.status == .delivered }) else { return }
        if let started = saved.inventoryStartedAt, now() < started.addingTimeInterval(WatchInventoryRequest.minimumInterval) { return }
        let request = WatchInventoryRequest(head: head)
        for index in saved.jobs.indices where saved.jobs[index].status == .delivered {
            saved.jobs[index].inventoryRequestID = request.id
        }
        saved.inventory = request
        saved.inventoryNextAttempt = .distantPast
        try save()
    }

    func receive(_ report: WatchInventoryReport) throws {
        guard report.isValid, report.request == saved.inventory, report.request.head == saved.head else {
            diagnostics.metadata(.inventoryRejected, head: report.request.head)
            return
        }
        let entries = Dictionary(grouping: report.entries, by: \.type).mapValues {
            Dictionary($0.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var events = [(WatchDiagnostic.Kind, WatchContentFile)]()
        var cancelled = [UUID]()
        for index in saved.jobs.indices {
            let job = saved.jobs[index]
            guard job.inventoryRequestID == report.request.id, let entry = entries[job.type]?[job.filename] else { continue }
            saved.jobs[index].inventoryRequestID = nil
            guard job.status == .delivered, let file = job.file else { continue }
            if entry.bytes == file.bytes {
                events.append((.inventoryConfirmed, file))
            } else {
                // a fresh transfer identity prevents old receipts from resurrecting the missing file.
                saved.jobs[index] = Job(type: job.type, filename: job.filename)
                cancelled.append(file.id)
                events.append((.inventoryMissing, file))
            }
        }
        let complete = !saved.jobs.contains { $0.inventoryRequestID == report.request.id }
        if complete {
            saved.inventory = nil
            saved.inventoryNextAttempt = nil
            saved.inventoryCompletedAt = now()
        }
        try save()
        cancelled.forEach { transport.cancel($0) }
        for (kind, file) in events {
            diagnostics.record(.init(kind: kind, id: file.id, source: .phone, fileType: file.type,
                                     bytes: file.bytes, identity: WatchDiagnosticIdentity(report.request.head)))
        }
        if complete { diagnostics.metadata(.inventoryCompleted, head: report.request.head) }
        try pump()
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
        diagnostics.record(.init(kind: .queueWakeup, id: saved.head?.publisher ?? UUID(), source: .system,
                                 identity: saved.head.map(WatchDiagnosticIdentity.init)))
        timer?.cancel()
        guard transport.available() else { try publishReport(); return }
        if let request = saved.inventory, (saved.inventoryNextAttempt ?? .distantPast) <= now() {
            if saved.inventoryNextAttempt == .distantPast { saved.inventoryStartedAt = now() }
            saved.inventoryNextAttempt = now().addingTimeInterval(60)
            try save()
            diagnostics.record(.init(kind: .inventoryRequested, id: request.id, source: .phone,
                                     identity: WatchDiagnosticIdentity(request.head)))
            transport.inventory(request)
        }
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
                    diagnostics.delivery(.receiptQuery, file: file, source: .phone)
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
                diagnostics.delivery(.contentEnqueued, file: file, source: .phone, status: .transferring)
                occupied += 1
            } catch {
                job.status = Self.isPermanent(error) ? .failed : .retrying
                job.attempts += 1
                job.nextAttempt = now().addingTimeInterval(backoff(job.attempts))
                saved.jobs[index] = job
                errorMessage = error.localizedDescription
                if let file = job.file {
                    diagnostics.delivery(Self.event(job.status), file: file, source: .phone, status: job.status, error: error)
                } else {
                    diagnostics.record(.init(kind: Self.event(job.status), id: head.publisher, source: .phone,
                                             fileType: job.type, error: error, identity: WatchDiagnosticIdentity(head), status: job.status))
                }
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
        guard !waiting.isEmpty || saved.inventory != nil else { return }
        // due retries blocked by occupied slots wait for completion or a later wakeup, never a one-second loop.
        let deadlines = waiting.map(\.nextAttempt) + [saved.inventoryNextAttempt].compactMap { $0 }
        let next = deadlines.filter { $0 > now() }.min() ?? now().addingTimeInterval(60)
        let delay = max(1, next.timeIntervalSince(now()))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.resume()
        }
    }
}

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
        var inventoryCompletion: (WatchInventoryCompletion) -> Void = { _ in }
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
        var manualRequest: WatchInventoryRequest?
        var manualCompleted: Bool?
        var recoveryFiles: [WatchContentFile]?
        var unidentifiedSources: [UUID]?
    }

    static let maximumTransfers = 4
    private let diagnostics: WatchDiagnostics
    private let fileStore: FileStore
    private let directory: URL
    private let transport: Transport
    private let now: () -> Date
    private let state: WatchDeliveryState
    let recoveredState: Bool
    private let schedulesRetries: Bool
    private var saved: Saved
    private var timer: Task<Void, Never>?
    private let worker: WatchContentWorker
    private var generation = UUID()
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var preparationSources: [UUID: UUID] = [:]
    private var preparingNames: [UUID: String] = [:]

    private var inventoryWork: Task<Void, Never>?
    private var inventoryReports: [WatchInventoryReport] = []

    func waitForWork() async {
        while !preparations.isEmpty || inventoryWork != nil {
            if let task = preparations.values.first { await task.value }
            if let task = inventoryWork { await task.value }
        }
    }
    private(set) var errorMessage: String?
    var jobs: [Job] { saved.jobs }

    init(fileStore: FileStore, directory: URL = defaultDirectory(), transport: Transport,
         now: @escaping () -> Date = { Date() }, schedulesRetries: Bool = true, diagnostics: WatchDiagnostics? = nil,
         state: WatchDeliveryState = .init(), worker: WatchContentWorker = WatchContentWorker()) throws {
        self.diagnostics = diagnostics ?? .shared
        self.fileStore = fileStore
        self.directory = directory
        self.transport = transport
        self.now = now
        self.state = state
        self.worker = worker
        self.schedulesRetries = schedulesRetries
        let url = directory.appending(path: "state.json")
        let loaded = try state.load(Saved.self, from: url, empty: Saved())
        saved = loaded.value
        recoveredState = loaded.repaired
        if loaded.repaired {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            saved.recoveryFiles = try Self.recoverSources(directory: directory, urls: urls,
                                                         outstanding: transport.outstanding(), state: state)
            let known = Set(saved.recoveryFiles?.map(\.id) ?? [])
            // older copies without a surviving descriptor remain intact; never guess their filename or ownership.
            saved.unidentifiedSources = urls.compactMap { UUID(uuidString: $0.lastPathComponent) }.filter { !known.contains($0) }
            saved.inventoryStartedAt = now()
        }
        if saved.inventoryStartedAt == nil {
            // older queues already sent pending challenges; start their daily limit conservatively on upgrade.
            let startedAutomatic = saved.inventory?.isManual == false && saved.inventoryNextAttempt != .distantPast
            saved.inventoryStartedAt = startedAutomatic ? now() : (saved.manualRequest == nil ? saved.inventoryCompletedAt : nil)
        }
        // migrate existing private copies to independent descriptors before their central journal can be lost.
        for file in saved.jobs.compactMap(\.file) where FileManager.default.fileExists(atPath: source(file).path) {
            try state.save(file, to: directory.appending(path: "\(file.id.uuidString).json"))
        }
        try save()
    }

    private static func recoverSources(directory: URL, urls: [URL], outstanding: [WatchContentFile],
                                       state: WatchDeliveryState) throws -> [WatchContentFile] {
        let descriptors = try urls.filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }.compactMap { url -> WatchContentFile? in
            let data: Data
            do { data = try state.read(url) } catch {
                if WatchDeliveryState.isMissing(error) { return nil }
                throw error
            }
            return try? JSONDecoder().decode(WatchContentFile.self, from: data)
        }
        // descriptors are candidates; verification runs on the worker before their bytes are reused.
        let candidates = (outstanding + descriptors).filter { (try? $0.validate()) != nil }
        return Array(Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
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
        if saved.head != head || (snapshot != nil && snapshot != saved.snapshot) {
            generation = UUID()
            preparations.values.forEach { $0.cancel() }
        }
        if saved.head != head {
            let old = saved.jobs.compactMap(\.file)
            // exported filenames identify content; a metadata revision does not revoke verified watch storage.
            let retainsDelivery = head?.libraryID != nil && head?.libraryID == saved.head?.libraryID
                && head?.publisher == saved.head?.publisher && head?.version == saved.head?.version
                && (head?.revision ?? 0) >= (saved.head?.revision ?? 0)
            saved = Saved(head: head, jobs: retainsDelivery ? saved.jobs.filter { $0.status == .delivered } : [],
                          snapshot: retainsDelivery ? saved.snapshot : nil, inventoryStartedAt: saved.inventoryStartedAt,
                          manualRequest: saved.manualRequest, manualCompleted: nil,
                          recoveryFiles: saved.recoveryFiles, unidentifiedSources: saved.unidentifiedSources)
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
            let desired = Dictionary(grouping: saved.jobs, by: \.type).mapValues { Set($0.map(\.filename)) }
            saved.recoveryFiles = saved.recoveryFiles?.filter {
                $0.head.libraryID == head?.libraryID && desired[$0.type]?.contains($0.filename) == true
            }
            try save()
        }
        try beginInventory()
        try pump()
    }

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        WatchLibraryProgress.make(head: saved.head, snapshot: saved.snapshot, playlistID: playlistID) { type, name in
            guard let job = saved.jobs.first(where: { $0.type == type && $0.filename == name }) else { return .pending }
            if job.file == nil && !fileStore.exists(type, name),
               saved.recoveryFiles?.contains(where: {
                   $0.type == type && $0.filename == name && $0.head.libraryID == saved.head?.libraryID
               }) != true {
                return .missingOnPhone
            }
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
        let previous = saved
        saved.jobs[index].status = receipt.status
        if receipt.status == .delivered, saved.inventory?.isManual == true { saved.jobs[index].inventoryRequestID = nil }
        if receipt.status == .retrying || receipt.status == .storageFull {
            saved.jobs[index].nextAttempt = now().addingTimeInterval(backoff(saved.jobs[index].attempts))
        }
        do { try save() } catch { saved = previous; throw error }
        diagnostics.delivery(receipt.status == .delivered ? .phoneAcknowledged : Self.event(receipt.status),
                             file: receipt.file, source: .phone, status: receipt.status)
        if let request = saved.inventory, request.isManual { try finishInventoryIfNeeded(request) }
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

    func receive(_ request: WatchInventoryRequest) throws {
        guard request.isValid, request.isManual, request.head == saved.head, saved.snapshot?.head == request.head else { return }
        if request == saved.manualRequest {
            if saved.manualCompleted == true { transport.inventoryCompletion(.init(request: request)) } else if saved.inventory == request {
                try finishInventoryIfNeeded(request)
                try pump()
            }
            return
        }
        if let previous = saved.manualRequest,
           (previous.manualSequence ?? 0) >= (request.manualSequence ?? 0) { return }
        let previous = saved
        saved.manualRequest = request
        saved.manualCompleted = false
        saved.inventory = request
        saved.inventoryNextAttempt = .distantPast
        for index in saved.jobs.indices { saved.jobs[index].inventoryRequestID = request.id }
        do { try save() } catch { saved = previous; throw error }
        generation = UUID()
        preparations.values.forEach { $0.cancel() }
        try finishInventoryIfNeeded(request)
        try pump()
    }

    private func finishInventoryIfNeeded(_ request: WatchInventoryRequest) throws {
        guard saved.inventory == request, saved.head == request.head,
              !saved.jobs.contains(where: { $0.inventoryRequestID == request.id }) else { return }
        let previous = saved
        saved.inventory = nil
        saved.inventoryNextAttempt = nil
        saved.inventoryCompletedAt = now()
        if request.isManual { saved.manualCompleted = true }
        do { try save() } catch { saved = previous; throw error }
        if request.isManual { transport.inventoryCompletion(.init(request: request)) }
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
        if report.request.isManual {
            guard report.isValid, report.request == saved.inventory else { return }
            if !saved.jobs.contains(where: { $0.inventoryRequestID == report.request.id }) {
                try finishInventoryIfNeeded(report.request)
                try pump()
                return
            }
            guard report.entries.contains(where: { entry in
                saved.jobs.contains { $0.type == entry.type && $0.filename == entry.filename && $0.inventoryRequestID == report.request.id }
            }) else { return }
            // retain the first bounded window; replay skips checked entries and advances to later batches.
            guard !inventoryReports.contains(report), inventoryReports.count < 8 else { return }
            inventoryReports.append(report)
            if inventoryWork == nil {
                inventoryWork = Task {
                    defer { inventoryWork = nil }
                    while !inventoryReports.isEmpty {
                        let next = inventoryReports.removeFirst()
                        do { try await receiveVerified(next); errorMessage = nil } catch {
                            errorMessage = error.localizedDescription
                            diagnostics.metadata(.inventoryFailed, head: next.request.head, error: error)
                        }
                    }
                }
            }
            return
        }
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

    private func receiveVerified(_ report: WatchInventoryReport) async throws {
        guard report.request == saved.inventory, report.request.head == saved.head else { return }
        for entry in report.entries {
            guard let index = saved.jobs.firstIndex(where: {
                $0.type == entry.type && $0.filename == entry.filename && $0.inventoryRequestID == report.request.id
            }) else { continue }
            let job = saved.jobs[index]
            let file: WatchContentFile?
            if let known = job.file {
                file = known
            } else if let value = try await worker.observe(fileStore.fileURL(entry.type, entry.filename)) {
                guard value.stamp.stillMatches(fileStore.fileURL(entry.type, entry.filename)) else { throw WatchLibraryError.invalid }
                file = WatchContentFile(head: report.request.head, type: entry.type, filename: entry.filename,
                                        bytes: value.stamp.size, digest: value.digest)
            } else { file = nil }
            guard report.request == saved.inventory, report.request.head == saved.head,
                  saved.jobs.indices.contains(index), saved.jobs[index].inventoryRequestID == report.request.id,
                  saved.jobs[index].file == job.file else { continue }
            let previous = saved
            let verified = file.map { entry.bytes == $0.bytes && entry.digest == $0.digest } ?? false
            if verified, let file {
                saved.jobs[index].file = file
                saved.jobs[index].status = .delivered
                saved.jobs[index].inventoryRequestID = nil
            } else if job.status == .delivered {
                saved.jobs[index] = Job(type: job.type, filename: job.filename)
            } else { saved.jobs[index].inventoryRequestID = nil }
            do { try save() } catch { saved = previous; throw error }
            if verified, let file {
                transport.cancel(file.id)
                diagnostics.record(.init(kind: .inventoryVerified, id: file.id, source: .phone, fileType: file.type,
                                         identity: WatchDiagnosticIdentity(report.request.head)))
            } else if job.status == .delivered, let file {
                transport.cancel(file.id)
                diagnostics.record(.init(kind: .inventoryMissing, id: file.id, source: .phone, fileType: file.type,
                                         identity: WatchDiagnosticIdentity(report.request.head)))
            }
        }
        let previous = saved
        do { try finishInventoryIfNeeded(report.request) } catch { saved = previous; throw error }
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
        try state.save(saved, to: directory.appending(path: "state.json"))
    }

    private func pump() throws {
        diagnostics.record(.init(kind: .queueWakeup, id: saved.head?.publisher ?? UUID(), source: .system,
                                 identity: saved.head.map(WatchDiagnosticIdentity.init)))
        timer?.cancel()
        guard transport.available() else { try publishReport(); return }
        if let request = saved.inventory, (saved.inventoryNextAttempt ?? .distantPast) <= now() {
            if saved.inventoryNextAttempt == .distantPast, !request.isManual { saved.inventoryStartedAt = now() }
            saved.inventoryNextAttempt = now().addingTimeInterval(60)
            try save()
            diagnostics.record(.init(kind: request.isManual ? .inventoryManualRequested : .inventoryRequested, id: request.id, source: .phone,
                                     identity: WatchDiagnosticIdentity(request.head)))
            transport.inventory(request)
        }
        let outstanding = transport.outstanding()
        let systemIDs = Set(outstanding.map(\.id))
        // source copies may be removed only after the system relinquishes them.
        let needed = Set(saved.jobs.filter { $0.status != .delivered && $0.status != .failed }.compactMap { $0.file?.id })
            .union(systemIDs).union(saved.recoveryFiles?.map(\.id) ?? []).union(saved.unidentifiedSources ?? [])
            .union(preparations.keys).union(preparationSources.values)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !needed.contains(id) {
                try FileManager.default.removeItem(at: url)
            }
        }
        var occupied = preparations.count + outstanding.count + saved.jobs.filter {
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
            if saved.inventory?.isManual == true, job.inventoryRequestID == saved.inventory?.id { continue }
            guard occupied < Self.maximumTransfers, job.nextAttempt <= now(), let head = saved.head,
                  head.metadataReady, head.failed != true, head.libraryID != nil else { continue }
            do {
                if job.file == nil {
                    let key = "\(head.publisher)/\(head.revision)/\(job.type)/\(job.filename)"
                    guard !preparingNames.values.contains(key) else { continue }
                    let recovered = saved.recoveryFiles?.first {
                        $0.head.libraryID == head.libraryID && $0.type == job.type && $0.filename == job.filename
                    }
                    guard recovered != nil || fileStore.exists(job.type, job.filename) else {
                        job.status = .missingOnPhone
                        job.nextAttempt = now().addingTimeInterval(60)
                        saved.jobs[index] = job
                        continue
                    }
                    prepare(job, head: head, recovered: recovered, key: key)
                    occupied += 1
                    continue
                }
                guard let file = job.file else { continue }
                job.attempts += 1
                job.status = .transferring
                saved.jobs[index] = job
                // independent immutable descriptors let a damaged queue recover private source ownership.
                try state.save(file, to: directory.appending(path: "\(file.id.uuidString).json"))
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
        if let snapshot = saved.snapshot, snapshot.head == saved.head {
            saved.recoveryFiles = saved.recoveryFiles?.filter { file in
                saved.jobs.contains { $0.type == file.type && $0.filename == file.filename && $0.file == nil }
            }
        }
        try save()
        try publishReport()
        schedule()
    }

    private func prepare(_ job: Job, head: WatchLibraryHead, recovered: WatchContentFile?, key: String) {
        let id = UUID()
        let epoch = generation
        let original = fileStore.fileURL(job.type, job.filename)
        let copy = directory.appending(path: id.uuidString)
        let recoveryURL = recovered.map { source($0) }
        preparingNames[id] = key
        preparationSources[id] = recovered?.id
        preparations[id] = Task {
            do {
                let file = try await worker.prepare(.init(id: id, head: head, type: job.type, filename: job.filename,
                                                           original: original, recovered: recovered, recoveryURL: recoveryURL, copy: copy))
                try Task.checkCancellation()
                guard generation == epoch, saved.head == head, transport.available(),
                      let index = saved.jobs.firstIndex(where: { $0.type == job.type && $0.filename == job.filename && $0.file == nil })
                else { throw CancellationError() }
                // no suspension between authority validation, durable ownership and enqueue.
                saved.jobs[index].file = file
                let queriesRecovery = file.id != id
                saved.jobs[index].status = queriesRecovery ? .awaitingReceipt : .transferring
                saved.jobs[index].nextAttempt = queriesRecovery ? now().addingTimeInterval(60) : .distantPast
                saved.jobs[index].attempts += 1
                try state.save(file, to: directory.appending(path: "\(file.id.uuidString).json"))
                try save()
                if queriesRecovery {
                    transport.query(file)
                    diagnostics.delivery(.receiptQuery, file: file, source: .phone)
                } else {
                    transport.enqueue(file, copy)
                    diagnostics.delivery(.contentEnqueued, file: file, source: .phone, status: .transferring)
                }
            } catch {
                if generation == epoch, !(error is CancellationError),
                   let index = saved.jobs.firstIndex(where: { $0.type == job.type && $0.filename == job.filename }) {
                    let missing = WatchDeliveryState.isMissing(error) && saved.jobs[index].file == nil
                    saved.jobs[index].status = missing ? .missingOnPhone : Self.isPermanent(error) ? .failed : .retrying
                    if missing { saved.recoveryFiles?.removeAll { $0.id == recovered?.id } }
                    saved.jobs[index].attempts += 1
                    saved.jobs[index].nextAttempt = now().addingTimeInterval(missing ? 60 : backoff(saved.jobs[index].attempts))
                    errorMessage = error.localizedDescription
                    try? save()
                }
                // failed persistence may already own this copy; preserve it for receipt-query recovery.
                if !saved.jobs.contains(where: { $0.file?.id == id }) {
                    try? FileManager.default.removeItem(at: copy)
                    try? FileManager.default.removeItem(at: directory.appending(path: "\(id.uuidString).json"))
                }
            }
            preparations[id] = nil
            preparationSources[id] = nil
            preparingNames[id] = nil
            // a new selection can replenish slots; unavailable transport waits for a lifecycle wakeup.
            if generation != epoch || transport.available() {
                do { try pump() } catch { errorMessage = error.localizedDescription }
            }
        }
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

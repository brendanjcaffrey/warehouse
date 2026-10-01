import Foundation

/// preparation intent outlives the foreground wait. both transports hand their
/// temporary files to this actor, so only one authorized result enters the cache.
@MainActor
final class WatchFileDownloader: SingleFileDownloading {
    struct Transport {
        var isReachable: @MainActor () -> Bool
        var currentToken: @MainActor () -> String?
        var currentGeneration: @MainActor () -> UUID
        var request: @MainActor (WatchFileTransfer, String, @escaping @MainActor (PhoneFileReply) -> Void) -> Void
        var cancel: @MainActor (UUID) -> Void
        var fileSize: @MainActor (LibraryFileType, String, String) async -> Int64? = { _, _, _ in nil }
    }

    enum State: String, Codable { case queued, accepted, transferring, delivered, rejected, cancelled }

    struct Job: Codable, Equatable {
        let transfer: WatchFileTransfer
        var state: State = .queued
        var reason: PhoneFileReply?
        var fraction: Double = 0
    }

    private struct Journal: Codable {
        let generation: UUID
        let desired: Set<FileToDownload>
        let jobs: [Job]
    }

    private struct Waiter {
        let continuation: CheckedContinuation<FileDownloadResult, Never>
        let onPhase: @MainActor @Sendable (FileDownloadPhase) -> Void
    }

    private struct Active {
        let id = UUID()
        let token: String
        let baseURL: URL
        var waiters: [UUID: Waiter] = [:]
        var deadline: Task<Void, Never>?
        var http: Task<Void, Never>?
    }

    typealias Fetch = @MainActor (LibraryFileType, String, String, URL) async throws -> URL
    typealias Size = @MainActor (LibraryFileType, String, String, URL) async throws -> Int64
    private let fileStore: FileStore
    private let fileCache: FileCache?
    private let fetch: Fetch
    private let moveIn: @MainActor (LibraryFileType, String, URL) throws -> Void
    private let size: Size
    private let availableBytes: @MainActor () -> Int64?
    private let wait: @MainActor (Duration) async throws -> Void
    private let timeout: Duration
    private let transport: Transport
    private var generation: UUID
    private var desired: Set<FileToDownload> = []
    private(set) var jobs: [UUID: Job] = [:]
    private var active: [UUID: Active] = [:]
    private var persistenceFailed = false
    var onStored: (@MainActor (LibraryFileType) -> Void)?
    var onEvent: (@MainActor (Job) -> Void)?
    private var journalURL: URL { fileStore.rootURL.appending(path: "phone-transfers.json") }

    init(
        fileStore: FileStore, timeout: Duration = .seconds(30), transport: Transport,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: @escaping Fetch = { try await LibraryClient().downloadFile($0, filename: $1, token: $2, baseURL: $3) },
        fileCache: FileCache? = nil,
        availableBytes: @escaping @MainActor () -> Int64? = { FileStore.deviceStorage()?.availableBytes },
        size: @escaping Size = { try await LibraryClient().fileSize($0, filename: $1, token: $2, baseURL: $3) },
        moveIn: (@MainActor (LibraryFileType, String, URL) throws -> Void)? = nil
    ) {
        self.fileStore = fileStore
        self.fileCache = fileCache
        self.timeout = timeout
        self.transport = transport
        self.wait = wait
        self.fetch = fetch
        self.moveIn = moveIn ?? { try fileStore.moveIn($0, $1, from: $2) }
        self.availableBytes = availableBytes
        self.size = size
        generation = transport.currentGeneration()
        if let data = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.generation == generation {
            desired = journal.desired
            for job in journal.jobs where job.transfer.generation == generation && desired.contains(job.transfer.file) {
                guard WatchFileTransfer.validFilename(job.transfer.filename) else { continue }
                jobs[job.transfer.id] = job
            }
        }
    }

    /// called from persisted playlist intent, including during launch before
    /// connectivity activates. backgrounding ends a wait, not this intent.
    func setDesiredMusic(_ filenames: Set<String>) {
        configurationChanged()
        let previous = desired
        desired = Set(filenames.filter(WatchFileTransfer.validFilename).map { FileToDownload(type: .music, filename: $0) })
        for job in Array(jobs.values) where previous.contains(job.transfer.file) && !desired.contains(job.transfer.file) {
            revoke(job.transfer.id)
        }
        persist()
    }

    func configurationChanged() {
        guard generation != transport.currentGeneration() || transport.currentToken() == nil else { return }
        generation = transport.currentGeneration()
        desired = []
        for id in Array(jobs.keys) { revoke(id) }
        persist()
    }

    /// the phone's system queue persists independently; reconcile on activation
    /// and reconnection, including progress of a request accepted before relaunch.
    func reconcile(_ progress: [PhoneFileProgress]) {
        configurationChanged()
        for item in progress {
            guard jobs[item.transfer.id]?.transfer == item.transfer else { transport.cancel(item.transfer.id); continue }
            update(item.transfer.id, state: item.fraction > 0 ? .transferring : .accepted, fraction: item.fraction)
        }
    }

    @MainActor
    func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
        await downloadResult(type, filename: filename, token: token, baseURL: baseURL, onPhase: { _ in }) == .downloaded
    }

    @MainActor
    func downloadResult(
        _ type: LibraryFileType, filename: String, token: String, baseURL: URL,
        onPhase: @escaping @MainActor @Sendable (FileDownloadPhase) -> Void
    ) async -> FileDownloadResult {
        configurationChanged()
        guard !Task.isCancelled, WatchFileTransfer.validFilename(filename), token == transport.currentToken() else { return .failed }
        if fileStore.exists(type, filename) { return .downloaded }
        let file = FileToDownload(type: type, filename: filename)
        var didReserve = false
        if let fileCache {
            let bytes: Int64
            do {
                if let phoneBytes = transport.isReachable() ? await transport.fileSize(type, filename, token) : nil {
                    bytes = phoneBytes
                } else {
                    bytes = try await size(type, filename, token, baseURL)
                }
            } catch {
                return .failed
            }
            configurationChanged()
            guard !Task.isCancelled, token == transport.currentToken() else { return .failed }
            if fileStore.exists(type, filename) { return .downloaded }
            if !active.keys.contains(where: { jobs[$0]?.transfer.file == file }) {
                guard fileCache.reserve(type, filename, bytes: bytes, availableBytes: availableBytes(),
                                        allowOversized: desired.contains(file)) else { return .outOfSpace }
                didReserve = true
            }
        }
        let transfer = jobs.values.first { $0.transfer.file == file }?.transfer
            ?? WatchFileTransfer(generation: generation, type: type, filename: filename)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    if didReserve { fileCache?.release(type, filename) }
                    continuation.resume(returning: .failed)
                    return
                }
                let isNew = jobs[transfer.id] == nil
                if isNew { jobs[transfer.id] = Job(transfer: transfer) }
                active[transfer.id, default: Active(token: token, baseURL: baseURL)].waiters[waiterID] = Waiter(
                    continuation: continuation, onPhase: onPhase)
                guard persist() else { complete(transfer.id, result: .failed, keepPhone: false); return }
                if isNew, let job = jobs[transfer.id] { onEvent?(job) }
                if active[transfer.id]?.http != nil { onPhase(.downloading); return }
                onPhase(.waitingForPhone)
                if active[transfer.id]?.deadline != nil { return }
                let phoneCount = jobs.values.filter { $0.state == .queued || $0.state == .accepted || $0.state == .transferring }.count
                guard transport.isReachable(), !isNew || phoneCount <= PhoneFileProvider.maximumTransfers else {
                    update(transfer.id, state: .rejected, reason: transport.isReachable() ? .queueFull : .unavailable)
                    startHTTP(transfer.id, token: token, baseURL: baseURL)
                    return
                }
                let duration = type == .artwork ? min(timeout, .seconds(2)) : timeout
                active[transfer.id]?.deadline = Task { [weak self, wait] in
                    do {
                        try await wait(duration)
                        try Task.checkCancellation()
                    } catch { return }
                    self?.startHTTP(transfer.id, token: token, baseURL: baseURL)
                }
                transport.request(transfer, token) { [weak self] reply in
                    guard let self, self.jobs[transfer.id]?.transfer == transfer else { return }
                    self.update(transfer.id, state: reply == .accepted ? .accepted : .rejected, reason: reply)
                    if reply != .accepted { self.startHTTP(transfer.id, token: token, baseURL: baseURL) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(waiterID, transfer: transfer) }
        }
    }

    func receive(_ transfer: WatchFileTransfer, from temporary: URL) {
        commit(transfer, temporary: temporary)
    }

    func stagingFailed(_ transfer: WatchFileTransfer, outOfSpace: Bool) {
        guard jobs[transfer.id]?.transfer == transfer else { return }
        if outOfSpace {
            complete(transfer.id, result: .outOfSpace, keepPhone: false)
        } else {
            failed(transfer)
        }
    }

    func failed(_ transfer: WatchFileTransfer) {
        guard jobs[transfer.id]?.transfer == transfer else { return }
        update(transfer.id, state: .rejected, reason: .transferFailed)
        if let running = active[transfer.id] {
            startHTTP(transfer.id, token: running.token, baseURL: running.baseURL)
        }
    }

    private func startHTTP(_ id: UUID, token: String, baseURL: URL) {
        guard let job = jobs[id], let running = active[id], running.http == nil else { return }
        active[id]?.deadline?.cancel()
        active[id]?.deadline = nil
        guard token == transport.currentToken(), job.transfer.generation == transport.currentGeneration() else { revoke(id); return }
        for waiter in active[id]?.waiters.values ?? [:].values { waiter.onPhase(.downloading) }
        active[id]?.http = Task { [weak self, fetch] in
            do {
                let temporary = try await fetch(job.transfer.type, job.transfer.filename, token, baseURL)
                guard let self else { try? FileManager.default.removeItem(at: temporary); return }
                self.commit(job.transfer, temporary: temporary)
            } catch {
                // cancellation can finish after a new foreground caller has
                // resumed this same durable transfer. only finish our attempt.
                guard self?.active[id]?.id == running.id else { return }
                self?.complete(id, result: BackgroundDownload.isOutOfSpace(error) ? .outOfSpace : .failed, keepPhone: true)
            }
        }
    }

    private func commit(_ transfer: WatchFileTransfer, temporary: URL) {
        defer { try? FileManager.default.removeItem(at: temporary) }
        configurationChanged()
        guard jobs[transfer.id]?.transfer == transfer,
              transfer.generation == transport.currentGeneration(), transport.currentToken() != nil,
              desired.contains(transfer.file) || active[transfer.id] != nil else { return }
        guard !persistenceFailed else { complete(transfer.id, result: .failed, keepPhone: false); return }
        do {
            if let fileCache, !fileStore.exists(transfer.type, transfer.filename) {
                let bytes = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                guard bytes > 0 else {
                    complete(transfer.id, result: .failed, keepPhone: false)
                    return
                }
                if bytes > (fileCache.reservedBytes(transfer.type, transfer.filename) ?? 0) {
                    fileCache.release(transfer.type, transfer.filename)
                    guard fileCache.reserve(transfer.type, transfer.filename, bytes: bytes,
                                            availableBytes: availableBytes().map { $0 + bytes },
                                            allowOversized: desired.contains(transfer.file)) else {
                        complete(transfer.id, result: .outOfSpace, keepPhone: false)
                        return
                    }
                }
            }
            // main-actor serialization covers the existence check and move for
            // both transports. neither transport writes the destination itself.
            if !fileStore.exists(transfer.type, transfer.filename) {
                try moveIn(transfer.type, transfer.filename, temporary)
            }
            update(transfer.id, state: .delivered, fraction: 1)
            complete(transfer.id, result: .downloaded, keepPhone: false)
            onStored?(transfer.type)
        } catch {
            complete(transfer.id, result: BackgroundDownload.isOutOfSpace(error) ? .outOfSpace : .failed, keepPhone: false)
        }
    }

    private func cancelWaiter(_ id: UUID, transfer: WatchFileTransfer) {
        let waiter = active[transfer.id]?.waiters.removeValue(forKey: id)
        waiter?.continuation.resume(returning: .failed)
        guard active[transfer.id]?.waiters.isEmpty == true else { return }
        complete(transfer.id, result: .failed, keepPhone: desired.contains(transfer.file))
    }

    private func revoke(_ id: UUID) {
        update(id, state: .cancelled)
        complete(id, result: .failed, keepPhone: false)
    }

    private func complete(_ id: UUID, result: FileDownloadResult, keepPhone: Bool) {
        if let transfer = jobs[id]?.transfer { fileCache?.release(transfer.type, transfer.filename) }
        let running = active.removeValue(forKey: id)
        running?.deadline?.cancel()
        running?.http?.cancel()
        if !keepPhone || jobs[id].map({ !desired.contains($0.transfer.file) }) == true {
            jobs[id] = nil
            transport.cancel(id)
        }
        persist()
        for waiter in running?.waiters.values ?? [:].values { waiter.continuation.resume(returning: result) }
    }

    private func update(_ id: UUID, state: State, reason: PhoneFileReply? = nil, fraction: Double = 0) {
        guard var job = jobs[id] else { return }
        job.state = state
        job.reason = reason
        job.fraction = fraction
        jobs[id] = job
        persist()
        onEvent?(job)
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileStore.rootURL, withIntermediateDirectories: true)
            let journal = Journal(generation: generation, desired: desired,
                                  jobs: jobs.values.filter { desired.contains($0.transfer.file) })
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            persistenceFailed = false
        } catch {
            persistenceFailed = true
        }
        return !persistenceFailed
    }
}

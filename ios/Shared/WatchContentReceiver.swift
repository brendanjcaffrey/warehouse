import Foundation
import Observation

/// staging is synchronous; admission and receipts use the accepted metadata inventory.
@MainActor
@Observable
final class WatchContentReceiver {
    private let diagnostics: WatchDiagnostics
    private let fileCache: FileCache
    private let directory: URL
    private let availableBytes: () -> Int64?
    private let send: (WatchContentReceipt) -> Void
    private let beforeCommit: () throws -> Void
    private let now: () -> Date
    private let state: WatchDeliveryState
    let recoveredState: Bool
    private let beforeReceipt: () throws -> Void
    private var head: WatchLibraryHead?
    private var pendingHead: WatchLibraryHead?
    private var snapshot: WatchLibrarySnapshot?
    private var reports: [WatchLibraryDeliveryReport]
    private(set) var receipts: [WatchContentReceipt]
    private(set) var errorMessage: String?
    private let inventory: WatchInventoryResponder
    var sendInventory: (WatchInventoryReport) -> Bool {
        get { inventory.send }
        set { inventory.send = newValue }
    }

    init(fileCache: FileCache, directory: URL = defaultDirectory(),
         availableBytes: @escaping () -> Int64? = { FileStore.deviceStorage()?.availableBytes },
         send: @escaping (WatchContentReceipt) -> Void, beforeCommit: @escaping () throws -> Void = {},
         beforeReceipt: @escaping () throws -> Void = {}, now: @escaping () -> Date = { Date() }, diagnostics: WatchDiagnostics? = nil,
         state: WatchDeliveryState = .init()) throws {
        self.diagnostics = diagnostics ?? .shared
        inventory = WatchInventoryResponder(fileStore: fileCache.fileStore, directory: directory, diagnostics: diagnostics ?? .shared, now: now)
        self.fileCache = fileCache
        self.directory = directory
        self.availableBytes = availableBytes
        self.send = send
        self.beforeCommit = beforeCommit
        self.beforeReceipt = beforeReceipt
        self.now = now
        self.state = state
        let reportsURL = directory.appending(path: "phone-progress.json")
        reports = (try? JSONDecoder().decode([WatchLibraryDeliveryReport].self, from: Data(contentsOf: reportsURL))) ?? []
        let url = directory.appending(path: "receipts.json")
        let loaded = try state.load([WatchContentReceipt].self, from: url, empty: [])
        receipts = loaded.value
        recoveredState = loaded.repaired
        if loaded.repaired { try state.save(receipts, to: url) }
        fileCache.onFilesReleased = { [weak self] in
            Task { @MainActor [weak self] in self?.resume() }
        }
    }

    nonisolated static func defaultDirectory() -> URL { URL.applicationSupportDirectory.appending(path: "watch-content-inbox") }

    /// the manifest and bytes become visible together, before the delegate returns.
    nonisolated static func stage(_ source: URL, file: WatchContentFile, directory: URL = defaultDirectory(),
                                  availableBytes: Int64? = FileStore.deviceStorage()?.availableBytes) throws {
        try file.validate()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { throw WatchLibraryError.invalid }
        guard let availableBytes, availableBytes - file.bytes >= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(file).write(to: temporary.appending(path: "file.json"), options: .atomic)
        try FileManager.default.copyItem(at: source, to: temporary.appending(path: "bytes"))
        let destination = directory.appending(path: file.id.uuidString)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func reconcile(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) throws {
        pendingHead = head
        self.head = nil
        self.snapshot = snapshot
        // an absent or pending snapshot cannot revoke the last durable selection.
        if head != nil { fileCache.awaitWatchSelection() }
        if let snapshot, snapshot.head == head {
            _ = try snapshot.validatedLibrary()
            try fileCache.adoptWatchSelection(music: snapshot.music, artwork: snapshot.artwork)
        }
        self.head = head
        try compactReceipts()
        try drain()
        try inventory.publish(head: head, snapshot: snapshot)
    }

    func receive(_ report: WatchLibraryDeliveryReport) throws {
        if let previous = reports.first(where: { $0.head == report.head }), previous.sequence >= report.sequence { return }
        var next = reports.filter { $0.head != report.head }
        next.append(report)
        // retain a few revisions because status can arrive before its metadata context.
        next = Array(next.suffix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appending(path: "phone-progress.json"), options: .atomic)
        reports = next
    }

    func query(_ request: WatchInventoryRequest) throws {
        try inventory.receive(request)
        try inventory.publish(head: head, snapshot: snapshot)
    }

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        var progress = WatchLibraryProgress.make(head: pendingHead, snapshot: snapshot, playlistID: playlistID) { type, name in
            // restored and retained local files are playable before a new acknowledgment arrives.
            if fileCache.fileStore.exists(type, name) { return .delivered }
            return receipts.last(where: {
                $0.file.head == snapshot?.head && $0.file.type == type && $0.file.filename == name
            }).map { $0.status == .delivered ? .pending : $0.status } ?? .pending
        }
        if let report = reports.last(where: { $0.head == snapshot?.head && $0.head == pendingHead }) {
            let reported = playlistID.flatMap { report.playlists[$0] } ?? report.overall
            if progress.state == .waiting && [.needsPhoneSync, .storageFull, .failed].contains(reported.state) {
                progress.state = reported.state
                progress.music.failed = min(reported.music.failed, progress.music.total - progress.music.downloaded)
            }
            let remainingArtwork = progress.artwork.total - progress.artwork.downloaded
            progress.artwork.failed = max(progress.artwork.failed, min(reported.artwork.failed, remainingArtwork))
            progress.artwork.missingOnPhone = min(reported.artwork.missingOnPhone, remainingArtwork)
            progress.artwork.storageFull = max(progress.artwork.storageFull, min(reported.artwork.storageFull, remainingArtwork))
        }
        return progress
    }

    func diagnosticState() -> WatchDeliveryDiagnosticState {
        var state = WatchDeliveryDiagnosticState(peer: .watch)
        state.head = pendingHead.map(WatchDiagnosticIdentity.init)
        state.inventoryHead = snapshot.map { WatchDiagnosticIdentity($0.head) }
        state.availableBytes = availableBytes()
        state.inventoryPending = inventory.requests.count
        state.inventoryRequestID = inventory.requests.first?.id
        state.inventoryStartedAt = inventory.lastScanAt
        state.inventoryEligibleAt = inventory.lastScanAt?.addingTimeInterval(WatchInventoryRequest.minimumInterval)
        let music = fileCache.fileStore.entries(.music)
        let artwork = fileCache.fileStore.entries(.artwork)
        state.localMusic = WatchDeliveryDiagnosticState.local(music)
        state.localArtwork = WatchDeliveryDiagnosticState.local(artwork)
        state.stagedFiles = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .count { UUID(uuidString: $0) != nil }
        for type in LibraryFileType.allCases {
            let names = type == .music ? try? snapshot?.music : try? snapshot?.artwork
            for name in names ?? [] {
                let entry = (type == .music ? music : artwork).first { $0.filename == name }
                let receipt = receipts.last { $0.file.head == snapshot?.head && $0.file.type == type && $0.file.filename == name }
                let status: WatchContentStatus = entry != nil ? .delivered : receipt.map {
                    $0.status == .delivered ? .pending : $0.status
                } ?? .pending
                state.add(type: type, status: status, bytes: entry?.sizeBytes ?? receipt?.file.bytes)
            }
        }
        return state
    }

    func staged(_ file: WatchContentFile) {
        diagnostics.delivery(.contentStaged, file: file, source: .phone)
        resume()
    }

    /// stop commits while the database serializes a newly received control message.
    func pause() { head = nil; pendingHead = nil }

    func resume() {
        do { try reconcile(head: pendingHead, snapshot: snapshot); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    private func isDesired(_ file: WatchContentFile) -> Bool {
        guard file.head == head, let snapshot, snapshot.head == head else { return false }
        let names = file.type == .music ? try? snapshot.music : try? snapshot.artwork
        return names?.contains(file.filename) == true
    }

    /// a lost receipt is repaired from durable identity plus actual verified bytes, never system completion.
    func query(_ file: WatchContentFile) throws {
        diagnostics.delivery(.receiptQuery, file: file, source: .phone)
        guard isDesired(file) else {
            if let head, head.publisher == file.head.publisher, file.head.revision < head.revision {
                send(.init(file: file, status: .failed))
            }
            return
        }
        try drain()
        if receipts.contains(where: { $0.file == file && $0.status == .failed }) {
            send(.init(file: file, status: .failed))
            return
        }
        let url = fileCache.fileStore.fileURL(file.type, file.filename)
        if file.matches(url) {
            if receipts.contains(where: { $0.file == file && $0.status == .delivered }) {
                diagnostics.delivery(.receiptSent, file: file, source: .phone, status: .delivered)
                send(.init(file: file, status: .delivered))
            } else {
                // superseded receipts can be reconstructed only from current authority and verified bytes.
                try acknowledge(file, status: .delivered)
            }
        } else if let receipt = receipts.first(where: { $0.file == file && $0.status == .retrying }),
                  let retryAt = receipt.retryAt, retryAt > now() {
            send(receipt)
        } else if !FileManager.default.fileExists(atPath: directory.appending(path: file.id.uuidString).path) {
            try acknowledge(file, status: .retrying)
        }
    }

    func stagingFailed(_ file: WatchContentFile, error: Error) {
        diagnostics.delivery(BackgroundDownload.isOutOfSpace(error) ? .contentStorageFull : .contentFailed,
                             file: file, source: .phone, error: error)
        guard isDesired(file) else { return }
        do {
            if file.matches(fileCache.fileStore.fileURL(file.type, file.filename)) {
                diagnostics.delivery(.contentReused, file: file, source: .cache)
                try acknowledge(file, status: .delivered)
                if file.type == .music { fileCache.noteMusicStored() }
                return
            }
            let permanent = error is WatchLibraryError || error is FileStore.FilenameError
            try acknowledge(file, status: permanent ? .failed : BackgroundDownload.isOutOfSpace(error) ? .storageFull : .retrying)
        } catch { errorMessage = error.localizedDescription }
    }

    private func acknowledge(_ file: WatchContentFile, status: WatchContentStatus,
                             retryAt: Date? = nil, attempts: Int? = nil) throws {
        var next = receipts.filter { $0.file.id != file.id }
        var receipt = WatchContentReceipt(file: file, status: status)
        receipt.retryAt = retryAt
        receipt.attempts = attempts
        next.append(receipt)
        try saveReceipts(retainedReceipts(next))
        diagnostics.delivery(.receiptPersisted, file: file, source: .cache, status: status)
        diagnostics.delivery(.receiptSent, file: file, source: .phone, status: status)
        send(receipt)
    }

    private func retainedReceipts(_ candidates: [WatchContentReceipt]) throws -> [WatchContentReceipt] {
        // pending or failed metadata must not revoke recovery evidence from the saved selection.
        guard let head, let snapshot, snapshot.head == head else { return candidates }
        let names: [LibraryFileType: Set<String>] = [.music: try snapshot.music, .artwork: try snapshot.artwork]
        let staged = FileManager.default.fileExists(atPath: directory.path)
            ? Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap(UUID.init(uuidString:))) : []
        var seen = [LibraryFileType: Set<String>]()
        return candidates.reversed().filter { receipt in
            let file = receipt.file
            guard file.head == head, names[file.type]?.contains(file.filename) == true else { return false }
            let latest = seen[file.type, default: []].insert(file.filename).inserted
            // one latest result per selected file, plus exact backoff for manifests still in the inbox.
            return latest || staged.contains(file.id)
        }.reversed()
    }

    private func compactReceipts() throws {
        guard !receipts.isEmpty else { return }
        let next = try retainedReceipts(receipts)
        if next != receipts { try saveReceipts(next) }
    }

    private func saveReceipts(_ next: [WatchContentReceipt]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try beforeReceipt()
        try state.save(next, to: directory.appending(path: "receipts.json"))
        receipts = next
    }

    private func drain() throws {
        diagnostics.record(.init(kind: .queueWakeup, id: pendingHead?.publisher ?? UUID(), source: .system,
                                 identity: pendingHead.map(WatchDiagnosticIdentity.init)))
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where UUID(uuidString: url.lastPathComponent) != nil {
            guard let file = try? JSONDecoder().decode(WatchContentFile.self, from: Data(contentsOf: url.appending(path: "file.json"))),
                  (try? file.validate()) != nil else {
                try FileManager.default.removeItem(at: url)
                continue
            }
            guard isDesired(file) else {
                // only the context authorizes files; future files wait for their snapshot.
                if let head, snapshot?.head == head,
                   head.publisher != file.head.publisher || head.revision >= file.head.revision {
                    try FileManager.default.removeItem(at: url)
                }
                continue
            }
            if let receipt = receipts.first(where: { $0.file == file }), let retryAt = receipt.retryAt, retryAt > now() { continue }
            do {
                try commit(file, from: url)
            } catch {
                let permanent = (error as NSError).domain == NSCocoaErrorDomain
                    && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains((error as NSError).code)
                let status: WatchContentStatus = permanent ? .failed : BackgroundDownload.isOutOfSpace(error) ? .storageFull : .retrying
                let attempts = (receipts.first { $0.file == file }?.attempts ?? 0) + 1
                let retryAt = status == .retrying ? now().addingTimeInterval(min(3600, 5 * pow(2, Double(min(attempts, 10))))) : nil
                diagnostics.delivery(status == .storageFull ? .contentStorageFull : status == .failed ? .contentFailed : .contentRetry,
                                     file: file, source: .cache, status: status, error: error)
                try acknowledge(file, status: status, retryAt: retryAt, attempts: attempts)
                if permanent || status == .storageFull { try FileManager.default.removeItem(at: url) }
                errorMessage = error.localizedDescription
            }
        }
        // successful commits have released their manifests, so their superseded results can now leave the ledger.
        try compactReceipts()
    }

    private func commit(_ file: WatchContentFile, from url: URL) throws {
        let destination = fileCache.fileStore.fileURL(file.type, file.filename)
        if file.matches(destination) {
            diagnostics.delivery(.contentReused, file: file, source: .cache)
            try acknowledge(file, status: .delivered)
            try FileManager.default.removeItem(at: url)
            if file.type == .music { fileCache.noteMusicStored() }
            return
        }
        let staged = url.appending(path: "bytes")
        guard file.matches(staged) else {
            diagnostics.delivery(.contentFailed, file: file, source: .cache, status: .failed, error: WatchLibraryError.invalid)
            try acknowledge(file, status: .failed)
            try FileManager.default.removeItem(at: url)
            return
        }
        // replacing bytes under the same name also waits for active playback to release them.
        if fileCache.fileStore.exists(file.type, file.filename), fileCache.isInUse(file.type, file.filename) { return }
        // staging already occupies this space, so admission accounts for the pending move.
        guard fileCache.reserve(file.type, file.filename, bytes: file.bytes,
                                availableBytes: availableBytes().map { $0 + file.bytes }, allowOversized: true) else {
            diagnostics.delivery(.contentStorageFull, file: file, source: .cache, status: .storageFull,
                                 error: CocoaError(.fileWriteOutOfSpace))
            try acknowledge(file, status: .storageFull)
            try FileManager.default.removeItem(at: url)
            return
        }
        defer { fileCache.release(file.type, file.filename) }
        try beforeCommit()
        // same-volume rename avoids another full copy; the manifest repairs a lost receipt after commit.
        try FileManager.default.createDirectory(at: fileCache.fileStore.directoryURL(file.type), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        diagnostics.delivery(.contentCommitted, file: file, source: .cache)
        try acknowledge(file, status: .delivered)
        try FileManager.default.removeItem(at: url)
        if file.type == .music { fileCache.noteMusicStored() }
    }
}

/// delegate staging can run before the main actor sees the receipt; background completion must see both.
final class WatchContentActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    var count: Int { lock.withLock { active } }
    func begin() { lock.withLock { active += 1 } }
    func end() { lock.withLock { active -= 1 } }
}

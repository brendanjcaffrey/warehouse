import Foundation
import Observation

/// staging is synchronous; admission and receipts use the accepted metadata inventory.
@MainActor
@Observable
final class WatchContentReceiver {
    private let fileCache: FileCache
    private let directory: URL
    private let availableBytes: () -> Int64?
    private let send: (WatchContentReceipt) -> Void
    private let beforeCommit: () throws -> Void
    private let now: () -> Date
    private let beforeReceipt: () throws -> Void
    private var head: WatchLibraryHead?
    private var pendingHead: WatchLibraryHead?
    private var snapshot: WatchLibrarySnapshot?
    private(set) var receipts: [WatchContentReceipt]
    private(set) var errorMessage: String?

    init(fileCache: FileCache, directory: URL = defaultDirectory(),
         availableBytes: @escaping () -> Int64? = { FileStore.deviceStorage()?.availableBytes },
         send: @escaping (WatchContentReceipt) -> Void, beforeCommit: @escaping () throws -> Void = {},
         beforeReceipt: @escaping () throws -> Void = {}, now: @escaping () -> Date = { Date() }) throws {
        self.fileCache = fileCache
        self.directory = directory
        self.availableBytes = availableBytes
        self.send = send
        self.beforeCommit = beforeCommit
        self.beforeReceipt = beforeReceipt
        self.now = now
        let url = directory.appending(path: "receipts.json")
        receipts = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([WatchContentReceipt].self, from: Data(contentsOf: url)) : []
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
        try drain()
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
        if receipts.contains(where: { $0.file == file && $0.status == .delivered }), file.matches(url) {
            send(.init(file: file, status: .delivered))
        } else if let receipt = receipts.first(where: { $0.file == file && $0.status == .retrying }),
                  let retryAt = receipt.retryAt, retryAt > now() {
            send(receipt)
        } else if !FileManager.default.fileExists(atPath: directory.appending(path: file.id.uuidString).path) {
            try acknowledge(file, status: .retrying)
        }
    }

    func stagingFailed(_ file: WatchContentFile, error: Error) {
        guard isDesired(file) else { return }
        do {
            if file.matches(fileCache.fileStore.fileURL(file.type, file.filename)) {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try beforeReceipt()
        try JSONEncoder().encode(next).write(to: directory.appending(path: "receipts.json"), options: .atomic)
        receipts = next
        send(receipt)
    }

    private func drain() throws {
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
                try acknowledge(file, status: status, retryAt: retryAt, attempts: attempts)
                if permanent || status == .storageFull { try FileManager.default.removeItem(at: url) }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commit(_ file: WatchContentFile, from url: URL) throws {
        let destination = fileCache.fileStore.fileURL(file.type, file.filename)
        if file.matches(destination) {
            try acknowledge(file, status: .delivered)
            try FileManager.default.removeItem(at: url)
            if file.type == .music { fileCache.noteMusicStored() }
            return
        }
        let staged = url.appending(path: "bytes")
        guard file.matches(staged) else {
            try acknowledge(file, status: .failed)
            try FileManager.default.removeItem(at: url)
            return
        }
        // replacing bytes under the same name also waits for active playback to release them.
        if fileCache.fileStore.exists(file.type, file.filename), fileCache.isInUse(file.type, file.filename) { return }
        // staging already occupies this space, so admission accounts for the pending move.
        guard fileCache.reserve(file.type, file.filename, bytes: file.bytes,
                                availableBytes: availableBytes().map { $0 + file.bytes }, allowOversized: true) else {
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

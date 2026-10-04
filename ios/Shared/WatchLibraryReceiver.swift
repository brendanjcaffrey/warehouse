import Foundation
import Observation

/// receipts are staged synchronously by the delegate and survive process recreation.
@MainActor
@Observable
final class WatchLibraryReceiver {
    private(set) var initialized = false
    private(set) var protocolSelected = false
    var allowsLegacySync: Bool { initialized && !protocolSelected && head == nil }
    private(set) var head: WatchLibraryHead?
    private(set) var snapshot: WatchLibrarySnapshot?
    private(set) var errorMessage: String?
    private(set) var pendingOperations = 0
    var refreshFailed: Bool { errorMessage != nil || head?.failed == true }
    var waitingForUpdate: Bool {
        guard let head, head.libraryID != nil else { return false }
        return snapshot?.head.publisher != head.publisher || snapshot?.head.revision != head.revision
            || snapshot?.head.libraryID != head.libraryID
    }
    var onChanged: () async -> Void = {}
    var onIdle: () -> Void = {}

    private let diagnostics: WatchDiagnostics
    private let database: LibraryDatabase
    nonisolated let directory: URL
    private var runner: Task<Void, Never>?

    init(database: LibraryDatabase, directory: URL = defaultDirectory(), diagnostics: WatchDiagnostics? = nil) {
        self.diagnostics = diagnostics ?? .shared
        self.database = database
        self.directory = directory
        resume()
    }

    nonisolated static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "watch-library-inbox")
    }

    nonisolated static func stage(_ source: URL, directory: URL = defaultDirectory()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    func expect(_ head: WatchLibraryHead) {
        protocolSelected = true
        enqueue {
            _ = try await self.database.expectWatchLibrary(head)
            self.head = try await self.database.watchHead()
            guard self.head?.version == 1 else { throw WatchLibraryError.unsupported }
            try await self.drain()
        }
    }

    func rejectContext() {
        protocolSelected = true
        enqueue {
            try await self.database.selectWatchProtocol()
            throw WatchLibraryError.unsupported
        }
    }

    func resume() {
        enqueue {
            self.protocolSelected = try await self.database.watchProtocolSelected() || self.protocolSelected
            self.head = try await self.database.watchHead()
            self.snapshot = try await self.database.watchSnapshot()
            self.initialized = true
            if self.protocolSelected, self.head == nil { throw WatchLibraryError.unsupported }
            if let head = self.head, head.version != 1 { throw WatchLibraryError.unsupported }
            try await self.drain()
        }
    }

    func received() { resume() }
    func failed(_ error: Error) {
        errorMessage = error.localizedDescription
        diagnostics.record(.init(kind: .metadataFailed, id: head?.publisher ?? UUID(), source: .phone,
                                 error: error, identity: head.map(WatchDiagnosticIdentity.init)))
    }
    func waitForImport() async { await runner?.value }

    private func enqueue(_ operation: @escaping () async throws -> Void) {
        let previous = runner
        pendingOperations += 1
        runner = Task {
            await previous?.value
            defer { pendingOperations -= 1; onIdle() }
            do {
                try await operation()
            } catch {
                failed(error)
            }
            await onChanged()
        }
    }

    private func drain() async throws {
        snapshot = try await database.watchSnapshot()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let retired = try await database.watchRetiredPublishers()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let incoming: WatchLibrarySnapshot
            let incomingBytes: Int64
            do {
                let data = try Data(contentsOf: url)
                incomingBytes = Int64(data.count)
                incoming = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: data)
                _ = try incoming.validatedLibrary()
            } catch {
                failed(error)
                try FileManager.default.removeItem(at: url)
                continue
            }
            if retired.contains(incoming.head.publisher) {
                try FileManager.default.removeItem(at: url)
                continue
            }
            guard let head else { continue }
            guard incoming.head.publisher == head.publisher,
                  incoming.head.revision == head.revision, incoming.head.libraryID == head.libraryID else {
                // a file can precede its context. retain future revisions for the next wakeup.
                if incoming.head.publisher == head.publisher && incoming.head.revision <= head.revision {
                    try FileManager.default.removeItem(at: url)
                }
                continue
            }
            let previous = snapshot?.head
            _ = try await database.importWatchLibrary(incoming)
            snapshot = try await database.watchSnapshot()
            if previous != snapshot?.head, snapshot?.head == incoming.head {
                diagnostics.metadata(.metadataAccepted, head: incoming.head, bytes: incomingBytes)
            }
            errorMessage = nil
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// background tasks remain alive until both queued imports and system delivery finish.
@MainActor
final class WatchLibraryBackgroundLifetime {
    private(set) var activated = false
    private(set) var contentPending = true
    private(set) var importsPending = 0
    private var completions = [() -> Void]()

    func update(activated: Bool, contentPending: Bool, importsPending: Int) {
        self.activated = activated
        self.contentPending = contentPending
        self.importsPending = importsPending
        finishIfIdle()
    }

    func hold(_ completion: @escaping () -> Void) {
        completions.append(completion)
        finishIfIdle()
    }

    func finishIfIdle() {
        guard activated, !contentPending, importsPending == 0 else { return }
        let ready = completions
        completions.removeAll()
        ready.forEach { $0() }
    }
}

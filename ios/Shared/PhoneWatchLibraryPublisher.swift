import Foundation
import SwiftProtobuf

/// persists the latest intent before queueing any system-owned delivery.
@MainActor
final class PhoneWatchLibraryPublisher {
    struct Transport {
        var context: (WatchLibraryHead) throws -> Void
        var outstanding: () -> Set<String>
        var enqueue: (URL, String) -> Void
    }

    private struct Saved: Codable {
        var head: WatchLibraryHead
        var libraryData: Data?
    }

    private let diagnostics: WatchDiagnostics
    private let database: LibraryDatabase
    private let directory: URL
    private let transport: Transport
    private var saved: Saved
    private var runner: Task<Void, Never>?
    private var request = 0
    private(set) var errorMessage: String?

    var onSnapshot: (WatchLibraryHead, WatchLibrarySnapshot?) -> Void = { _, _ in }
    var onSelectionReconciled: ([String]) -> Void = { _ in }

    var head: WatchLibraryHead { saved.head }

    init(database: LibraryDatabase, directory: URL = defaultDirectory(), transport: Transport, diagnostics: WatchDiagnostics? = nil) throws {
        self.diagnostics = diagnostics ?? .shared
        self.database = database
        self.directory = directory
        self.transport = transport
        let stateURL = directory.appending(path: "state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: stateURL))
        } else {
            saved = Saved(head: .init(publisher: UUID(), revision: 1, libraryID: nil, playlistIDs: []), libraryData: nil)
        }
        try persist(saved)
    }

    nonisolated static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "watch-library-publisher")
    }

    nonisolated static func key(_ head: WatchLibraryHead) -> String { "\(head.publisher.uuidString)-\(head.revision)" }

    /// latest request wins even if a database read is suspended during a selection change.
    func publish(identity: String?, playlistIDs: [String]) {
        request += 1
        let generation = request
        let previous = runner
        runner = Task {
            await previous?.value
            guard generation == request else { return }
            var preparing = true
            do {
                if saved.head.libraryID != identity || saved.head.playlistIDs != playlistIDs {
                    try persist(Saved(head: .init(publisher: saved.head.publisher, revision: saved.head.revision + 1,
                                                 libraryID: identity, playlistIDs: playlistIDs), libraryData: nil))
                }
                try? transport.context(saved.head)
                guard let identity else { errorMessage = nil; return }
                let selection = try await database.selectedWatchLibrary(ids: playlistIDs, identity: identity)
                guard generation == request else { return }
                var options = BinaryEncodingOptions()
                options.useDeterministicOrdering = true
                let data = try selection.library.serializedData(options: options)
                if saved.libraryData != data || !saved.head.metadataReady || saved.head.playlistIDs != selection.playlistIDs {
                    var head = saved.head
                    if head.metadataReady || head.playlistIDs != selection.playlistIDs {
                        head = .init(publisher: head.publisher, revision: head.revision + 1,
                                     libraryID: identity, playlistIDs: selection.playlistIDs)
                    }
                    head.metadataReady = true
                    head.failed = nil
                    let snapshot = WatchLibrarySnapshot(head: head, libraryData: data)
                    _ = try snapshot.validatedLibrary()
                    try persist(Saved(head: head, libraryData: data))
                }
                preparing = false
                errorMessage = nil
                onSelectionReconciled(selection.playlistIDs)
                try deliver()
                onSnapshot(saved.head, saved.libraryData.map { WatchLibrarySnapshot(head: saved.head, libraryData: $0) })
            } catch {
                guard generation == request else { return }
                errorMessage = error.localizedDescription
                diagnostics.metadata(.metadataFailed, head: saved.head, error: error)
                if preparing, identity != nil, saved.head.failed != true {
                    var head = WatchLibraryHead(publisher: saved.head.publisher, revision: saved.head.revision + 1,
                                               libraryID: saved.head.libraryID, playlistIDs: saved.head.playlistIDs)
                    head.failed = true
                    try? persist(Saved(head: head, libraryData: nil))
                    try? transport.context(saved.head)
                }
            }
        }
    }

    func waitForPublication() async { await runner?.value }

    private func persist(_ next: Saved) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appending(path: "state.json"), options: .atomic)
        saved = next
        // invalidate obsolete content immediately, but queue metadata before starting its files.
        if next.libraryData == nil { onSnapshot(next.head, nil) }
    }

    private func deliver() throws {
        try transport.context(saved.head)
        guard let data = saved.libraryData, saved.head.metadataReady else { return }
        let key = Self.key(saved.head)
        let outstanding = transport.outstanding()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent != "state.json" && url.lastPathComponent != "\(key).json"
                && !outstanding.contains(url.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        guard !outstanding.contains(key) else { return }
        let url = directory.appending(path: "\(key).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try JSONEncoder().encode(WatchLibrarySnapshot(head: saved.head, libraryData: data)).write(to: url, options: .atomic)
        }
        transport.enqueue(url, key)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        diagnostics.metadata(.metadataPublished, head: saved.head, bytes: (attributes?[.size] as? NSNumber)?.int64Value)
    }
}

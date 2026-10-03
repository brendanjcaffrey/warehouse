import Foundation

/// a phone-owned challenge fences reports to the current selected library.
struct WatchInventoryRequest: Codable, Equatable, Sendable {
    let id: UUID
    let head: WatchLibraryHead

    init(id: UUID = UUID(), head: WatchLibraryHead) { self.id = id; self.head = head }

    var isValid: Bool {
        head.version == 1 && head.revision > 0 && head.metadataReady && head.failed != true && head.libraryID?.isEmpty == false
    }

    func encode() throws -> [String: Any] {
        ["kind": "watchInventoryRequest", "inventory": try JSONEncoder().encode(self)]
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchInventoryRequest", let data = dictionary["inventory"] as? Data,
              let request = try? JSONDecoder().decode(Self.self, from: data), request.isValid else { return nil }
        self = request
    }
}

/// every entry explicitly reports presence or absence; a missing batch never implies missing files.
struct WatchInventoryReport: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let type: LibraryFileType
        let filename: String
        let bytes: Int64?
    }

    static let maximumEntries = 64
    let request: WatchInventoryRequest
    let entries: [Entry]

    var isValid: Bool {
        request.isValid && !entries.isEmpty && entries.count <= Self.maximumEntries
            && entries.allSatisfy { (try? FileStore.checkFilename($0.filename)) != nil && ($0.bytes.map { $0 > 0 } ?? true) }
            && Set(entries.map { "\($0.type.rawValue)/\($0.filename)" }).count == entries.count
    }

    init(request: WatchInventoryRequest, entries: [Entry]) { self.request = request; self.entries = entries }

    func encode() throws -> [String: Any] {
        ["kind": "watchInventoryReport", "inventory": try JSONEncoder().encode(self)]
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchInventoryReport", let data = dictionary["inventory"] as? Data,
              data.count <= 65_536, let report = try? JSONDecoder().decode(Self.self, from: data), report.isValid else { return nil }
        self = report
    }
}

/// pending requests survive metadata import and transport activation; retries can safely replay individual entries.
@MainActor
final class WatchInventoryResponder {
    private let fileStore: FileStore
    private let url: URL
    private let diagnostics: WatchDiagnostics
    private(set) var requests: [WatchInventoryRequest]
    var send: (WatchInventoryReport) -> Bool = { _ in false }

    init(fileStore: FileStore, directory: URL, diagnostics: WatchDiagnostics) {
        self.fileStore = fileStore
        self.diagnostics = diagnostics
        url = directory.appending(path: "inventory-requests.json")
        requests = []
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                requests = Array(try JSONDecoder().decode([WatchInventoryRequest].self, from: Data(contentsOf: url))
                    .filter(\.isValid).suffix(8))
            } catch {
                // these are retryable challenges, not ownership or delivery evidence; damage must not disable the receiver.
                diagnostics.record(.init(kind: .inventoryFailed, id: UUID(), source: .cache, error: error))
            }
        }
    }

    func receive(_ request: WatchInventoryRequest) throws {
        guard request.isValid else { return }
        if !requests.contains(request) { requests.append(request) }
        // obsolete requests cannot grow the durable inbox without bound; the phone retries unanswered challenges.
        requests = Array(requests.suffix(8))
        do { try save() } catch {
            diagnostics.metadata(.inventoryFailed, head: request.head, error: error)
            throw error
        }
    }

    func publish(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) throws {
        guard let head, let snapshot, snapshot.head == head else { return }
        _ = try snapshot.validatedLibrary()
        for request in requests where request.head == head {
            do {
                var batch = [WatchInventoryReport.Entry]()
                var accepted = true
                for type in LibraryFileType.allCases {
                    let names = try type == .music ? snapshot.music : snapshot.artwork
                    for name in names.sorted() {
                        batch.append(.init(type: type, filename: name, bytes: try storedBytes(type, name)))
                        if batch.count == WatchInventoryReport.maximumEntries {
                            accepted = emit(request, entries: batch) && accepted
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !batch.isEmpty { accepted = emit(request, entries: batch) && accepted }
                if accepted {
                    requests.removeAll { $0 == request }
                    try save()
                }
            } catch {
                diagnostics.metadata(.inventoryFailed, head: head, error: error)
                throw error
            }
        }
    }

    private func emit(_ request: WatchInventoryRequest, entries: [WatchInventoryReport.Entry]) -> Bool {
        guard send(.init(request: request, entries: entries)) else { return false }
        diagnostics.record(.init(kind: .inventoryReported, id: request.id, source: .cache,
                                 identity: WatchDiagnosticIdentity(request.head)))
        return true
    }

    private func storedBytes(_ type: LibraryFileType, _ filename: String) throws -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileStore.fileURL(type, filename).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
            return bytes
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            // unreadable storage is not evidence that the watch lost a file.
            throw error
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(requests).write(to: url, options: .atomic)
    }
}

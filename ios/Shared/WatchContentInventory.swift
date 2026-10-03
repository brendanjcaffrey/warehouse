import Foundation

/// a phone-owned challenge fences reports to the current selected library.
struct WatchInventoryRequest: Codable, Equatable, Sendable {
    static let minimumInterval: TimeInterval = 24 * 60 * 60
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
    private struct Capture: Codable {
        let request: WatchInventoryRequest
        let entries: [WatchInventoryReport.Entry]
        let capturedAt: Date
    }

    private let fileStore: FileStore
    private let url: URL
    private let captureURL: URL
    private let diagnostics: WatchDiagnostics
    private let now: () -> Date
    private var capture: Capture?
    private(set) var requests: [WatchInventoryRequest]
    var send: (WatchInventoryReport) -> Bool = { _ in false }
    var lastScanAt: Date? { capture?.capturedAt }

    init(fileStore: FileStore, directory: URL, diagnostics: WatchDiagnostics, now: @escaping () -> Date = { Date() }) {
        self.fileStore = fileStore
        self.diagnostics = diagnostics
        self.now = now
        url = directory.appending(path: "inventory-requests.json")
        captureURL = directory.appending(path: "inventory-capture.json")
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
        if FileManager.default.fileExists(atPath: captureURL.path) {
            do { capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: captureURL)) } catch {
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
                if capture?.request != request {
                    if let lastScanAt, now() < lastScanAt.addingTimeInterval(WatchInventoryRequest.minimumInterval) { continue }
                    try scan(request, snapshot: snapshot)
                }
                guard let capture, capture.request == request else { continue }
                var accepted = true
                for start in stride(from: 0, to: capture.entries.count, by: WatchInventoryReport.maximumEntries) {
                    let end = min(start + WatchInventoryReport.maximumEntries, capture.entries.count)
                    accepted = emit(request, entries: Array(capture.entries[start..<end])) && accepted
                }
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

    private func scan(_ request: WatchInventoryRequest, snapshot: WatchLibrarySnapshot) throws {
        var entries = [WatchInventoryReport.Entry]()
        for type in LibraryFileType.allCases {
            let names = try type == .music ? snapshot.music : snapshot.artwork
            for name in names.sorted() { entries.append(.init(type: type, filename: name, bytes: try storedBytes(type, name))) }
        }
        let next = Capture(request: request, entries: entries, capturedAt: now())
        // persist the complete observation before sending any part; retries replay it without another storage scan.
        try JSONEncoder().encode(next).write(to: captureURL, options: .atomic)
        capture = next
        diagnostics.record(.init(kind: .inventoryScanned, id: request.id, source: .cache,
                                 identity: WatchDiagnosticIdentity(request.head)))
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

import Foundation
import Observation

/// a phone-owned challenge fences reports to the current selected library.
struct WatchInventoryRequest: Codable, Equatable, Sendable {
    static let minimumInterval: TimeInterval = 24 * 60 * 60
    let id: UUID
    let head: WatchLibraryHead
    var manualSequence: Int64?
    var isManual: Bool { manualSequence != nil }

    init(id: UUID = UUID(), head: WatchLibraryHead, manualSequence: Int64? = nil) {
        self.id = id; self.head = head; self.manualSequence = manualSequence
    }

    var isValid: Bool {
        (manualSequence.map { $0 > 0 } ?? true) && head.version == 1 && head.revision > 0 && head.metadataReady
            && head.failed != true && head.libraryID?.isEmpty == false
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
        var digest: String?
    }

    static let maximumEntries = 64
    let request: WatchInventoryRequest
    let entries: [Entry]

    var isValid: Bool {
        request.isValid && !entries.isEmpty && entries.count <= Self.maximumEntries
            && entries.allSatisfy { (try? FileStore.checkFilename($0.filename)) != nil && ($0.bytes.map { $0 > 0 } ?? true) }
            && entries.allSatisfy { $0.digest.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? true }
            && (!request.isManual || entries.allSatisfy { ($0.bytes == nil) == ($0.digest == nil) })
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
@Observable
final class WatchInventoryResponder {
    private struct Capture: Codable {
        let request: WatchInventoryRequest
        let entries: [WatchInventoryReport.Entry]
        let capturedAt: Date
    }

    private struct Manual: Codable {
        var sequence: Int64 = 0
        var request: WatchInventoryRequest?
        var completed = false
    }

    private var manual = Manual()
    private let manualURL: URL
    private let worker: WatchContentWorker
    private var currentHead: WatchLibraryHead?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    var pendingOperations: Int { work == nil ? 0 : 1 }
    var onActivityChanged: () -> Void = {}
    var sendRequest: (WatchInventoryRequest) -> Bool = { _ in false }
    private(set) var errorMessage: String?
    var manualPending: Bool { manual.request != nil && !manual.completed }
    var manualFeedback: String? {
        if let errorMessage { return "Sync failed: \(errorMessage). Try again." }
        if manualPending { return "Sync pending. Waiting for iPhone confirmation." }
        return manual.completed ? "Downloaded status synced to iPhone." : nil
    }

    func waitForWork() async { while let work { await work.value } }

    private let fileStore: FileStore
    private let url: URL
    private let captureURL: URL
    private let diagnostics: WatchDiagnostics
    private let now: () -> Date
    private var capture: Capture?
    private(set) var requests: [WatchInventoryRequest]
    var send: (WatchInventoryReport) -> Bool = { _ in false }
    var lastScanAt: Date? { capture?.capturedAt }

    init(fileStore: FileStore, directory: URL, diagnostics: WatchDiagnostics, now: @escaping () -> Date = { Date() },
         worker: WatchContentWorker = WatchContentWorker()) {
        self.worker = worker
        self.fileStore = fileStore
        self.diagnostics = diagnostics
        self.now = now
        manualURL = directory.appending(path: "inventory-manual.json")
        url = directory.appending(path: "inventory-requests.json")
        captureURL = directory.appending(path: "inventory-capture.json")
        requests = []
        if FileManager.default.fileExists(atPath: manualURL.path) {
            do { manual = try JSONDecoder().decode(Manual.self, from: Data(contentsOf: manualURL)) } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    func startManual(head: WatchLibraryHead?) throws {
        guard let head, head.metadataReady, head.failed != true else {
            errorMessage = "Wait for the library update"
            throw WatchLibraryError.notLoaded
        }
        // epoch microseconds exceed the 32-bit int range on watch hardware.
        let sequence = max(manual.sequence + 1, Int64(now().timeIntervalSince1970 * 1_000_000))
        let next = Manual(sequence: sequence, request: WatchInventoryRequest(head: head, manualSequence: sequence))
        do { try saveManual(next) } catch { errorMessage = error.localizedDescription; throw error }
        manual = next
        errorMessage = nil
        retryManual()
    }

    func complete(_ completion: WatchInventoryCompletion) throws {
        guard completion.request == manual.request else { return }
        var next = manual
        next.completed = true
        do { try saveManual(next) } catch { errorMessage = error.localizedDescription; throw error }
        manual = next
        errorMessage = nil
        timer?.cancel()
    }

    private func saveManual(_ value: Manual) throws {
        try FileManager.default.createDirectory(at: manualURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: manualURL, options: .atomic)
    }

    private func retryManual() {
        guard manualPending, let request = manual.request else { return }
        _ = sendRequest(request)
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.retryManual()
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

    func pause() { currentHead = nil }

    func publish(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) throws {
        currentHead = head
        if let head, manualPending, manual.request?.head != head {
            var next = manual
            next.request = nil
            try saveManual(next)
            manual = next
            errorMessage = "Library changed"
            timer?.cancel()
        }
        guard let head, let snapshot, snapshot.head == head else { return }
        _ = try snapshot.validatedLibrary()
        retryManual()
        for request in requests where request.head == head {
            if !request.isManual, manualPending { continue }
            if request.isManual, request != manual.request || manual.completed { continue }
            do {
                if request.isManual, capture?.request != request {
                    scanManual(request, snapshot: snapshot)
                    continue
                }
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

    private func scanManual(_ request: WatchInventoryRequest, snapshot: WatchLibrarySnapshot) {
        guard work == nil else { return }
        work = Task {
            defer { work = nil; onActivityChanged() }
            do {
                var entries = [WatchInventoryReport.Entry]()
                for type in LibraryFileType.allCases {
                    let names = try type == .music ? snapshot.music : snapshot.artwork
                    for name in names.sorted() {
                        let value = try await worker.observe(fileStore.fileURL(type, name))
                        entries.append(.init(type: type, filename: name, bytes: value?.stamp.size, digest: value?.digest))
                    }
                }
                guard requests.contains(request), manual.request == request, currentHead == request.head else { return }
                let next = Capture(request: request, entries: entries, capturedAt: now())
                try JSONEncoder().encode(next).write(to: captureURL, options: .atomic)
                capture = next
                errorMessage = nil
                diagnostics.record(.init(kind: .inventoryManualScanned, id: request.id, source: .cache,
                                         identity: WatchDiagnosticIdentity(request.head)))
                try publish(head: snapshot.head, snapshot: snapshot)
            } catch {
                errorMessage = error.localizedDescription
                diagnostics.metadata(.inventoryFailed, head: request.head, error: error)
            }
        }
        onActivityChanged()
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

/// confirmation follows durable phone state, not system transport completion.
struct WatchInventoryCompletion: Codable, Equatable {
    let request: WatchInventoryRequest

    func encode() throws -> [String: Any] {
        ["kind": "watchInventoryCompletion", "inventory": try JSONEncoder().encode(self)]
    }

    init(request: WatchInventoryRequest) { self.request = request }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchInventoryCompletion", let data = dictionary["inventory"] as? Data,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.request.isValid, value.request.isManual else { return nil }
        self = value
    }
}

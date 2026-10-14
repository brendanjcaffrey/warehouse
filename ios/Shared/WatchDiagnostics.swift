import Foundation
import OSLog

/// legacy reply values remain decodable in saved diagnostic captures.
enum PhoneFileReply: String, Codable, Sendable {
    case accepted, cacheMiss, unauthorized, invalidRequest, duplicate, queueFull, unavailable, transferFailed
}

/// bounded, credential-free events for a paired-device capture.
struct WatchDiagnostic: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cacheHit, queued, phoneAccepted, phoneMiss, requestRejected
        case phoneTransferring, phoneDelivered, phoneFailed, phoneTimedOut
        case httpStarted, httpDelivered, httpFailed, storageFailure, evicted
        case playbackRequested, playbackBuffering, playbackStarted, playbackStalled, playbackRecovered, playbackFailed
        case reachabilityChanged, activationChanged
        case metadataPublished, metadataAccepted, metadataCompleted, metadataFailed
        case contentEnqueued, contentCompleted, contentStaged, contentCommitted, contentReused
        case contentTransferFailed, contentFailed, contentRetry, contentStorageFull, receiptPersisted, receiptSent, receiptQuery, phoneAcknowledged
        case queueWakeup
        case contentProcessingChanged, backgroundStateChanged, backgroundCompleted
        case contentCallbackReceived, contentStagingCompleted, contentStagingFailed, contentCallbackHandled
        case contentQueryReceived, contentQueryHandled
        case metadataCallbackReceived, metadataStagingCompleted, metadataStagingFailed, metadataCallbackHandled
        case contextCallbackReceived, contextCallbackHandled
        case processStarted, scenePhaseChanged, applicationStateChanged
        case sessionActivationRequested, sessionActivationCompleted, backgroundTaskReceived
        case inventoryRequested, inventoryReported, inventoryConfirmed, inventoryMissing, inventoryCompleted, inventoryRejected, inventoryFailed
        case inventoryScanned, inventoryManualRequested, inventoryManualScanned, inventoryVerified

        static func phoneReply(_ reply: PhoneFileReply) -> Self {
            switch reply {
            case .accepted: .phoneAccepted
            case .cacheMiss: .phoneMiss
            case .transferFailed: .phoneFailed
            case .unauthorized, .invalidRequest, .duplicate, .queueFull, .unavailable: .requestRejected
            }
        }
    }

    enum Source: String, Codable, Sendable { case phone, http, cache, system }
    enum Detail: String, Codable, Sendable {
        case reachable, unreachable, activated, inactive
        case bluetooth, headphones, speaker, otherRoute
    }
    enum WaitingReason: String, Codable, Sendable {
        case minimizeStalls, evaluatingBufferingRate, noItem, other
    }

    let identity: WatchDiagnosticIdentity?
    let status: WatchContentStatus?
    let date: Date
    let kind: Kind
    let id: UUID
    let source: Source
    let fileType: LibraryFileType?
    let reply: PhoneFileReply?
    let bytes: Int64?
    let throughput: Double?
    let bufferSeconds: Double?
    let elapsed: TimeInterval?
    let errorDomain: String?
    let errorCode: Int?
    let detail: Detail?
    let waitingReason: WaitingReason?
    var processing: WatchDiagnosticProcessing?
    var background: WatchDiagnosticBackground?
    var completedTasks: Int?
    var lifecycle: WatchDiagnosticLifecycle?

    init(kind: Kind, id: UUID, source: Source, fileType: LibraryFileType? = nil,
         reply: PhoneFileReply? = nil, bytes: Int64? = nil,
         throughput: Double? = nil, bufferSeconds: Double? = nil,
         elapsed: TimeInterval? = nil, error: Error? = nil, detail: Detail? = nil,
         waitingReason: WaitingReason? = nil, date: Date = Date(),
         identity: WatchDiagnosticIdentity? = nil, status: WatchContentStatus? = nil) {
        self.identity = identity
        self.status = status
        self.date = date
        self.kind = kind
        self.id = id
        self.source = source
        self.fileType = fileType
        self.reply = reply
        self.bytes = bytes
        self.throughput = throughput.flatMap { $0.isFinite ? $0 : nil }
        self.bufferSeconds = bufferSeconds.flatMap { $0.isFinite ? $0 : nil }
        self.elapsed = elapsed.flatMap { $0.isFinite ? $0 : nil }
        let nsError = error as NSError?
        // arbitrary error domains and descriptions can contain request urls.
        switch nsError?.domain {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "WCErrorDomain":
            errorDomain = nsError?.domain
            errorCode = nsError?.code
        default:
            errorDomain = nsError == nil ? nil : "other"
            errorCode = nsError?.code
        }
        self.detail = detail
        self.waitingReason = waitingReason
    }
}

struct WatchDiagnosticReport: Codable {
    let capturedAt: Date
    let deviceModel: String
    let systemVersion: String
    let events: [WatchDiagnostic]
    var build: WatchDiagnosticBuild? = WatchDiagnosticBuild()
    var capture: WatchDiagnosticCapture?
    var totals: [String: WatchDiagnosticTotal]?
    var delivery: WatchDeliveryDiagnosticState?
    var pairID: UUID?
    var lifecycle: WatchDiagnosticLifecycle?

    var count: Int { events.count }

    func count(_ kind: WatchDiagnostic.Kind) -> Int {
        events.count { $0.kind == kind }
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(Self.self, from: data)
    }
}

/// one lock covers memory and journal writes so delegate probes persist before any actor hop.
final class WatchDiagnostics: @unchecked Sendable {
    static let defaultCapacity = 4096
    static let shared = WatchDiagnostics(
        storeURL: FileStore.defaultRootURL().appending(path: "watch-diagnostics.json"))
    private let logger = Logger(subsystem: "com.jcaffrey.warehouse", category: "watch-diagnostics")
    private let capacity: Int
    private let logEvents: Bool
    private let storeURL: URL?
    private let lock = NSLock()
    private var storedEvents: [WatchDiagnostic] = []
    var events: [WatchDiagnostic] { lock.withLock { storedEvents } }
    private var lifecycle: WatchDiagnosticLifecycle?
    private var capture: WatchDiagnosticCapture
    private var totals: [String: WatchDiagnosticTotal] = [:]
    private var counted = Set<String>()
    private var checkpointReady = false
    private var journalEntries = 0
    private static let checkpointInterval = 64

    private struct Saved: Codable {
        let report: WatchDiagnosticReport
        let counted: Set<String>
    }

    private struct JournalEntry: Codable {
        let captureID: UUID
        let sequence: Int
        let event: WatchDiagnostic
    }

    init(capacity: Int = WatchDiagnostics.defaultCapacity, logEvents: Bool = true, storeURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.logEvents = logEvents
        self.storeURL = storeURL
        capture = WatchDiagnosticCapture(capacity: self.capacity)
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let saved = try? decoder.decode(Saved.self, from: data)
            if let report = saved?.report ?? WatchDiagnosticReport.decode(data) {
                storedEvents = Array(report.events.suffix(self.capacity))
                capture = report.capture ?? WatchDiagnosticCapture(startedAt: storedEvents.first?.date ?? Date(),
                                                                   totalEvents: report.events.count, capacity: self.capacity)
                capture.capacity = self.capacity
                capture.droppedEvents = capture.totalEvents - storedEvents.count
                totals = report.totals ?? [:]
                counted = saved?.counted ?? []
                checkpointReady = saved != nil
            }
        }
        restoreJournal()
    }

    func record(_ event: WatchDiagnostic) {
        lock.withLock { recordLocked(event) }
    }

    private func recordLocked(_ incoming: WatchDiagnostic) {
        var event = incoming
        event.lifecycle = lifecycle
        append(event)
        persist(event)
        if logEvents, let message = Self.line(for: event) {
            logger.info("\(message, privacy: .public)")
        }
    }

    func startProcess() {
        lock.withLock {
            let current = WatchDiagnosticLifecycle()
            lifecycle = current
            recordLocked(.init(kind: .processStarted, id: current.processID, source: .system))
        }
    }

    func sceneChanged(_ phase: WatchDiagnosticLifecycle.State) {
        lock.withLock {
            guard var current = lifecycle, current.scene != phase else { return }
            current.scene = phase
            lifecycle = current
            recordLocked(.init(kind: .scenePhaseChanged, id: current.processID, source: .system))
        }
    }

    func applicationChanged(_ state: WatchDiagnosticLifecycle.State) {
        lock.withLock {
            guard var current = lifecycle, current.application != state else { return }
            current.application = state
            lifecycle = current
            recordLocked(.init(kind: .applicationStateChanged, id: current.processID, source: .system))
        }
    }

    private func append(_ event: WatchDiagnostic) {
        capture.totalEvents += 1
        let kind = event.kind
        let unique = [WatchDiagnostic.Kind.contentCommitted, .contentReused, .phoneAcknowledged].contains(kind)
        let category = kind == .contentCommitted || kind == .contentReused ? "verified" : kind.rawValue
        if !unique || counted.insert("\(category):\(event.id)").inserted {
            let key = "\(kind.rawValue):\(event.fileType?.rawValue ?? "metadata")"
            var total = totals[key] ?? WatchDiagnosticTotal(firstAt: event.date, lastAt: event.date)
            total.count += 1
            // receipts and queries are control traffic, never newly delivered file bytes.
            if [.contentEnqueued, .contentCompleted, .contentStaged, .contentCommitted, .contentReused,
                .phoneAcknowledged, .metadataPublished, .metadataAccepted].contains(kind) { total.bytes += event.bytes ?? 0 }
            total.firstAt = min(total.firstAt, event.date)
            total.lastAt = max(total.lastAt, event.date)
            totals[key] = total
        }
        storedEvents.append(event)
        if storedEvents.count > capacity { storedEvents.removeFirst(storedEvents.count - capacity) }
        capture.droppedEvents = capture.totalEvents - storedEvents.count
    }

    func report(deviceModel: String, systemVersion: String,
                delivery: WatchDeliveryDiagnosticState? = nil) -> WatchDiagnosticReport {
        lock.withLock { reportLocked(deviceModel: deviceModel, systemVersion: systemVersion, delivery: delivery) }
    }

    private func reportLocked(deviceModel: String, systemVersion: String,
                              delivery: WatchDeliveryDiagnosticState? = nil) -> WatchDiagnosticReport {
        var report = WatchDiagnosticReport(capturedAt: Date(), deviceModel: deviceModel,
                                           systemVersion: systemVersion, events: storedEvents)
        report.capture = capture
        report.totals = totals
        report.delivery = delivery
        report.lifecycle = lifecycle
        return report
    }

    func clear() {
        lock.withLock {
            storedEvents = []
            totals = [:]
            counted = []
            capture = WatchDiagnosticCapture(capacity: capacity)
            checkpointReady = false
            persist(nil)
        }
    }

    private func restoreJournal() {
        guard let storeURL else { return }
        let journal = storeURL.appendingPathExtension("events")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        do {
            let data = try Data(contentsOf: journal)
            if !checkpointReady, !data.isEmpty { capture.persistenceFailed = true }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            for line in lines.dropLast() {
                let entry = try decoder.decode(JournalEntry.self, from: Data(line))
                guard entry.captureID == capture.id, entry.sequence > capture.totalEvents else { continue }
                guard entry.sequence == capture.totalEvents + 1 else { throw CocoaError(.fileReadCorruptFile) }
                append(entry.event)
                journalEntries += 1
            }
            guard lines.last?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            capture.persistenceFailed = true
            checkpointReady = false
        }
    }

    private func persist(_ event: WatchDiagnostic?) {
        guard let storeURL else { return }
        let journal = storeURL.appendingPathExtension("events")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if !checkpointReady || journalEntries >= Self.checkpointInterval || event == nil {
                let report = reportLocked(deviceModel: "", systemVersion: "")
                let data = try encoder.encode(Saved(report: report, counted: counted))
                try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // checkpoint first; replay ignores already checkpointed sequences if journal cleanup is interrupted.
                try data.write(to: storeURL, options: .atomic)
                try Data().write(to: journal, options: .atomic)
                checkpointReady = true
                journalEntries = 0
            } else if let event {
                let entry = JournalEntry(captureID: capture.id, sequence: capture.totalEvents, event: event)
                var data = try encoder.encode(entry)
                data.append(10)
                if !FileManager.default.fileExists(atPath: journal.path) { try Data().write(to: journal, options: .atomic) }
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                journalEntries += 1
            }
        } catch {
            capture.persistenceFailed = true
            checkpointReady = false
            logger.error("diagnostic persistence failed")
        }
    }

    static func line(for event: WatchDiagnostic) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(event),
              let message = String(data: data, encoding: .utf8) else { return nil }
        return message.lowercased()
    }
}

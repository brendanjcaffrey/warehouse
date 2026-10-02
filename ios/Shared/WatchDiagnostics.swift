import Foundation
import OSLog

/// bounded, credential-free events for a paired-device capture.
struct WatchDiagnostic: Codable {
    enum Kind: String, Codable {
        case cacheHit, queued, phoneAccepted, phoneMiss, requestRejected
        case phoneTransferring, phoneDelivered, phoneFailed, phoneTimedOut
        case httpStarted, httpDelivered, httpFailed, storageFailure, evicted
        case playbackRequested, playbackBuffering, playbackStarted, playbackStalled, playbackRecovered, playbackFailed
        case reachabilityChanged, activationChanged
        case metadataPublished, metadataAccepted, metadataCompleted, metadataFailed
        case contentEnqueued, contentCompleted, contentStaged, contentCommitted, contentReused
        case contentTransferFailed, contentFailed, contentRetry, contentStorageFull, receiptPersisted, receiptSent, receiptQuery, phoneAcknowledged
        case queueWakeup

        static func phoneReply(_ reply: PhoneFileReply) -> Self {
            switch reply {
            case .accepted: .phoneAccepted
            case .cacheMiss: .phoneMiss
            case .transferFailed: .phoneFailed
            case .unauthorized, .invalidRequest, .duplicate, .queueFull, .unavailable: .requestRejected
            }
        }
    }

    enum Source: String, Codable { case phone, http, cache, system }
    enum Detail: String, Codable {
        case reachable, unreachable, activated, inactive
        case bluetooth, headphones, speaker, otherRoute
    }
    enum WaitingReason: String, Codable {
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

@MainActor
final class WatchDiagnostics {
    static let shared = WatchDiagnostics(
        storeURL: FileStore.defaultRootURL().appending(path: "watch-diagnostics.json"))
    private let logger = Logger(subsystem: "com.jcaffrey.warehouse", category: "watch-diagnostics")
    private let capacity: Int
    private let logEvents: Bool
    private let storeURL: URL?
    private(set) var events: [WatchDiagnostic] = []
    private var capture: WatchDiagnosticCapture
    private var totals: [String: WatchDiagnosticTotal] = [:]
    private var counted = Set<String>()

    private struct Saved: Codable {
        let report: WatchDiagnosticReport
        let counted: Set<String>
    }

    init(capacity: Int = 512, logEvents: Bool = true, storeURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.logEvents = logEvents
        self.storeURL = storeURL
        capture = WatchDiagnosticCapture(capacity: self.capacity)
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let saved = try? decoder.decode(Saved.self, from: data)
            if let report = saved?.report ?? WatchDiagnosticReport.decode(data) {
                events = Array(report.events.suffix(self.capacity))
                capture = report.capture ?? WatchDiagnosticCapture(startedAt: events.first?.date ?? Date(),
                                                                   totalEvents: report.events.count, capacity: self.capacity)
                capture.capacity = self.capacity
                capture.droppedEvents = capture.totalEvents - events.count
                totals = report.totals ?? [:]
                counted = saved?.counted ?? []
            }
        }
    }

    func record(_ event: WatchDiagnostic) {
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
            total.lastAt = event.date
            totals[key] = total
        }
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        capture.droppedEvents = capture.totalEvents - events.count
        persist()
        if logEvents, let message = Self.line(for: event) {
            logger.info("\(message, privacy: .public)")
        }
    }

    func report(deviceModel: String, systemVersion: String,
                delivery: WatchDeliveryDiagnosticState? = nil) -> WatchDiagnosticReport {
        var report = WatchDiagnosticReport(capturedAt: Date(), deviceModel: deviceModel,
                                           systemVersion: systemVersion, events: events)
        report.capture = capture
        report.totals = totals
        report.delivery = delivery
        return report
    }

    func clear() {
        events = []
        totals = [:]
        counted = []
        capture = WatchDiagnosticCapture(capacity: capacity)
        persist()
    }

    private func persist() {
        guard let storeURL else { return }
        let report = report(deviceModel: "", systemVersion: "")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(Saved(report: report, counted: counted))
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            capture.persistenceFailed = true
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

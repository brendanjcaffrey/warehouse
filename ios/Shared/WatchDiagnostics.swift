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
         waitingReason: WaitingReason? = nil, date: Date = Date()) {
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

    init(capacity: Int = 512, logEvents: Bool = true, storeURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.logEvents = logEvents
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let report = WatchDiagnosticReport.decode(data) {
            events = Array(report.events.suffix(self.capacity))
        }
    }

    func record(_ event: WatchDiagnostic) {
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        persist()
        if logEvents, let message = Self.line(for: event) {
            logger.info("\(message, privacy: .public)")
        }
    }

    func report(deviceModel: String, systemVersion: String) -> WatchDiagnosticReport {
        WatchDiagnosticReport(capturedAt: Date(), deviceModel: deviceModel,
                              systemVersion: systemVersion, events: events)
    }

    func clear() {
        events = []
        persist()
    }

    private func persist() {
        guard let storeURL else { return }
        let report = report(deviceModel: "", systemVersion: "")
        guard let data = report.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
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

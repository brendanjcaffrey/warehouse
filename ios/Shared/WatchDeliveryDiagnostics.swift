import CryptoKit
import Foundation

/// only opaque namespaces cross the diagnostic boundary, never library or playlist names.
struct WatchDiagnosticIdentity: Codable, Equatable {
    let publisher: UUID
    let revision: Int64
    let library: String?

    init(_ head: WatchLibraryHead) {
        publisher = head.publisher
        revision = head.revision
        library = head.libraryID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
}

struct WatchDiagnosticTotal: Codable, Equatable {
    var count = 0
    var bytes: Int64 = 0
    var firstAt: Date
    var lastAt: Date
}

struct WatchDiagnosticCapture: Codable {
    var id = UUID()
    var startedAt = Date()
    var totalsStartedAt: Date? = Date()
    var totalEvents = 0
    var droppedEvents = 0
    var capacity: Int
    var persistenceFailed = false
}

struct WatchDiagnosticBuild: Codable {
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    var number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    #if targetEnvironment(simulator)
    var simulator = true
    #else
    var simulator = false
    #endif
}

/// bytes are known sizes only; unknown sizes remain explicitly countable.
struct WatchDiagnosticFiles: Codable {
    var count = 0
    var bytes: Int64 = 0
    var unknownBytes = 0

    mutating func add(bytes: Int64?) {
        count += 1
        if let bytes { self.bytes += bytes } else { unknownBytes += 1 }
    }
}

struct WatchDiagnosticInventory: Codable {
    var desired = WatchDiagnosticFiles()
    var delivered = WatchDiagnosticFiles()
    var pending = WatchDiagnosticFiles()
    var failed = WatchDiagnosticFiles()
    var states: [String: Int] = [:]

    mutating func add(status: WatchContentStatus, bytes: Int64?) {
        desired.add(bytes: bytes)
        states[status.rawValue, default: 0] += 1
        switch status {
        case .delivered: delivered.add(bytes: bytes)
        case .failed: failed.add(bytes: bytes)
        default: pending.add(bytes: bytes)
        }
    }
}

struct WatchDeliveryDiagnosticState: Codable {
    enum Peer: String, Codable { case phone, watch }
    let peer: Peer
    var head: WatchDiagnosticIdentity?
    var inventoryHead: WatchDiagnosticIdentity?
    var music = WatchDiagnosticInventory()
    var artwork = WatchDiagnosticInventory()
    var localMusic: WatchDiagnosticFiles?
    var localArtwork: WatchDiagnosticFiles?
    var availableBytes: Int64?
    var systemOutstanding: Int?
    var transportAvailable: Bool?
    var receiptWait: Int?
    var stagedFiles: Int?
    var nextAttemptAt: Date?

    mutating func add(type: LibraryFileType, status: WatchContentStatus, bytes: Int64?) {
        if type == .music { music.add(status: status, bytes: bytes) } else { artwork.add(status: status, bytes: bytes) }
    }

    static func local(_ entries: [FileEntry]) -> WatchDiagnosticFiles {
        var result = WatchDiagnosticFiles()
        for entry in entries { result.add(bytes: entry.sizeBytes) }
        return result
    }
}

extension WatchDiagnostics {
    func delivery(_ kind: WatchDiagnostic.Kind, file: WatchContentFile, source: WatchDiagnostic.Source,
                  status: WatchContentStatus? = nil, error: Error? = nil) {
        record(.init(kind: kind, id: file.id, source: source, fileType: file.type,
                     bytes: file.bytes, error: error, identity: WatchDiagnosticIdentity(file.head), status: status))
    }

    func metadata(_ kind: WatchDiagnostic.Kind, head: WatchLibraryHead, bytes: Int64? = nil, error: Error? = nil) {
        record(.init(kind: kind, id: head.publisher, source: .phone, bytes: bytes, error: error,
                     identity: WatchDiagnosticIdentity(head)))
    }
}

import CryptoKit
import Foundation

/// immutable bytes bound to one desired revision, without server credentials.
struct WatchContentFile: Codable, Equatable, Sendable {
    var version = 1
    let id: UUID
    let head: WatchLibraryHead
    let type: LibraryFileType
    let filename: String
    let bytes: Int64
    let digest: String

    func validate() throws {
        guard version == 1, head.version == 1, head.metadataReady, head.failed != true,
              head.revision > 0, head.libraryID?.isEmpty == false, bytes > 0,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw WatchLibraryError.invalid }
        try FileStore.checkFilename(filename)
    }

    func encode(kind: String = "watchContentFile") throws -> [String: Any] {
        ["kind": kind, "watchContentFile": try JSONEncoder().encode(self)]
    }

    init?(dictionary: [String: Any]) {
        guard let data = dictionary["watchContentFile"] as? Data,
              let file = try? JSONDecoder().decode(Self.self, from: data), (try? file.validate()) != nil else { return nil }
        self = file
    }

    init(id: UUID = UUID(), head: WatchLibraryHead, type: LibraryFileType, filename: String, bytes: Int64, digest: String) {
        self.id = id
        self.head = head
        self.type = type
        self.filename = filename
        self.bytes = bytes
        self.digest = digest
    }

    static func fingerprint(_ url: URL) throws -> (bytes: Int64, digest: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(data.count)
            hash.update(data: data)
        }
        return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func matches(_ url: URL) -> Bool {
        guard let actual = try? Self.fingerprint(url) else { return false }
        return actual.bytes == bytes && actual.digest == digest
    }
}

enum WatchContentStatus: String, Codable, Sendable {
    case pending, missingOnPhone, transferring, awaitingReceipt, delivered, retrying, storageFull, failed
}

struct WatchContentReceipt: Codable, Equatable, Sendable {
    let file: WatchContentFile
    let status: WatchContentStatus
    var retryAt: Date?
    var attempts: Int?

    func encode() throws -> [String: Any] { ["kind": "watchContentReceipt", "receipt": try JSONEncoder().encode(self)] }

    init(file: WatchContentFile, status: WatchContentStatus) { self.file = file; self.status = status; retryAt = nil; attempts = nil }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchContentReceipt", let data = dictionary["receipt"] as? Data,
              let receipt = try? JSONDecoder().decode(Self.self, from: data), (try? receipt.file.validate()) != nil,
              [.delivered, .retrying, .storageFull, .failed].contains(receipt.status) else { return nil }
        self = receipt
    }
}

import Foundation

/// correlates a phone file transfer with the watch cache fill that requested it.
/// credentials travel only in the request, never in persisted transfer metadata.
struct WatchFileTransfer: Equatable, Codable, Sendable {
    let id: UUID
    let generation: UUID
    let type: LibraryFileType
    let filename: String

    init(id: UUID = UUID(), generation: UUID = UUID(), type: LibraryFileType, filename: String) {
        self.id = id
        self.generation = generation
        self.type = type
        self.filename = filename
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "cachedFile",
              let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID),
              let rawGeneration = dictionary["generation"] as? String, let generation = UUID(uuidString: rawGeneration),
              let rawType = dictionary["fileType"] as? String, let type = LibraryFileType(rawValue: rawType),
              let filename = dictionary["filename"] as? String,
              Self.validFilename(filename)
        else { return nil }
        self.init(id: id, generation: generation, type: type, filename: filename)
    }

    static func validFilename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.hasPrefix(".") && !filename.contains("/") && !filename.contains("\0")
    }

    func encode() -> [String: Any] {
        ["kind": "cachedFile", "id": id.uuidString, "generation": generation.uuidString,
         "fileType": type.rawValue, "filename": filename]
    }

    var file: FileToDownload { FileToDownload(type: type, filename: filename) }

    /// the system removes an incoming file when its delegate returns. copy it
    /// synchronously before hopping to the main actor, then consume the copy.
    static func stage(_ source: URL, metadata: [String: Any]?) -> (WatchFileTransfer, URL)? {
        guard let metadata, let transfer = WatchFileTransfer(dictionary: metadata) else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            return (transfer, temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
    }
}

/// an accepted request is queued, not delivered. failures retain their cause
/// across the messaging boundary without carrying credentials into metadata.
enum PhoneFileReply: String, Codable, Sendable {
    case accepted, cacheMiss, unauthorized, invalidRequest, duplicate, queueFull, unavailable, transferFailed
}

struct PhoneFileProgress: Sendable {
    let transfer: WatchFileTransfer
    let fraction: Double

    init(transfer: WatchFileTransfer, fraction: Double = 0) {
        self.transfer = transfer
        self.fraction = fraction
    }

    init?(dictionary: [String: Any]) {
        guard let transfer = WatchFileTransfer(dictionary: dictionary),
              let fraction = dictionary["fraction"] as? Double, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        self.init(transfer: transfer, fraction: fraction)
    }

    func encode() -> [String: Any] {
        var message = transfer.encode()
        message["fraction"] = fraction
        return message
    }
}

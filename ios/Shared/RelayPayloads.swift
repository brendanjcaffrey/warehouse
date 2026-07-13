import Foundation

/// dictionary schemas for the messages the watch & phone exchange to relay
/// syncs through the phone, so the watch never talks to the server directly

extension FileToDownload {
    /// a single-string form like "music/abc123.mp3", used inside payloads
    var pathKey: String {
        "\(type.directory)/\(filename)"
    }

    init?(pathKey: String) {
        let parts = pathKey.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let type = LibraryFileType(rawValue: String(parts[0])),
              !parts[1].isEmpty
        else {
            return nil
        }
        self.init(type: type, filename: String(parts[1]))
    }
}

/// the bare request dictionaries that carry no data beyond their type
enum RelayRequest {
    static let typeKey = "type"
    static let version = "versionRequest"
    static let library = "libraryRequest"
    static let cancelFileRequests = "cancelFileRequests"

    private static let acceptedKey = "accepted"

    static func encode(_ type: String) -> [String: Any] {
        [typeKey: type]
    }

    static func matches(_ dictionary: [String: Any], _ type: String) -> Bool {
        dictionary[typeKey] as? String == type
    }

    /// the immediate reply to a library request; the data itself follows as
    /// a file transfer
    static func acceptedReply() -> [String: Any] {
        [acceptedKey: true]
    }

    static func isAccepted(_ dictionary: [String: Any]) -> Bool {
        dictionary[acceptedKey] as? Bool == true
    }
}

/// the phone's reply to a version request: the server's library timestamp,
/// a server error, or the phone being unable to reach the server
enum VersionReply: Equatable {
    case updateTimeNs(Int64)
    case error(String)
    case offline

    private static let updateTimeNsKey = "updateTimeNs"
    private static let errorKey = "error"
    private static let offlineKey = "offline"

    init?(dictionary: [String: Any]) {
        if let updateTimeNs = (dictionary[Self.updateTimeNsKey] as? NSNumber)?.int64Value {
            self = .updateTimeNs(updateTimeNs)
        } else if let message = dictionary[Self.errorKey] as? String {
            self = .error(message)
        } else if dictionary[Self.offlineKey] as? Bool == true {
            self = .offline
        } else {
            return nil
        }
    }

    func encode() -> [String: Any] {
        switch self {
        case .updateTimeNs(let updateTimeNs):
            return [Self.updateTimeNsKey: NSNumber(value: updateTimeNs)]
        case .error(let message):
            return [Self.errorKey: message]
        case .offline:
            return [Self.offlineKey: true]
        }
    }
}

/// a batch of files the watch asks the phone to send over; re-sent with the
/// current missing list while a sync is running, so requests are idempotent
struct FileRequestPayload: Equatable {
    /// caps the encoded size; the watch re-requests once these arrive
    static let maxFiles = 200

    let id: String
    let files: [FileToDownload]
    let priority: Bool

    private static let type = "fileRequest"
    private static let idKey = "id"
    private static let filesKey = "files"
    private static let priorityKey = "priority"

    init(id: String = UUID().uuidString, files: [FileToDownload], priority: Bool = false) {
        self.id = id
        self.files = Array(files.prefix(Self.maxFiles))
        self.priority = priority
    }

    init?(dictionary: [String: Any]) {
        guard RelayRequest.matches(dictionary, Self.type),
              let id = dictionary[Self.idKey] as? String,
              let pathKeys = dictionary[Self.filesKey] as? [String],
              let priority = dictionary[Self.priorityKey] as? Bool
        else {
            return nil
        }
        self.init(id: id, files: pathKeys.compactMap(FileToDownload.init(pathKey:)), priority: priority)
    }

    func encode() -> [String: Any] {
        [
            RelayRequest.typeKey: Self.type,
            Self.idKey: id,
            Self.filesKey: files.map(\.pathKey),
            Self.priorityKey: priority
        ]
    }
}

/// the phone's answer once a file request has fully drained: which of its
/// files the phone doesn't have in its own library (everything else was sent)
struct FileResultPayload: Equatable {
    let requestId: String
    let failed: [FileToDownload]

    private static let type = "fileResult"
    private static let requestIdKey = "requestId"
    private static let failedKey = "failed"

    init(requestId: String, failed: [FileToDownload]) {
        self.requestId = requestId
        self.failed = failed
    }

    init?(dictionary: [String: Any]) {
        guard RelayRequest.matches(dictionary, Self.type),
              let requestId = dictionary[Self.requestIdKey] as? String,
              let pathKeys = dictionary[Self.failedKey] as? [String]
        else {
            return nil
        }
        self.init(requestId: requestId, failed: pathKeys.compactMap(FileToDownload.init(pathKey:)))
    }

    func encode() -> [String: Any] {
        [
            RelayRequest.typeKey: Self.type,
            Self.requestIdKey: requestId,
            Self.failedKey: failed.map(\.pathKey)
        ]
    }
}

/// sent by the phone when fetching the library from the server fails, since
/// a successful fetch is announced by the library file itself arriving
struct LibraryResultPayload: Equatable {
    let error: String

    private static let type = "libraryResult"
    private static let errorKey = "error"

    init(error: String) {
        self.error = error
    }

    init?(dictionary: [String: Any]) {
        guard RelayRequest.matches(dictionary, Self.type),
              let error = dictionary[Self.errorKey] as? String
        else {
            return nil
        }
        self.init(error: error)
    }

    func encode() -> [String: Any] {
        [
            RelayRequest.typeKey: Self.type,
            Self.errorKey: error
        ]
    }
}

/// identifies what a watch connectivity file transfer contains: the library
/// proto or a single music/artwork file
enum FileTransferMetadata: Equatable {
    case library(updateTimeNs: Int64)
    case file(FileToDownload)

    private static let kindKey = "kind"
    private static let libraryKind = "library"
    private static let fileKind = "file"
    private static let updateTimeNsKey = "updateTimeNs"
    private static let fileTypeKey = "fileType"
    private static let filenameKey = "filename"

    init?(dictionary: [String: Any]?) {
        switch dictionary?[Self.kindKey] as? String {
        case Self.libraryKind:
            guard let updateTimeNs = (dictionary?[Self.updateTimeNsKey] as? NSNumber)?.int64Value else {
                return nil
            }
            self = .library(updateTimeNs: updateTimeNs)
        case Self.fileKind:
            guard let rawType = dictionary?[Self.fileTypeKey] as? String,
                  let type = LibraryFileType(rawValue: rawType),
                  let filename = dictionary?[Self.filenameKey] as? String,
                  !filename.isEmpty
            else {
                return nil
            }
            self = .file(FileToDownload(type: type, filename: filename))
        default:
            return nil
        }
    }

    func encode() -> [String: Any] {
        switch self {
        case .library(let updateTimeNs):
            return [
                Self.kindKey: Self.libraryKind,
                Self.updateTimeNsKey: NSNumber(value: updateTimeNs)
            ]
        case .file(let file):
            return [
                Self.kindKey: Self.fileKind,
                Self.fileTypeKey: file.type.rawValue,
                Self.filenameKey: file.filename
            ]
        }
    }
}

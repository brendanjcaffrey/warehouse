import Foundation

/// each owner has one serial executor for bulk io; it never owns selection or cache state.
actor WatchContentWorker {
    struct Stamp: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let modified: Date

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
                throw WatchLibraryError.invalid
            }
            self.inode = inode.uint64Value
            self.size = size.int64Value
            self.modified = modified
        }

        func stillMatches(_ url: URL) -> Bool { (try? Stamp(url)) == self }
    }

    private let beforeWork: @Sendable () throws -> Void

    init(beforeWork: @escaping @Sendable () throws -> Void = {}) { self.beforeWork = beforeWork }

    func verify(_ file: WatchContentFile, at url: URL) throws -> Stamp? {
        try Task.checkCancellation()
        try beforeWork()
        do {
            let stamp = try Stamp(url)
            guard stamp.size == file.bytes else { return nil }
            let actual = try WatchContentFile.fingerprint(url)
            try Task.checkCancellation()
            return actual.bytes == file.bytes && actual.digest == file.digest && stamp.stillMatches(url) ? stamp : nil
        } catch {
            if WatchDeliveryState.isMissing(error) { return nil }
            throw error
        }
    }

    struct Observation: Sendable {
        let stamp: Stamp
        let digest: String
    }

    func observe(_ url: URL) throws -> Observation? {
        try Task.checkCancellation()
        try beforeWork()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            let stamp = try Stamp(url)
            guard stamp.size > 0 else { return nil }
            let value = try WatchContentFile.fingerprint(url)
            guard value.bytes == stamp.size, stamp.stillMatches(url) else { throw WatchLibraryError.invalid }
            return Observation(stamp: stamp, digest: value.digest)
        } catch {
            if WatchDeliveryState.isMissing(error) { return nil }
            throw error
        }
    }

    struct Preparation: Sendable {
        let id: UUID
        let head: WatchLibraryHead
        let type: LibraryFileType
        let filename: String
        let original: URL
        let recovered: WatchContentFile?
        let recoveryURL: URL?
        let copy: URL
    }

    func prepare(_ request: Preparation) throws -> WatchContentFile {
        let (id, head, type, filename) = (request.id, request.head, request.type, request.filename)
        let (original, recovered, recoveryURL, copy) = (request.original, request.recovered, request.recoveryURL, request.copy)
        try Task.checkCancellation()
        try beforeWork()
        let source: URL
        if let recovered, let recoveryURL, try verify(recovered, at: recoveryURL) != nil {
            // compatible recovery queries its original transfer identity before any resend.
            if head.retainsContent(from: recovered.head) { return recovered }
            source = recoveryURL
        } else {
            source = original
        }
        // fingerprint the private copy so ordinary phone sync can subsequently remove the original.
        try FileManager.default.copyItem(at: source, to: copy)
        let fingerprint = try WatchContentFile.fingerprint(copy)
        try Task.checkCancellation()
        let file = WatchContentFile(id: id, head: head, type: type, filename: filename,
                                    bytes: fingerprint.bytes, digest: fingerprint.digest)
        try file.validate()
        return file
    }
}

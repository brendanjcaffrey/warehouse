import Foundation

enum LibraryFileType: String, CaseIterable, Codable, Sendable {
    case music
    case artwork

    /// subdirectory on disk and url path prefix on the server
    var directory: String { rawValue }
}

/// counts & sizes of everything downloaded, shown in settings
struct DownloadStats: Equatable, Sendable {
    var trackCount = 0
    var artworkCount = 0
    var totalBytes: Int64 = 0
}

/// used & total capacity of the device, shown in settings; the available
/// count is what the file cache sizes its budget against
struct DeviceStorage: Equatable, Sendable {
    let usedBytes: Int64
    let totalBytes: Int64
    let availableBytes: Int64
}

/// one file on disk, as the cache's eviction pass needs to see it
struct FileEntry: Equatable, Sendable {
    let filename: String
    let sizeBytes: Int64
    /// stands in for last-used when the recency index has no entry for the
    /// file, which is the case for anything the mirror sync left behind
    let createdAt: Date
}

/// stores downloaded music & artwork files under a root directory,
/// mirroring the server's filenames (md5-based, extension included)
struct FileStore: Sendable {
    enum FilenameError: Error, Equatable {
        case invalid(String)
    }

    let rootURL: URL

    static func defaultRootURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "files")
    }

    /// creates the music/artwork directories and excludes them from backups
    func prepare() throws {
        for type in LibraryFileType.allCases {
            var url = directoryURL(type)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
    }

    func directoryURL(_ type: LibraryFileType) -> URL {
        rootURL.appending(path: type.directory)
    }

    func fileURL(_ type: LibraryFileType, _ filename: String) -> URL {
        directoryURL(type).appending(path: filename)
    }

    func exists(_ type: LibraryFileType, _ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(type, filename).path)
    }

    func write(_ type: LibraryFileType, _ filename: String, data: Data) throws {
        try Self.checkFilename(filename)
        try FileManager.default.createDirectory(at: directoryURL(type), withIntermediateDirectories: true)
        try data.write(to: fileURL(type, filename), options: .atomic)
    }

    /// moves a freshly downloaded file into the store, replacing whatever was
    /// there; the source is consumed either way, a rejected filename included
    func moveIn(_ type: LibraryFileType, _ filename: String, from source: URL) throws {
        do {
            try Self.checkFilename(filename)
            try FileManager.default.createDirectory(at: directoryURL(type), withIntermediateDirectories: true)
            let destination = fileURL(type, filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: source)
            throw error
        }
    }

    func delete(_ type: LibraryFileType, _ filename: String) throws {
        try Self.checkFilename(filename)
        try FileManager.default.removeItem(at: fileURL(type, filename))
    }

    func list(_ type: LibraryFileType) -> Set<String> {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryURL(type).path)
        return Set(contents ?? [])
    }

    /// deletes every file of the given type that isn't in the keeping set
    func deleteFiles(_ type: LibraryFileType, keeping: Set<String>) {
        for filename in list(type).subtracting(keeping) {
            try? delete(type, filename)
        }
    }

    func downloadStats() -> DownloadStats {
        let music = entries(.music)
        let artwork = entries(.artwork)
        return DownloadStats(
            trackCount: music.count,
            artworkCount: artwork.count,
            totalBytes: totalSize(of: music) + totalSize(of: artwork))
    }

    /// every file of the given type with the metadata eviction sorts on
    func entries(_ type: LibraryFileType) -> [FileEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL(type),
            includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(
                filename: url.lastPathComponent,
                sizeBytes: Int64(values?.fileSize ?? 0),
                createdAt: values?.creationDate ?? .distantPast)
        }
    }

    func totalSize(_ type: LibraryFileType) -> Int64 {
        totalSize(of: entries(type))
    }

    static func deviceStorage() -> DeviceStorage? {
        #if os(watchOS)
        // the important-usage capacity key doesn't exist on watchos, and the
        // plain capacity keys are typed as int, which is 32 bits there, so
        // they wrap on any volume over 2gb. the file system attributes come
        // back as nsnumbers and survive the trip. the home directory is on the
        // same volume as application support and always exists
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let total = (attributes?[.systemSize] as? NSNumber)?.int64Value,
              let available = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        return DeviceStorage(
            usedBytes: total - available,
            totalBytes: total,
            availableBytes: available)
        #else
        let values = try? URL.applicationSupportDirectory.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return DeviceStorage(
            usedBytes: Int64(total) - available,
            totalBytes: Int64(total),
            availableBytes: available)
        #endif
    }

    /// filenames come from the server's library data & are md5-based; anything
    /// that could climb out of the type directory is not one of ours. only the
    /// methods that mutate the filesystem check, since a name this rejects
    /// should never reach the read paths either. throwing rather than skipping
    /// keeps a compromised library from looking like a network failure
    private static func checkFilename(_ filename: String) throws {
        guard !filename.isEmpty, !filename.hasPrefix("."), !filename.contains("/") else {
            throw FilenameError.invalid(filename)
        }
    }

    private func totalSize(of files: [FileEntry]) -> Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }
}

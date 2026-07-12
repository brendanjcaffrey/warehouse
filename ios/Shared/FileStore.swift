import Foundation

enum LibraryFileType: String, CaseIterable, Sendable {
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

/// used & total capacity of the device, shown in settings
struct DeviceStorage: Equatable, Sendable {
    let usedBytes: Int64
    let totalBytes: Int64
}

/// stores downloaded music & artwork files under a root directory,
/// mirroring the server's filenames (md5-based, extension included)
struct FileStore: Sendable {
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
        try FileManager.default.createDirectory(at: directoryURL(type), withIntermediateDirectories: true)
        try data.write(to: fileURL(type, filename), options: .atomic)
    }

    func delete(_ type: LibraryFileType, _ filename: String) throws {
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
        let music = contents(.music)
        let artwork = contents(.artwork)
        return DownloadStats(
            trackCount: music.count,
            artworkCount: artwork.count,
            totalBytes: totalSize(of: music) + totalSize(of: artwork))
    }

    static func deviceStorage() -> DeviceStorage? {
        #if os(watchOS)
        // the important-usage capacity key doesn't exist on watchos
        let values = try? URL.applicationSupportDirectory.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacity else { return nil }
        return DeviceStorage(usedBytes: Int64(total - available), totalBytes: Int64(total))
        #else
        let values = try? URL.applicationSupportDirectory.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return DeviceStorage(usedBytes: Int64(total) - available, totalBytes: Int64(total))
        #endif
    }

    private func contents(_ type: LibraryFileType) -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL(type),
            includingPropertiesForKeys: [.fileSizeKey])
        return urls ?? []
    }

    private func totalSize(of files: [URL]) -> Int64 {
        files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}

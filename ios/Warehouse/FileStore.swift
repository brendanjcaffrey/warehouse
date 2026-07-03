import Foundation

enum LibraryFileType: String, CaseIterable, Sendable {
    case music
    case artwork

    /// subdirectory on disk and url path prefix on the server
    var directory: String { rawValue }
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
}

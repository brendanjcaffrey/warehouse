import Foundation
import Observation

/// artwork arrives through durable phone delivery; browsing only reads local files.
@MainActor
final class WatchArtworkFetcher {
    private let fileStore: FileStore
    private var files: [String: ArtworkFile] = [:]

    @Observable
    fileprivate final class ArtworkFile {
        var identity: UUID?
        @ObservationIgnored private var stamp: Stamp?

        struct Stamp: Equatable {
            let inode: UInt64
            let bytes: Int64
            let modified: Date

            init?(_ url: URL) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let inode = attributes[.systemFileNumber] as? NSNumber,
                      let bytes = attributes[.size] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date else { return nil }
                self.inode = inode.uint64Value
                self.bytes = bytes.int64Value
                self.modified = modified
            }
        }

        init(url: URL) { refresh(url) }

        func refresh(_ url: URL) {
            let next = Stamp(url)
            guard next != stamp else { return }
            stamp = next
            identity = next == nil ? nil : UUID()
        }
    }

    init(fileCache: FileCache) {
        fileStore = fileCache.fileStore
        fileCache.onArtworkChanged = { [weak self] filename in
            guard let self, let file = files[filename] else { return }
            file.refresh(fileStore.fileURL(.artwork, filename))
        }
    }

    /// only the requested file is observed; repeated row reads never probe the disk.
    func request(_ filename: String?, maxPixelSize: Int = 56) -> WatchArtworkRequest {
        guard let filename, (try? FileStore.checkFilename(filename)) != nil else {
            return WatchArtworkRequest(filename: filename, maxPixelSize: maxPixelSize)
        }
        let url = fileStore.fileURL(.artwork, filename)
        let file: ArtworkFile
        if let existing = files[filename] {
            file = existing
        } else {
            file = ArtworkFile(url: url)
            files[filename] = file
        }
        let identity = file.identity
        return WatchArtworkRequest(filename: filename, maxPixelSize: maxPixelSize,
                                   url: identity == nil ? nil : url, contentIdentity: identity)
    }

    func artworkURL(_ filename: String?) -> URL? {
        guard let filename, fileStore.exists(.artwork, filename) else { return nil }
        return fileStore.fileURL(.artwork, filename)
    }
}

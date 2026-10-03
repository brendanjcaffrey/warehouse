import Foundation

/// artwork arrives through durable phone delivery; browsing only reads local files.
@MainActor
final class WatchArtworkFetcher {
    private let fileStore: FileStore

    init(fileStore: FileStore) {
        self.fileStore = fileStore
    }

    func artworkURL(_ filename: String?) -> URL? {
        guard let filename, fileStore.exists(.artwork, filename) else { return nil }
        return fileStore.fileURL(.artwork, filename)
    }
}

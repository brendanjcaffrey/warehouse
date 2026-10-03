import Foundation

/// read-only migration of saved watch selections; preparation belongs to the phone.
@MainActor
final class OfflineLibrary {
    private struct Selection: Decodable {
        let filenames: [String: String]
    }

    private let fileCache: FileCache
    private var manifestURL: URL { fileCache.fileStore.rootURL.appending(path: "offline-playlists.json") }
    private(set) var selectedPlaylistIds: [String] = []

    init(fileCache: FileCache) {
        self.fileCache = fileCache
        if !fileCache.hasWatchSelection, FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                let selections = try JSONDecoder().decode([String: Selection].self, from: Data(contentsOf: manifestURL))
                let filenames = Set(selections.values.flatMap { $0.filenames.values })
                for name in filenames { try FileStore.checkFilename(name) }
                selectedPlaylistIds = selections.keys.sorted()
                fileCache.retainMusic(filenames)
            } catch {
                // unreadable legacy intent must not expose saved music to eviction.
                fileCache.retainMusic(fileCache.fileStore.list(.music))
            }
        }
        retireForPhoneSelection()
    }

    func retireForPhoneSelection() {
        guard fileCache.hasDurableWatchSelection else { return }
        selectedPlaylistIds = []
        try? FileManager.default.removeItem(at: manifestURL)
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class SongsStore {
    private(set) var songs = [Song]()
    private(set) var downloadedMusic = Set<String>()
    private(set) var errorMessage: String?

    private let database: LibraryDatabase
    private let fileStore: FileStore

    init(database: LibraryDatabase, fileStore: FileStore) {
        self.database = database
        self.fileStore = fileStore
    }

    func load() async {
        do {
            songs = try await database.allSongs()
            downloadedMusic = fileStore.list(.music)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isDownloaded(_ song: Song) -> Bool {
        downloadedMusic.contains(song.musicFilename)
    }

    func artworkURL(_ song: Song) -> URL? {
        guard let filename = song.artworkFilename else { return nil }
        return fileStore.fileURL(.artwork, filename)
    }
}

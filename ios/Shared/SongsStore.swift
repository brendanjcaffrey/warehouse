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

    /// persists an edited track & refreshes the songs list so every view
    /// built from it picks up the change
    func applyTrackEdit(_ song: Song) async {
        do {
            try await database.updateTrack(song)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// writes picked artwork into the local artwork directory so thumbnails
    /// can render it before it's uploaded; returns the content addressed filename
    func storeArtwork(_ data: Data) throws -> String {
        guard let prepared = ArtworkFile.prepare(data) else {
            throw ArtworkError.unreadableImage
        }
        try fileStore.write(.artwork, prepared.filename, data: prepared.data)
        return prepared.filename
    }

    enum ArtworkError: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            "The picked image couldn't be read."
        }
    }

    func isDownloaded(_ song: Song) -> Bool {
        downloadedMusic.contains(song.musicFilename)
    }

    func artworkURL(_ song: Song) -> URL? {
        artworkURL(filename: song.artworkFilename)
    }

    func artworkURL(filename: String?) -> URL? {
        guard let filename else { return nil }
        return fileStore.fileURL(.artwork, filename)
    }
}

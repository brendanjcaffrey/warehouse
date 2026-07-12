import Foundation
import Observation

@MainActor
@Observable
final class PlaylistsStore {
    private(set) var playlists = [PlaylistItem]()
    private(set) var errorMessage: String?

    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func load() async {
        do {
            playlists = try await database.allPlaylists()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import Foundation
import Observation

/// local startup readiness is independent of remote refresh progress
@MainActor
@Observable
final class WatchLibraryStore {
    enum State: Equatable {
        case setup
        case loading
        case needsSync
        case empty
        case ready
        case failed(String)
    }

    private(set) var state: State = .loading
    private let songs: SongsStore
    private let playlists: PlaylistsStore
    private let metadata: LibraryMetadata

    init(songs: SongsStore, playlists: PlaylistsStore, defaults: UserDefaults = .standard) {
        self.songs = songs
        self.playlists = playlists
        metadata = LibraryMetadata(defaults: defaults)
    }

    func presentation(isConfigured: Bool) -> State {
        // explicit sign-out hides the saved library; a network failure does not
        isConfigured ? state : .setup
    }

    func load() async {
        await songs.load()
        await playlists.load()
        if let message = songs.errorMessage ?? playlists.errorMessage {
            state = .failed(message)
        } else if !songs.songs.isEmpty {
            state = .ready
        } else if metadata.hasSavedLibrary || !playlists.playlists.isEmpty {
            state = .empty
        } else {
            state = .needsSync
        }
    }
}

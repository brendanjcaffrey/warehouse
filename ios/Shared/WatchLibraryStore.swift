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
    private let receiver: WatchLibraryReceiver?

    init(songs: SongsStore, playlists: PlaylistsStore, defaults: UserDefaults = .standard, receiver: WatchLibraryReceiver? = nil) {
        self.receiver = receiver
        self.songs = songs
        self.playlists = playlists
        metadata = LibraryMetadata(defaults: defaults)
    }

    func presentation(isConfigured: Bool) -> State {
        // saved content does not need server credentials to browse or play.
        if state == .ready || state == .empty { return state }
        return isConfigured ? state : .setup
    }

    func load() async {
        await songs.load()
        await playlists.load()
        if let message = songs.errorMessage ?? playlists.errorMessage {
            state = .failed(message)
        } else if !songs.songs.isEmpty {
            state = .ready
        } else if receiver?.snapshot != nil || metadata.hasSavedLibrary || !playlists.playlists.isEmpty {
            state = .empty
        } else {
            state = .needsSync
        }
    }
}

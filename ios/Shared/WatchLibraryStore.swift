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
    var content: WatchContentReceiver?
    var deliveryStartupError: String?
    var deliveryRecovered = false

    init(songs: SongsStore, playlists: PlaylistsStore, defaults: UserDefaults = .standard, receiver: WatchLibraryReceiver? = nil,
         content: WatchContentReceiver? = nil) {
        self.content = content
        self.receiver = receiver
        self.songs = songs
        self.playlists = playlists
        metadata = LibraryMetadata(defaults: defaults)
    }

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        var progress = content?.progress(playlistID: playlistID) ?? WatchLibraryProgress(state: .setup)
        if let receiver, !receiver.initialized || (progress.state == .setup && receiver.head?.libraryID != nil) {
            progress.state = .preparing
        }
        if receiver?.refreshFailed == true { progress.state = .refreshFailed }
        if receiver?.waitingForUpdate == true && progress.state != .refreshFailed { progress.state = .preparing }
        if deliveryStartupError != nil { progress.state = .deliveryUnavailable }
        return progress
    }

    func presentation(isConfigured: Bool) -> State {
        // saved content does not need server credentials to browse or play.
        if state == .ready || state == .empty { return state }
        if receiver?.initialized == false && receiver?.refreshFailed != true { return .loading }
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

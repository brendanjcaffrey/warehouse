import Foundation

/// errors surfaced to siri & the shortcuts app as spoken/displayed messages
enum IntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case loggedOut
    case nothingPlaying
    case notFound
    case emptyPlaylist
    case libraryEmpty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .loggedOut:
            "Please log in to Warehouse first."
        case .nothingPlaying:
            "Nothing is playing."
        case .notFound:
            "That wasn't found in your library."
        case .emptyPlaylist:
            "That playlist is empty."
        case .libraryEmpty:
            "Your library hasn't been synced yet."
        }
    }
}

/// composes the stores intents need, so they can look up library content &
/// start playback without juggling auth tokens or library loading; intents
/// run outside the swiftui environment & reach this through app intents
/// dependency injection
@MainActor
final class IntentPlaybackService {
    private let auth: AuthStore
    private let songs: SongsStore
    private let playlists: PlaylistsStore
    private let player: PlayerStore

    init(auth: AuthStore, songs: SongsStore, playlists: PlaylistsStore, player: PlayerStore) {
        self.auth = auth
        self.songs = songs
        self.playlists = playlists
        self.player = player
    }

    var allSongs: [Song] { songs.songs }
    var allPlaylists: [PlaylistItem] { playlists.playlists }
    var currentSong: Song? { player.song }

    /// loads the library from the local database when an intent runs before
    /// the app's views have, e.g. a background launch straight into an
    /// intent; throws when nobody is logged in
    func prepare() async throws {
        guard auth.token != nil else {
            throw IntentError.loggedOut
        }
        if songs.songs.isEmpty {
            await songs.load()
        }
        if playlists.playlists.isEmpty {
            await playlists.load()
        }
    }

    func artworkURL(filename: String?) -> URL? {
        songs.artworkURL(filename: filename)
    }

    /// starts playback the same way views do, supplying auth so tracks not
    /// yet downloaded can be fetched on demand
    func play(_ songsToPlay: [Song], startingAt index: Int = 0, shuffled: Bool = false) {
        if shuffled {
            player.playShuffled(songsToPlay, token: auth.token, baseURL: auth.baseURL())
        } else {
            player.play(songsToPlay, startingAt: index, token: auth.token, baseURL: auth.baseURL())
        }
    }

    /// rebuilds the spotlight index from the current library; quietly does
    /// nothing when logged out
    func refreshSpotlight() async {
        guard (try? await prepare()) != nil else { return }
        let items = SpotlightIndexer.items(
            songs: allSongs, playlists: allPlaylists, artworkURL: artworkURL(filename:))
        await SpotlightIndexer.donate(items)
    }
}

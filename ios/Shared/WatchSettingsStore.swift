import Foundation
import Observation

/// watch-side copy of the settings pushed from the phone: the server,
/// credentials, which playlists to sync & how far ahead to fill the cache
@MainActor
@Observable
final class WatchSettingsStore {
    private static let serverURLKey = "serverURL"
    private static let playlistIdsKey = "watchPlaylistIds"
    private static let deepPrefetchDepthKey = "deepPrefetchDepth"

    private(set) var serverURL: String
    private(set) var token: String?
    private(set) var playlistIds: [String]
    /// how many tracks past the one about to play the player pulls down while
    /// the app is frontmost; 0 is off
    private(set) var deepPrefetchDepth: Int
    /// bumped whenever the phone changes the playlist selection, so the ui
    /// can kick off a new sync
    private(set) var selectionChanges = 0

    private let defaults: UserDefaults
    private let metadata: LibraryMetadata
    private let writeToken: (String?) -> Void

    // the parameters are here for tests
    init(
        defaults: UserDefaults = .standard,
        readToken: () -> String? = Keychain.readToken,
        writeToken: @escaping (String?) -> Void = Keychain.setToken
    ) {
        self.defaults = defaults
        self.writeToken = writeToken
        metadata = LibraryMetadata(defaults: defaults)
        serverURL = defaults.string(forKey: Self.serverURLKey) ?? ""
        token = readToken()
        playlistIds = defaults.stringArray(forKey: Self.playlistIdsKey) ?? []
        deepPrefetchDepth = defaults.integer(forKey: Self.deepPrefetchDepthKey)
    }

    var isConfigured: Bool {
        token != nil && !serverURL.isEmpty && !playlistIds.isEmpty
    }

    func apply(_ payload: WatchPayload) {
        if payload.playlistIds != playlistIds {
            // force a library refetch: the server trims the library to the
            // selection, so a new selection means a different library
            metadata.updateTimeNs = 0
            selectionChanges += 1
        }
        serverURL = payload.serverURL
        defaults.set(payload.serverURL, forKey: Self.serverURLKey)
        playlistIds = payload.playlistIds
        defaults.set(payload.playlistIds, forKey: Self.playlistIdsKey)
        token = payload.token.isEmpty ? nil : payload.token
        writeToken(token)
        deepPrefetchDepth = payload.deepPrefetchDepth
        defaults.set(payload.deepPrefetchDepth, forKey: Self.deepPrefetchDepthKey)
    }

    // the same normalization as the phone's AuthStore
    func baseURL() -> URL? {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}

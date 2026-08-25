import Foundation

/// the settings the phone pushes to the watch over watch connectivity: the
/// server & credentials, which playlists to sync, & how far ahead of the
/// playhead the watch fills its cache
struct WatchPayload: Equatable {
    let serverURL: String
    let token: String
    let playlistIds: [String]
    /// how many tracks past the one about to play the watch pulls down while
    /// its app is frontmost; 0 turns the deep fetch off
    let deepPrefetchDepth: Int

    private static let serverURLKey = "serverURL"
    private static let tokenKey = "token"
    private static let playlistIdsKey = "playlistIds"
    private static let deepPrefetchDepthKey = "deepPrefetchDepth"

    init(serverURL: String, token: String, playlistIds: [String], deepPrefetchDepth: Int = 0) {
        self.serverURL = serverURL
        self.token = token
        self.playlistIds = playlistIds
        self.deepPrefetchDepth = deepPrefetchDepth
    }

    init?(dictionary: [String: Any]) {
        guard let serverURL = dictionary[Self.serverURLKey] as? String,
              let token = dictionary[Self.tokenKey] as? String,
              let playlistIds = dictionary[Self.playlistIdsKey] as? [String]
        else {
            return nil
        }
        // missing on a context pushed by a phone from before the setting
        // existed, which is off rather than undecodable
        self.init(
            serverURL: serverURL, token: token, playlistIds: playlistIds,
            deepPrefetchDepth: dictionary[Self.deepPrefetchDepthKey] as? Int ?? 0)
    }

    /// true when there's enough here for the watch to sync
    var isConfigured: Bool {
        !serverURL.isEmpty && !token.isEmpty && !playlistIds.isEmpty
    }

    func encode() -> [String: Any] {
        [
            Self.serverURLKey: serverURL,
            Self.tokenKey: token,
            Self.playlistIdsKey: playlistIds,
            Self.deepPrefetchDepthKey: deepPrefetchDepth
        ]
    }
}

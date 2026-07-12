import Foundation

/// the settings the phone pushes to the watch over watch connectivity: the
/// server & credentials plus which playlists to sync
struct WatchPayload: Equatable {
    let serverURL: String
    let token: String
    let playlistIds: [String]

    private static let serverURLKey = "serverURL"
    private static let tokenKey = "token"
    private static let playlistIdsKey = "playlistIds"

    init(serverURL: String, token: String, playlistIds: [String]) {
        self.serverURL = serverURL
        self.token = token
        self.playlistIds = playlistIds
    }

    init?(dictionary: [String: Any]) {
        guard let serverURL = dictionary[Self.serverURLKey] as? String,
              let token = dictionary[Self.tokenKey] as? String,
              let playlistIds = dictionary[Self.playlistIdsKey] as? [String]
        else {
            return nil
        }
        self.init(serverURL: serverURL, token: token, playlistIds: playlistIds)
    }

    /// true when there's enough here for the watch to sync
    var isConfigured: Bool {
        !serverURL.isEmpty && !token.isEmpty && !playlistIds.isEmpty
    }

    func encode() -> [String: Any] {
        [
            Self.serverURLKey: serverURL,
            Self.tokenKey: token,
            Self.playlistIdsKey: playlistIds
        ]
    }
}

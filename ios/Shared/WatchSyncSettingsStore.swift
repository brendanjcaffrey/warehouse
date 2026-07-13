import Foundation
import Observation

/// phone-side settings for the watch app's sync: which playlists to sync
@MainActor
@Observable
final class WatchSyncSettingsStore {
    private static let playlistIdsKey = "watchPlaylistIds"

    /// called after every change so the new settings can be pushed to the watch
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var playlistIds: [String]
    private let defaults: UserDefaults

    // the parameter is here for tests
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlistIds = defaults.stringArray(forKey: Self.playlistIdsKey) ?? []
    }

    func isSelected(_ playlistId: String) -> Bool {
        playlistIds.contains(playlistId)
    }

    func toggle(_ playlistId: String) {
        if let index = playlistIds.firstIndex(of: playlistId) {
            playlistIds.remove(at: index)
        } else {
            playlistIds.append(playlistId)
        }
        defaults.set(playlistIds, forKey: Self.playlistIdsKey)
        onChange()
    }
}

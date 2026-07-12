import Foundation
import Observation

/// phone-side settings for the watch app's sync: which playlists to sync,
/// plus an optional server url override (e.g. a tailscale funnel url) for
/// when the watch can't reach the same server the phone uses
@MainActor
@Observable
final class WatchSyncSettingsStore {
    private static let playlistIdsKey = "watchPlaylistIds"
    private static let serverURLOverrideKey = "watchServerURLOverride"

    /// called after every change so the new settings can be pushed to the watch
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var playlistIds: [String]
    private(set) var serverURLOverride: String
    private let defaults: UserDefaults

    // the parameter is here for tests
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlistIds = defaults.stringArray(forKey: Self.playlistIdsKey) ?? []
        serverURLOverride = defaults.string(forKey: Self.serverURLOverrideKey) ?? ""
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

    func setServerURLOverride(_ url: String) {
        guard url != serverURLOverride else { return }
        serverURLOverride = url
        defaults.set(url, forKey: Self.serverURLOverrideKey)
        onChange()
    }

    /// the url the watch should sync from: the override if set, otherwise the
    /// phone's own server url
    func effectiveServerURL(phoneServerURL: String) -> String {
        let trimmed = serverURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? phoneServerURL : trimmed
    }
}

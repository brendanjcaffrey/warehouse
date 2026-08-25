import Foundation
import Observation

/// phone-side settings for the watch app: which playlists its library is
/// trimmed to, the url it reaches the server on, & how far ahead of the
/// playhead it fills its cache. the watch can't join the tailnet, so the url
/// is normally a tailscale funnel url; left blank it falls back to the
/// phone's own server url
@MainActor
@Observable
final class WatchSyncSettingsStore {
    private static let playlistIdsKey = "watchPlaylistIds"
    private static let serverURLOverrideKey = "watchServerURLOverride"
    private static let deepPrefetchDepthKey = "watchDeepPrefetchDepth"
    /// as far as the watch will be asked to fill ahead: past this it is the
    /// cache budget doing the stopping, not the depth. a bound at all because
    /// the queue is walked against the disk every time the chain re-arms, and
    /// that walk has to end
    static let maxDeepPrefetchDepth = 10_000

    /// called after every change so the new settings can be pushed to the watch
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var playlistIds: [String]
    private(set) var serverURLOverride: String
    /// how many tracks past the one about to play the watch pulls down while
    /// its app is frontmost. off by default: it is a lot of link time & a lot
    /// of the watch's disk, and it only pays for the walking-out-of-signal
    /// case rather than for ordinary listening
    private(set) var deepPrefetchDepth: Int
    private let defaults: UserDefaults

    // the parameter is here for tests
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlistIds = defaults.stringArray(forKey: Self.playlistIdsKey) ?? []
        serverURLOverride = defaults.string(forKey: Self.serverURLOverrideKey) ?? ""
        // integer(forKey:) is 0 for a key that has never been set, which is
        // the default anyway
        deepPrefetchDepth = defaults.integer(forKey: Self.deepPrefetchDepthKey)
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

    func setDeepPrefetchDepth(_ depth: Int) {
        let clamped = min(max(depth, 0), Self.maxDeepPrefetchDepth)
        guard clamped != deepPrefetchDepth else { return }
        deepPrefetchDepth = clamped
        defaults.set(clamped, forKey: Self.deepPrefetchDepthKey)
        onChange()
    }

    /// the url the watch reaches the server on: the override if set,
    /// otherwise the phone's own server url
    func effectiveServerURL(phoneServerURL: String) -> String {
        let trimmed = serverURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? phoneServerURL : trimmed
    }
}

import Foundation
import Observation

/// the phone owns watch playlist selection and automatic delivery progress.
@MainActor
@Observable
final class WatchSyncSettingsStore {
    var content: PhoneWatchContentQueue?

    func progress(playlistID: String? = nil) -> WatchLibraryProgress {
        guard !playlistIds.isEmpty else { return WatchLibraryProgress(state: .empty) }
        return content?.progress(playlistID: playlistID) ?? WatchLibraryProgress(state: .preparing)
    }

    private static let playlistIdsKey = "watchPlaylistIds"
    /// called after every change so the new settings can be pushed to the watch
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var playlistIds: [String]
    private let defaults: UserDefaults

    // the parameter is here for tests
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlistIds = defaults.stringArray(forKey: Self.playlistIdsKey) ?? []
        defaults.removeObject(forKey: "watchServerURLOverride")
        defaults.removeObject(forKey: "watchDeepPrefetchDepth")
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

    func setPlaylistIds(_ ids: [String]) {
        guard Set(ids) != Set(playlistIds) else { return }
        playlistIds = Array(Set(ids)).sorted()
        defaults.set(playlistIds, forKey: Self.playlistIdsKey)
        onChange()
    }

}

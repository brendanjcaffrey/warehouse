import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchRemoteStore.self) private var remote

    /// only the library gates the menu now; tracks arrive on demand, so
    /// there's nothing outstanding to wait on
    private var isLibraryReady: Bool {
        settings.isConfigured && !songs.songs.isEmpty && sync.completedSyncs > 0
    }

    var body: some View {
        Group {
            if isLibraryReady {
                WatchMenuView()
            } else if remote.isAvailable {
                // nothing of our own to browse yet, but the phone is playing:
                // the remote is the whole app in that case, so skip the
                // waiting screens rather than hiding the one useful thing
                NavigationStack {
                    WatchRemoteNowPlayingView()
                }
            } else if !settings.isConfigured {
                WatchWaitingView()
            } else {
                WatchSyncProgressView()
            }
        }
        .task(id: settings.selectionChanges) {
            // first sync, plus a re-sync whenever the phone changes the selection
            await sync.sync(token: settings.token, baseURL: settings.baseURL())
        }
        .task(id: sync.completedSyncs) {
            await songs.load()
            await playlists.load()
        }
    }
}

import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        Group {
            if !settings.isConfigured {
                WatchWaitingView()
            } else if songs.songs.isEmpty || sync.completedSyncs == 0 || sync.isTransferringLibrary {
                // hold the progress view through the whole launch sync, so the
                // menu can't appear while downloads are still outstanding
                WatchSyncProgressView()
            } else {
                WatchMenuView()
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

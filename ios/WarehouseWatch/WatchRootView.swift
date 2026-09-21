import SwiftUI

struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(WatchLibraryStore.self) private var library
    @Environment(WatchRemoteStore.self) private var remote

    private var startup: WatchLibraryStore.State {
        library.presentation(isConfigured: settings.isConfigured)
    }

    var body: some View {
        Group {
            if startup == .ready {
                WatchMenuView()
            } else if remote.isAvailable {
                // nothing of our own to browse yet, but the phone is playing:
                // the remote is the whole app in that case, so skip the
                // waiting screens rather than hiding the one useful thing
                NavigationStack {
                    WatchRemoteNowPlayingView()
                }
            } else {
                startupContent
            }
        }
        .task(id: settings.selectionChanges) {
            // make the saved library available before starting any network work
            await library.load()
            // first sync, plus a re-sync whenever the phone changes the selection
            guard settings.isConfigured else { return }
            await sync.sync(token: settings.token, baseURL: settings.baseURL())
        }
        .onChange(of: sync.completedSyncs) {
            Task { await library.load() }
        }
        .onChange(of: scenePhase) {
            // a sync that died offline is otherwise only retried when asked.
            // coming back to the front is the moment the wrist is likely in
            // range again, & it's the only signal the watch gets
            guard scenePhase == .active, sync.state == .offline else { return }
            Task {
                await sync.sync(token: settings.token, baseURL: settings.baseURL())
            }
        }
    }

    @ViewBuilder
    private var startupContent: some View {
        switch startup {
        case .setup:
            WatchWaitingView()
        case .loading:
            ProgressView("Loading saved library…")
        case .needsSync:
            WatchSyncProgressView()
        case .empty:
            ContentUnavailableView {
                Label("No Songs", systemImage: "music.note")
            } description: {
                Text("Your selected playlists contain no songs.")
            } actions: {
                refreshButton
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                refreshButton
            }
        case .ready:
            WatchMenuView()
        }
    }

    private var refreshButton: some View {
        Button("Try Again") {
            Task {
                await library.load()
                await sync.sync(token: settings.token, baseURL: settings.baseURL())
            }
        }
        .disabled(sync.isBusy)
    }
}
